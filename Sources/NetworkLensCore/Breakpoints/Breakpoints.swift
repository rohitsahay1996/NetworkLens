//
//  Breakpoints.swift
//  NetworkLensCore
//
//  Created by Rohit Sahay on 29/07/26.
//

import Foundation

/// The armed breakpoint set, plus the safety rules that govern it.
///
/// Consulted from `LensURLProtocol` on the hot path, so reads are a lock and a
/// linear scan over a handful of rules rather than anything clever.
public final class Breakpoints: @unchecked Sendable {

    public static let shared = Breakpoints()

    private let lock = NSLock()
    private var storage: [Breakpoint] = []
    private var perturbationStorage: [Perturbation] = []
    private var skippedKeys: Set<String> = []
    private var observers: [UUID: @Sendable () -> Void] = [:]

    /// Request editing is off by default and behind an explicit toggle.
    ///
    /// Editing a response is client-side and affects one screen. Editing a
    /// request sends different data to a real backend and can create real
    /// records — a QA tester who does not realise that can do damage that
    /// outlives the session.
    private var requestEditingEnabled = false

    public init() {}

    // MARK: - Rules

    public var all: [Breakpoint] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    public var perturbations: [Perturbation] {
        lock.lock()
        defer { lock.unlock() }
        return perturbationStorage
    }

