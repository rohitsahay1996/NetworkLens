//
//  Scenarios.swift
//  NetworkLensCore
//
//  Created by Rohit Sahay on 30/07/26.
//

import Foundation

/// The saved scenarios, and the one currently applied.
///
/// Mirrors `Mocks` and `Breakpoints` deliberately: same lock discipline, same
/// observer token, same relaunch semantics — so a reader who has understood one
/// registry has understood all three.
public final class Scenarios: @unchecked Sendable {

    public static let shared = Scenarios()

    private let lock = NSLock()
    private var storage: [Scenario] = []
    private var appliedID: UUID?
    private var observers: [UUID: @Sendable () -> Void] = [:]

    public init() {}

    // MARK: - Reads

    public var all: [Scenario] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    /// The scenario last applied, and only while the rules still say so.
    ///
    /// Verified rather than remembered: switching one endpoint by hand makes
    /// this go nil on its own, so the label can never claim a setup that is no
    /// longer in force.
    public func applied(in mocks: Mocks = .shared) -> Scenario? {
        lock.lock()
        let candidate = storage.first { $0.id == appliedID }
        lock.unlock()

        guard let candidate, candidate.matches(mocks.all) else { return nil }
        return candidate
    }

    public func scenario(named name: String) -> Scenario? {
        lock.lock()
        defer { lock.unlock() }
        return storage.first { $0.name == name }
    }

    // MARK: - Editing

    /// Adds or replaces by id, then by name — saving "checkout" twice updates
    /// it rather than leaving two entries a tester has to tell apart.
    public func save(_ scenario: Scenario) {
        lock.lock()
        if let index = storage.firstIndex(where: { $0.id == scenario.id }) {
            storage[index] = scenario
        } else if let index = storage.firstIndex(where: { $0.name == scenario.name }) {
            storage[index] = scenario
        } else {
            storage.append(scenario)
        }
        lock.unlock()
        notify()
    }

    public func remove(id: UUID) {
        lock.lock()
        storage.removeAll { $0.id == id }
        if appliedID == id { appliedID = nil }
        lock.unlock()
        notify()
    }

    public func removeAll() {
        lock.lock()
        storage.removeAll()
        appliedID = nil
        lock.unlock()
        notify()
    }

    public func replaceAll(_ scenarios: [Scenario]) {
        lock.lock()
        storage = scenarios
        appliedID = nil
        lock.unlock()
        notify()
    }

    /// Nothing is applied after a relaunch, whatever survived on disk.
    ///
    /// The scenarios themselves are worth keeping — they are the work. Having
    /// one silently back in force on the next launch is the same trap as a
    /// forgotten breakpoint: the app misbehaves and nothing on screen says why.
    public func clearAppliedForRelaunch() {
        lock.lock()
        appliedID = nil
        lock.unlock()
        notify()
    }

    // MARK: - Applying

    /// What happened when a scenario was applied.
    public struct Outcome: Sendable, Equatable {
        /// Endpoints switched.
        public var applied: Int
        /// Entries whose rule or variant no longer exists.
        public var missing: [Scenario.Entry]

        public var isComplete: Bool { missing.isEmpty }
    }

    /// Selects every variant the scenario names, in one pass.
    ///
    /// Reports what it could not do rather than failing or pretending: rules
    /// get deleted and variants get renamed, and a half-applied scenario that
    /// says so is debuggable while a silent one is not.
    @discardableResult
    public func apply(_ scenario: Scenario, to mocks: Mocks = .shared) -> Outcome {
        let (updated, missing) = scenario.resolve(against: mocks.all)

        for rule in updated {
            mocks.set(rule)
            // Selecting through the store rewinds the script, which a raw
            // `set` does not — a scenario has to start its sequences at step
            // one or it is not reproducible.
            mocks.activateVariant(rule.activeVariantID, forRuleID: rule.id)
        }
        if !updated.isEmpty, !mocks.isMockingEnabled {
            mocks.setMockingEnabled(true)
        }

        lock.lock()
        appliedID = updated.isEmpty ? nil : scenario.id
        lock.unlock()
        notify()

        return Outcome(applied: updated.count, missing: missing)
    }

    // MARK: - Observation

    public struct ObservationToken: Sendable {
        let id: UUID
        let cancel: @Sendable () -> Void
        public func invalidate() { cancel() }
    }

    public func addObserver(_ observer: @escaping @Sendable () -> Void) -> ObservationToken {
        let id = UUID()
        lock.lock()
        observers[id] = observer
        lock.unlock()
        return ObservationToken(id: id) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.observers.removeValue(forKey: id)
            self.lock.unlock()
        }
    }

    private func notify() {
        lock.lock()
        let current = Array(observers.values)
        lock.unlock()
        for observer in current { observer() }
    }
}
