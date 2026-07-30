//
//  Mocks.swift
//  NetworkLensCore
//
//  Created by Rohit Sahay on 30/07/26.
//

import Foundation

/// The registered mock set, and the hit accounting that goes with it.
///
/// Consulted from `LensURLProtocol` on every request, so the empty case costs a
/// lock and an `isEmpty` check — the matcher chain is not even run until a rule
/// exists. Mirrors `Breakpoints` deliberately: same lock discipline, same
/// relaunch semantics — but keyed by endpoint *and* match conditions, since one
/// endpoint can carry a catch-all rule alongside narrower ones.
public final class Mocks: @unchecked Sendable {

    public static let shared = Mocks()

    private let lock = NSLock()
    private var storage: [MockRule] = []
    /// Keyed by rule id, not endpoint key, so replacing a rule starts its count
    /// over instead of inheriting the old rule's history.
    private var hits: [UUID: Int] = [:]
    private var observers: [UUID: @Sendable () -> Void] = [:]

    /// Master switch. Lets a tester compare mocked and live behaviour without
    /// tearing down a rule set they spent time building.
    private var mockingEnabled = true

    public init() {}

    // MARK: - Rules

    public var all: [MockRule] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    public var isMockingEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return mockingEnabled
    }

    /// True when something would actually be served — the master switch is on
    /// *and* at least one rule is armed.
    ///
    /// The question the UI needs answered is "is anything I am looking at
    /// fake?", and neither half answers it alone: the switch can be on with an
    /// empty rule set, and rules can sit armed behind a switch that is off.
    /// Chasing a bug that turns out to be your own mock is the failure this
    /// exists to prevent.
    public var isServing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return mockingEnabled && storage.contains(where: \.isEnabled)
    }

    /// Whether this endpoint would be answered from the device right now.
    public func isServing(endpointKey: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return mockingEnabled && storage.contains { $0.endpointKey == endpointKey && $0.isEnabled }
    }

    /// Switches which answer an endpoint gives, and rewinds its script.
    ///
    /// The rewind is the point. Hit counts are per rule, so without it a
    /// three-step variant selected after two hits would start at step three —
    /// the tester picks "fails twice then succeeds" and sees it succeed
    /// immediately, which reads as the tool being broken.
    public func activateVariant(_ variantID: UUID, forRuleID ruleID: UUID) {
        lock.lock()
        guard let index = storage.firstIndex(where: { $0.id == ruleID }) else {
            return lock.unlock()
        }
        storage[index].activate(variantID: variantID)
        hits[ruleID] = 0
        lock.unlock()
        notify()
    }

    public func setMockingEnabled(_ enabled: Bool) {
        lock.lock()
        mockingEnabled = enabled
        lock.unlock()
        notify()
    }

    /// Adds the rule, or replaces the one with the same endpoint key *and*
    /// match conditions.
    ///
    /// Identity is the pair. One rule per endpoint per condition set: a
    /// catch-all and a `page=2` rule coexist, while saving a second catch-all
    /// replaces the first. Two rules that could both claim a request would make
    /// the answer depend on insertion order, which `resolve` refuses to do —
    /// see the specificity ordering there.
    public func set(_ rule: MockRule) {
        lock.lock()
        if let index = storage.firstIndex(
            where: { $0.endpointKey == rule.endpointKey && $0.match == rule.match }
        ) {
            let replaced = storage[index]
            storage[index] = rule
            if replaced.id != rule.id { hits[replaced.id] = nil }
        } else {
            storage.append(rule)
        }
        lock.unlock()
        notify()
    }

    public func remove(id: UUID) {
        lock.lock()
        storage.removeAll { $0.id == id }
        hits[id] = nil
        lock.unlock()
        notify()
    }

    public func removeAll() {
        lock.lock()
        storage.removeAll()
        hits.removeAll()
        lock.unlock()
        notify()
    }

    /// Swaps the whole rule set, for restoring a saved session.
    ///
    /// Counts are dropped rather than carried: a restored script has to start
    /// at step one, or the first request after a relaunch lands in the middle
    /// of a sequence nobody remembers arming.
    public func replaceAll(_ rules: [MockRule]) {
        lock.lock()
        storage = rules
        hits.removeAll()
        lock.unlock()
        notify()
    }

    /// Turns every rule off without discarding them, for "go live for a minute".
    public func disableAll() {
        lock.lock()
        for index in storage.indices { storage[index].isEnabled = false }
        lock.unlock()
        notify()
    }

    public func rule(forEndpointKey key: String) -> MockRule? {
        lock.lock()
        defer { lock.unlock() }
        return storage.first { $0.endpointKey == key }
    }

    /// Cleared on relaunch unless `keepBreakpointsAcrossLaunches` is set, for
    /// the same reason breakpoints are: a forgotten mock that survives a
    /// relaunch presents as a backend bug.
    public func clearForRelaunch() {
        lock.lock()
        storage.removeAll()
        hits.removeAll()
        lock.unlock()
        notify()
    }

    // MARK: - Hit accounting

    public func hitCount(forRuleID id: UUID) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return hits[id] ?? 0
    }

    public func hitCount(forEndpointKey key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let rule = storage.first(where: { $0.endpointKey == key }) else { return 0 }
        return hits[rule.id] ?? 0
    }

    public func resetHitCounts() {
        lock.lock()
        hits.removeAll()
        lock.unlock()
        notify()
    }

    // MARK: - Hot path

    /// Claims `request` for a rule, if one is armed for its endpoint.
    ///
    /// Has a side effect — the rule's hit count moves — so it must be called
    /// exactly once per request, by the interception layer and nobody else.
    /// Use `rule(forEndpointKey:)` to inspect without counting.
    public func resolve(_ request: URLRequest) -> MockResolution? {
        lock.lock()
        let enabled = mockingEnabled
        let hasAny = !storage.isEmpty
        lock.unlock()

        // Runs on every request, mocked or not. Nothing armed, nothing to key.
        guard enabled, hasAny else { return nil }

        let key = NetworkLens.endpointKey(for: request)

        lock.lock()
        // Narrowest wins. A `page=2` rule has to beat the catch-all for the
        // same endpoint no matter which was saved first; among equals, the
        // earlier one keeps its claim so the order stays stable across launches.
        let candidates = storage
            .filter { $0.endpointKey == key && $0.isEnabled && $0.match.matches(request) }
        guard
            let rule = candidates.max(by: { $0.match.specificity < $1.match.specificity })
        else {
            lock.unlock()
            return nil
        }

        let hitIndex = (hits[rule.id] ?? 0) + 1
        // A spent `.passThrough` script claims nothing, so it must not count
        // either. Leaving the counter parked at the end of the script is what
        // keeps every later request passing through instead of the count
        // running away for traffic the rule no longer touches.
        guard let outcome = rule.outcome(forHit: hitIndex) else {
            lock.unlock()
            return nil
        }
        hits[rule.id] = hitIndex
        lock.unlock()

        // No `notify()` here on purpose. This is the hot path, and firing every
        // observer per mocked request would put UI work on the network task.
        // Counts are read on demand.
        return MockResolution(
            ruleID: rule.id,
            endpointKey: rule.endpointKey,
            name: rule.name,
            outcome: outcome,
            hitIndex: hitIndex
        )
    }

    // MARK: - Observation

    public func addObserver(_ observer: @escaping @Sendable () -> Void) -> ObservationToken {
        let id = UUID()
        lock.lock()
        observers[id] = observer
        lock.unlock()
        return ObservationToken(id: id) { [weak self] id in
            guard let self else { return }
            self.lock.lock()
            self.observers[id] = nil
            self.lock.unlock()
        }
    }

    private func notify() {
        lock.lock()
        let current = Array(observers.values)
        lock.unlock()
        for observer in current { observer() }
    }

    public final class ObservationToken: Sendable {
        private let id: UUID
        private let cancel: @Sendable (UUID) -> Void

        init(id: UUID, cancel: @escaping @Sendable (UUID) -> Void) {
            self.id = id
            self.cancel = cancel
        }

        deinit { cancel(id) }
    }
}