    public var isRequestEditingEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requestEditingEnabled
    }

    public func setRequestEditingEnabled(_ enabled: Bool) {
        lock.lock()
        requestEditingEnabled = enabled
        lock.unlock()
        notify()
    }

    /// Adds or replaces the rule for a match identity.
    ///
    /// Keyed by what the rule actually matches rather than appended blindly, so
    /// arming the same endpoint or the same URL twice does not leave two
    /// overlapping breakpoints. Two exact-URL breakpoints on the same endpoint
    /// stay distinct — their identity is the URL, not the shared endpoint key.
    public func set(_ breakpoint: Breakpoint) {
        lock.lock()
        if let index = storage.firstIndex(where: { $0.matchIdentity == breakpoint.matchIdentity }) {
            storage[index] = breakpoint
        } else {
            storage.append(breakpoint)
        }
        lock.unlock()
        notify()
    }

    public func remove(id: UUID) {
        lock.lock()
        storage.removeAll { $0.id == id }
        lock.unlock()
        notify()
    }

    public func removeAll() {
        lock.lock()
        storage.removeAll()
        skippedKeys.removeAll()
        lock.unlock()
        notify()
    }

    /// Turns every rule off without discarding them, for "Resume all and
    /// disable breakpoints".
    public func disableAll() {
        lock.lock()
        for index in storage.indices { storage[index].isEnabled = false }
        lock.unlock()
        notify()
    }

    public func breakpoint(forEndpointKey key: String) -> Breakpoint? {
        lock.lock()
        defer { lock.unlock() }
        return storage.first { $0.endpointKey == key && $0.isEnabled }
    }

    /// "Execute and skip this endpoint for the session."
    public func skipForSession(endpointKey: String) {
        lock.lock()
        skippedKeys.insert(endpointKey)
        lock.unlock()
        notify()
    }

    public func clearSkips() {
        lock.lock()
        skippedKeys.removeAll()
        lock.unlock()
        notify()
    }

    // MARK: - Perturbations

    public func save(_ perturbation: Perturbation) {
        lock.lock()
        if let index = perturbationStorage.firstIndex(where: { $0.id == perturbation.id }) {
            perturbationStorage[index] = perturbation
        } else {
            perturbationStorage.append(perturbation)
        }
        lock.unlock()
        notify()
    }

    public func removePerturbation(id: UUID) {
        lock.lock()
        perturbationStorage.removeAll { $0.id == id }
        lock.unlock()
        notify()
    }

    public func perturbations(forEndpointKey key: String) -> [Perturbation] {
        lock.lock()
        defer { lock.unlock() }
        return perturbationStorage.filter { $0.endpointKey == key }
    }

    /// Those actually rewriting this endpoint's traffic, in save order.
    ///
    /// Order matters and is deliberately the order they were saved: ops
    /// compose, and two enabled perturbations touching the same path have to
    /// resolve the same way on every hit or nothing is reproducible.
    public func enabledPerturbations(forEndpointKey key: String) -> [Perturbation] {
        lock.lock()
        defer { lock.unlock() }
        return perturbationStorage.filter { $0.endpointKey == key && $0.isEnabled }
    }

    /// Both clear on relaunch by default; this is what "keep active" skips.
    public func clearForRelaunch() {
        lock.lock()
        storage.removeAll()
        perturbationStorage.removeAll()
        skippedKeys.removeAll()
        lock.unlock()
        notify()
    }

    /// Drops the armed rules but keeps saved perturbations.
    ///
    /// The relaunch behaviour once persistence is in play: an armed breakpoint
    /// that survives a relaunch reads as a hung app, while a perturbation is
    /// inert until someone applies it and is exactly what a tester saved it
    /// for. `clearForRelaunch()` remains the "forget everything" path.
    public func clearRulesForRelaunch() {
        lock.lock()
        storage.removeAll()
        skippedKeys.removeAll()
        lock.unlock()
        notify()
    }

    /// Swaps the whole rule set, for restoring a saved session.
    public func replaceAll(_ breakpoints: [Breakpoint]) {
        lock.lock()
        storage = breakpoints
        skippedKeys.removeAll()
        lock.unlock()
        notify()
    }

    public func replacePerturbations(_ perturbations: [Perturbation]) {
        lock.lock()
        perturbationStorage = perturbations
        lock.unlock()
        notify()
    }

    // MARK: - Hot path

    public func shouldPauseRequest(for request: URLRequest) -> Bool {
        guard let rule = enabledRule(matching: request), rule.stage.pausesRequest else {
            return false
        }
        lock.lock()
        let enabled = requestEditingEnabled
        let skipped = skippedKeys.contains(rule.matchIdentity)
        lock.unlock()

        guard enabled, !skipped else { return false }
        // Production hosts refuse request breakpoints outright. Response
        // breakpoints stay available — they cannot reach the backend.
        return !NetworkLens.configuration.isProductionHost(request.url?.host)
    }

    public func shouldPauseResponse(for request: URLRequest) -> Bool {
        guard let rule = enabledRule(matching: request), rule.stage.pausesResponse else {
            return false
        }
        lock.lock()
        let skipped = skippedKeys.contains(rule.matchIdentity)
        lock.unlock()
        return !skipped
    }

    /// The identity the coordinator should carry for a paused request, so a
    /// one-shot disarm and a session skip land on the exact rule that fired
    /// rather than every breakpoint sharing its endpoint key.
    public func matchIdentity(for request: URLRequest) -> String? {
        enabledRule(matching: request)?.matchIdentity
    }

    /// The enabled rule that claims this request, or `nil`.
    ///
    /// URL-scoped rules are the more specific intent, so they win over an
    /// endpoint rule that also covers the request. The matcher chain is only
    /// consulted when an endpoint-style rule exists to need it — a session with
    /// only URL breakpoints armed never pays for it.
    private func enabledRule(matching request: URLRequest) -> Breakpoint? {
        lock.lock()
        let all = storage
        lock.unlock()
        // Runs on every request, armed or not; bail before any URL work.
        guard !all.isEmpty else { return nil }

        if let url = request.url {
            let target = Self.canonicalURL(url)
            if let rule = all.first(where: {
                $0.isEnabled && $0.url.flatMap(Self.canonicalURL(fromPattern:)) == target
            }) {
                return rule
            }
        }

        guard all.contains(where: { $0.isEnabled && $0.url == nil }) else { return nil }
        let key = NetworkLens.endpointKey(for: request)
        return all.first { $0.isEnabled && $0.url == nil && $0.endpointKey == key }
    }

    /// Disables a one-shot rule after it fires. Keyed by match identity — the
    /// same string the coordinator was handed for this pause.
    public func didHit(endpointKey identity: String) {
        lock.lock()
        if let index = storage.firstIndex(where: { $0.matchIdentity == identity }),
           storage[index].oneShot {
            storage[index].isEnabled = false
        }
        lock.unlock()
        notify()
    }

    /// Canonical form used to compare a URL breakpoint against live traffic.
    ///
    /// A URL breakpoint is armed from the stored exchange, whose URL has
    /// already been through the redactor, so the live request is run through
    /// the same redactor before comparing — otherwise a breakpoint on a URL
    /// carrying a sensitively named query param (`?access_token=…`) would never
    /// match the traffic it was armed from. Query order is normalised too,
    /// since URLSession does not promise to preserve it, and the fragment is
    /// dropped — it never reaches the server.
    static func canonicalURL(_ url: URL) -> String {
        let redacted = NetworkLens.configuration.redactor
            .redact(RequestSnapshot(method: "GET", url: url)).url
        guard var components = URLComponents(url: redacted, resolvingAgainstBaseURL: false) else {
            return redacted.absoluteString
        }
        components.fragment = nil
        if let items = components.queryItems, !items.isEmpty {
            components.queryItems = items.sorted {
                $0.name != $1.name ? $0.name < $1.name : ($0.value ?? "") < ($1.value ?? "")
            }
        }
        return components.string ?? redacted.absoluteString
    }

    /// The stored pattern in canonical form, or `nil` if it is not a URL.
    static func canonicalURL(fromPattern pattern: String) -> String? {
        URL(string: pattern).map(canonicalURL)
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
