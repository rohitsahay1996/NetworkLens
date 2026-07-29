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

    /// Adds or replaces the rule for an endpoint key.
    ///
    /// Keyed by endpoint rather than appended blindly, so swiping the same row
    /// twice does not arm two overlapping breakpoints.
    public func set(_ breakpoint: Breakpoint) {
        lock.lock()
        if let index = storage.firstIndex(where: { $0.endpointKey == breakpoint.endpointKey }) {
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

    /// Both clear on relaunch by default; this is what "keep active" skips.
    public func clearForRelaunch() {
        lock.lock()
        storage.removeAll()
        perturbationStorage.removeAll()
        skippedKeys.removeAll()
        lock.unlock()
        notify()
    }

    // MARK: - Hot path

    public func shouldPauseRequest(for request: URLRequest) -> Bool {
        guard let key = matchKey(for: request) else { return false }

        lock.lock()
        let enabled = requestEditingEnabled
        let skipped = skippedKeys.contains(key)
        let rule = storage.first { $0.endpointKey == key && $0.isEnabled }
        lock.unlock()

        guard enabled, !skipped, let rule, rule.stage.pausesRequest else { return false }
        // Production hosts refuse request breakpoints outright. Response
        // breakpoints stay available — they cannot reach the backend.
        return !NetworkLens.configuration.isProductionHost(request.url?.host)
    }

    public func shouldPauseResponse(for request: URLRequest) -> Bool {
        guard let key = matchKey(for: request) else { return false }

        lock.lock()
        let skipped = skippedKeys.contains(key)
        let rule = storage.first { $0.endpointKey == key && $0.isEnabled }
        lock.unlock()

        guard !skipped, let rule, rule.stage.pausesResponse else { return false }
        return true
    }

    /// Disables a one-shot rule after it fires.
    public func didHit(endpointKey key: String) {
        lock.lock()
        if let index = storage.firstIndex(where: { $0.endpointKey == key }), storage[index].oneShot {
            storage[index].isEnabled = false
        }
        lock.unlock()
        notify()
    }

    private func matchKey(for request: URLRequest) -> String? {
        lock.lock()
        let hasAny = !storage.isEmpty
        lock.unlock()
        // Skip the matcher chain entirely when nothing is armed. This runs on
        // every request, armed or not.
        guard hasAny else { return nil }
        return NetworkLens.endpointKey(for: request)
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
