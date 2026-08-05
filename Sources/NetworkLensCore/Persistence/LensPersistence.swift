//
//  LensPersistence.swift
//  NetworkLensCore
//
//  Created by Rohit Sahay on 30/07/26.
//

import Foundation

/// Moves rules between the in-memory registries and a `LensSnapshotStore`.
///
/// Owns the policy, not the format: what survives a relaunch, and what is
/// deliberately dropped. The format lives in `LensSnapshot`.
public final class LensPersistence: @unchecked Sendable {

    public static let shared = LensPersistence()

    private let lock = NSLock()
    private var store: LensSnapshotStore
    private let queue = DispatchQueue(label: "com.networklens.persistence")

    /// Suppresses autosave while restoring, so replaying a snapshot into the
    /// registries does not immediately write it back out again.
    private var isRestoring = false
    private var isAutosaving = false

    private var mocksToken: Mocks.ObservationToken?
    private var breakpointsToken: Breakpoints.ObservationToken?

    public init(store: LensSnapshotStore = FileSnapshotStore()) {
        self.store = store
    }

    public func setStore(_ store: LensSnapshotStore) {
        lock.lock()
        self.store = store
        lock.unlock()
    }

    private var currentStore: LensSnapshotStore {
        lock.lock()
        defer { lock.unlock() }
        return store
    }

    // MARK: - Snapshotting

    /// Reads the live registries. Cheap enough to call on every mutation.
    ///
    /// Rules are redacted on the way out unless the host app opts out. A rule
    /// is built from a real response and is therefore exactly as sensitive as
    /// the traffic it came from — the traffic list has always been redacted,
    /// but rules were not, and rules are the half that gets written to disk and
    /// outlives the session. A captured `200` carrying a bearer token was being
    /// shown as `***` and saved in the clear.
    ///
    /// In-memory rules are untouched, so the current session keeps serving the
    /// real captured bytes; only the copy that persists is scrubbed.
    public func snapshot() -> LensSnapshot {
        let configuration = NetworkLens.configuration
        let mocks = configuration.redactsPersistedRules
            ? Mocks.shared.all.map { $0.redacted(by: configuration.redactor) }
            : Mocks.shared.all

        return LensSnapshot(
            mocks: mocks,
            breakpoints: Breakpoints.shared.all,
            perturbations: Breakpoints.shared.perturbations,
            scenarios: Scenarios.shared.all,
            isMockingEnabled: Mocks.shared.isMockingEnabled
        )
    }

    /// Writes the current state, synchronously. Autosave uses the async path.
    @discardableResult
    public func persist() -> Bool {
        do {
            try currentStore.save(snapshot())
            return true
        } catch {
            return false
        }
    }

    // MARK: - Restoring

    /// Applies a saved snapshot at launch.
    ///
    /// `keepingActiveRules` is `LensConfiguration.keepBreakpointsAcrossLaunches`.
    /// When it is off — the default — mocks and breakpoints are dropped and
    /// only perturbations come back. A forgotten mock that survives a relaunch
    /// presents as a backend bug, and a forgotten breakpoint as a hang; a
    /// perturbation does nothing until someone applies it, so it is safe to
    /// keep and is the one thing a tester expects to still be there.
    public func restore(keepingActiveRules: Bool) {
        guard let snapshot = try? currentStore.load() else { return }

        lock.lock()
        isRestoring = true
        lock.unlock()
        defer {
            lock.lock()
            isRestoring = false
            lock.unlock()
        }

        Breakpoints.shared.replacePerturbations(snapshot.perturbations)
        Scenarios.shared.replaceAll(snapshot.scenarios)

        guard keepingActiveRules else {
            Mocks.shared.clearForRelaunch()
            Breakpoints.shared.clearRulesForRelaunch()
            return
        }

        Mocks.shared.replaceAll(snapshot.mocks)
        Mocks.shared.setMockingEnabled(snapshot.isMockingEnabled)
        Breakpoints.shared.replaceAll(snapshot.breakpoints)
    }

    // MARK: - Autosave

    /// Persists on every rule mutation, off the caller's thread.
    ///
    /// Mutations are coarse — arming a rule, editing one, clearing the set —
    /// so this is a handful of small writes per session, not a write loop. The
    /// mocking hot path deliberately does not notify, so a mocked request
    /// never reaches this.
    public func beginAutosave() {
        lock.lock()
        guard !isAutosaving else {
            lock.unlock()
            return
        }
        isAutosaving = true
        lock.unlock()

        mocksToken = Mocks.shared.addObserver { [weak self] in self?.scheduleSave() }
        breakpointsToken = Breakpoints.shared.addObserver { [weak self] in self?.scheduleSave() }
    }

    public func endAutosave() {
        mocksToken = nil
        breakpointsToken = nil
        lock.lock()
        isAutosaving = false
        lock.unlock()
    }

    private func scheduleSave() {
        lock.lock()
        let restoring = isRestoring
        lock.unlock()
        guard !restoring else { return }

        queue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.snapshot()
            try? self.currentStore.save(snapshot)
        }
    }

    /// Forgets everything on disk. The "reset the tool" button.
    public func clear() {
        try? currentStore.clear()
    }

    /// Flushes pending autosave writes. Tests and app-background hooks.
    public func flush() {
        queue.sync {}
    }
}
