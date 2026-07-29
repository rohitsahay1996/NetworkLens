import Foundation

/// The public façade.
///
/// `NetworkLensUI` extends this type with `attachOverlay(to:)`, and
/// `NetworkLensNoOp` mirrors the whole surface with empty bodies. Host call
/// sites therefore swap `import NetworkLensUI` for `import NetworkLensNoOp`
/// in a release build and need no `#if` guards.
public enum NetworkLens {

    /// Live session state. Nil until `start` is called.
    private static let state = LensState()

    /// Zero-config entry point. Swizzles `URLSessionConfiguration.default`
    /// and `.ephemeral` so sessions created afterwards are instrumented.
    ///
    /// Safe to call more than once — later calls replace the configuration but
    /// do not re-swizzle.
    public static func start(configuration: LensConfiguration = .default) {
        state.activate(with: configuration)

        if !configuration.keepBreakpointsAcrossLaunches {
            Breakpoints.shared.clearForRelaunch()
        }

        // Covers URLSession.shared, which honours globally registered
        // protocols but has a configuration the app cannot reach.
        URLProtocol.registerClass(LensURLProtocol.self)

        // Covers sessions built after this point from .default / .ephemeral.
        LensSwizzler.installConfigurationHooks()

        if configuration.automaticScreenAttribution {
            // Stamps the current screen onto the request on the caller's
            // thread, at task creation. Reading it later in canInit would give
            // the delegate queue's screen, which is nobody's screen.
            LensSwizzler.installTaskHooks()
        }
    }

    /// Explicit install, for apps that build their own session configuration
    /// and would rather not be swizzled.
    public static func install(into config: URLSessionConfiguration) {
        var classes = config.protocolClasses ?? []
        guard !classes.contains(where: { $0 == LensURLProtocol.self }) else { return }
        // First, or the system HTTP protocol claims the request before we see it.
        classes.insert(LensURLProtocol.self, at: 0)
        config.protocolClasses = classes
    }

    /// Escape hatch for traffic `URLProtocol` cannot see — gRPC, raw sockets,
    /// WebSockets, or a decode failure the host app wants on the timeline.
    public static func record(_ exchange: NetworkExchange) {
        state.record(exchange)
    }

    // MARK: - Accessors used by the overlay

    /// Backing store. Exposed so `NetworkLensUI` can observe it without Core
    /// depending on the UI target.
    public static var store: ExchangeStore { state.store }

    public static var configuration: LensConfiguration { state.configuration }

    public static var isActive: Bool { state.isActive }

    /// Endpoint key for a request under the active matcher chain. Used by the
    /// interception layer and available to callers building `record(_:)`
    /// exchanges by hand.
    public static func endpointKey(for request: URLRequest) -> String {
        state.endpointKey(for: request)
    }

    public static func stats() -> SessionStats {
        SessionStats(exchanges: state.store.exchanges)
    }
}

// MARK: - State

/// Holds the live configuration and store behind a lock.
///
/// A separate type rather than static vars on the enum so the mutable state has
/// one owner and one lock, and so tests can reason about `reset()`.
final class LensState: @unchecked Sendable {

    private let lock = NSLock()
    private var _configuration = LensConfiguration.default
    private var _isActive = false
    private var _chain = MatcherChain([PathMatcher()])

    let store = ExchangeStore()

    var configuration: LensConfiguration {
        lock.lock()
        defer { lock.unlock() }
        return _configuration
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isActive
    }

    func activate(with configuration: LensConfiguration) {
        lock.lock()
        _configuration = configuration
        _chain = MatcherChain(configuration.matchers)
        _isActive = true
        lock.unlock()
        store.setCapacity(configuration.maxStoredExchanges)
    }

    func endpointKey(for request: URLRequest) -> String {
        lock.lock()
        let chain = _chain
        lock.unlock()
        return chain.endpointKey(for: request)
    }

    /// Redacts on the way in. There is no path into the store that skips this.
    ///
    /// Upserts rather than appends, because interception records the same
    /// exchange twice — once in flight, once complete.
    func record(_ exchange: NetworkExchange) {
        lock.lock()
        let redactor = _configuration.redactor
        lock.unlock()
        store.upsert(exchange.redacted(by: redactor))
    }
}
