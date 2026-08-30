//
//  NetworkLens.swift
//  NetworkLensCore
//
//  Created by Rohit Sahay on 29/07/26.
//

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

        // Nothing below runs when the gate is shut, and that is the point: a
        // dormant lens must not register a URLProtocol, swizzle a session,
        // restore a rule or open a trace file. A disabled tool that still sat
        // on the request path would be a production risk with none of the
        // benefit — and the one thing this gate exists to promise is that an
        // App Store build with the flag off behaves as if the package were not
        // linked at all.
        guard configuration.isEnabled else {
            state.clearTraceWriter()
            LensControlChannel.shared.stop()
            // Registration is process-wide, so a previous enabled start in the
            // same process has to be undone here. Swizzling cannot be, which is
            // why `canInit` re-checks the gate rather than trusting this line.
            URLProtocol.unregisterClass(LensURLProtocol.self)
            return
        }

        if configuration.persistsRules {
            // Restore decides for itself what may come back armed, so the
            // unconditional clear below would undo it.
            LensPersistence.shared.restore(
                keepingActiveRules: configuration.keepBreakpointsAcrossLaunches
            )
            LensPersistence.shared.beginAutosave()
        } else if !configuration.keepBreakpointsAcrossLaunches {
            Breakpoints.shared.clearForRelaunch()
            Mocks.shared.clearForRelaunch()
        }

        if let options = configuration.trace {
            // Attached before the launch scenario is applied, so a mock that a
            // scenario arms at startup still shows up in the trace as mocked
            // rather than appearing from nowhere on the first request.
            let writer = TraceWriter(options: options, redactor: configuration.redactor)
            writer.attach(to: store)
            state.noteTraceWriter(writer)
        } else {
            // start() is documented as replacing the configuration, so a second
            // call without a trace option has to stop the first one's writer.
            // Leaving it attached would keep writing under a configuration that
            // says tracing is off.
            state.clearTraceWriter()
        }

        if let options = configuration.control {
            LensControlChannel.shared.start(options)
        } else {
            // Same reason the trace writer is cleared above: a second start()
            // without control options must not leave the first one's poller
            // running under a configuration that says the channel is off.
            LensControlChannel.shared.stop()
        }

        // After the restore, never before: a launch argument names a scenario
        // by the name it was saved under, and nothing has been read off disk
        // until the line above runs.
        if let named = LensLaunchOptions.scenarioName() {
            state.noteLaunchScenario(applyScenario(named: named))
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

    /// Where the trace is being written, or nil when tracing is off.
    ///
    /// The path a tester reads out to whoever is going to pull the file off the
    /// device — on a simulator it is under the app's data container, which is
    /// not somewhere anyone guesses.
    public static var traceURL: URL? { state.traceWriter?.fileURL }

    /// Blocks until queued trace lines have landed.
    ///
    /// Writing is asynchronous, so a test or a CI step that reads the file
    /// straight after firing a request needs this or it reads a short file.
    public static func flushTrace() { state.traceWriter?.flush() }

    /// Applies a saved scenario by name, for a caller that has no UI.
    ///
    /// The entry point a UI test drives. Returns rather than throws, and
    /// reports a miss as data rather than silence, so a test can assert that
    /// the state it asked for is the state it got:
    ///
    /// ```swift
    /// XCTAssertTrue(NetworkLens.applyScenario(named: "cart empty").isApplied)
    /// ```
    @discardableResult
    public static func applyScenario(named name: String) -> ScenarioActivation {
        guard let scenario = Scenarios.shared.scenario(named: name) else {
            return .noSuchScenario(name: name, available: Scenarios.shared.all.map(\.name))
        }
        return .applied(name: scenario.name, outcome: Scenarios.shared.apply(scenario))
    }

    /// What the launch argument did, if one was given.
    ///
    /// Kept so the overlay can say so out loud. A scenario that was asked for
    /// and not found has to be visible somewhere, or the app simply behaves
    /// like the tool is not installed.
    public static var launchScenarioActivation: ScenarioActivation? {
        state.launchScenarioActivation
    }

    /// Explicit install, for apps that build their own session configuration
    /// and would rather not be swizzled.
    ///
    /// Also the moment the lens learns what the app's networking is actually
    /// configured with. An intercepted request is re-sent on the lens's own
    /// session, so cookies, additional headers, credentials and connectivity
    /// settings come from that session rather than the app's — and anything it
    /// does not have is dropped from every request while the tool is attached.
    /// Installing explicitly copies the configuration for that leg, which is the
    /// difference between the tool observing the app and the tool changing it.
    @discardableResult
    public static func install(into config: URLSessionConfiguration) -> Bool {
        install(into: config, adoptingForPassthrough: true)
    }

    /// - Parameter adoptingForPassthrough: whether this configuration should
    ///   also become the template for the real network leg. False for the
    ///   swizzled `.default` / `.ephemeral` getters: those fire on every access
    ///   from anywhere in the process, including from inside this tool, so the
    ///   last one to run would decide the app's cookie jar at random.
    @discardableResult
    static func install(
        into config: URLSessionConfiguration, adoptingForPassthrough: Bool
    ) -> Bool {
        // A background session runs its transfers in another process, where a
        // custom `URLProtocol` is never consulted. Installing into one appears
        // to work and then captures nothing — which reads as a broken tool
        // rather than an unsupported configuration, so say so instead.
        guard !isBackground(config) else {
            state.noteUninterceptable("a background URLSessionConfiguration")
            return false
        }

        if adoptingForPassthrough {
            PassthroughSession.shared.adopt(config)
        }

        var classes = config.protocolClasses ?? []
        guard !classes.contains(where: { $0 == LensURLProtocol.self }) else { return true }
        // First, or the system HTTP protocol claims the request before we see it.
        classes.insert(LensURLProtocol.self, at: 0)
        config.protocolClasses = classes
        return true
    }

    /// Whether traffic on this configuration can be seen at all.
    ///
    /// Worth asking before wiring a session in a networking module: the answer
    /// is no for background configurations, and no amount of setup changes it.
    public static func canIntercept(_ config: URLSessionConfiguration) -> Bool {
        !isBackground(config)
    }

    /// Rewrites refused because the host is production.
    ///
    /// Surfaced rather than silently skipped: a tester whose rewrite did
    /// nothing needs to know it was refused, not conclude the tool is broken.
    public static var blockedRewrites: [String] { state.blockedRewrites }

    static func noteBlockedRewrite(host: String, endpointKey: String) {
        state.noteBlockedRewrite("\(endpointKey) on \(host)")
    }

    /// Configurations the lens was asked to install into and could not.
    ///
    /// Surfaced rather than logged: a tester wondering why a screen shows no
    /// traffic needs this on screen, and a developer wiring a new session needs
    /// it in a test.
    public static var uninterceptable: [String] { state.uninterceptable }

    /// `identifier` is non-nil only for `background(withIdentifier:)`.
    private static func isBackground(_ config: URLSessionConfiguration) -> Bool {
        config.identifier != nil
    }

    /// Escape hatch for traffic `URLProtocol` cannot see — gRPC, raw sockets,
    /// WebSockets, or a decode failure the host app wants on the timeline.
    public static func record(_ exchange: NetworkExchange) {
        state.record(exchange)
    }

    /// The clock everything in the lens waits on.
    ///
    /// A seam, not a setting. `LensURLProtocol` is instantiated by
    /// `URLSession`, so there is nowhere to inject a clock into it — a static
    /// is the only place it can be reached. Replace it in tests; leave it alone
    /// in an app.
    public static var clock: LensClock {
        get { state.clock }
        set { state.clock = newValue }
    }

    /// Attributes one request to a screen, explicitly.
    ///
    /// `ScreenContext` covers the ordinary case, where a screen is on display
    /// and everything it fires belongs to it. This is for the case it cannot
    /// serve: requests built on one thread and fired concurrently, where the
    /// innermost pushed screen at task-creation time is whichever task happened
    /// to get there first. Attribution then has to travel with the request
    /// rather than with the caller.
    ///
    /// Takes precedence over `ScreenContext` — the swizzle only fills the
    /// screen in when it is absent.
    public static func tagged(_ request: URLRequest, screen: String) -> URLRequest {
        request.stamped(screen: screen, exchangeID: UUID())
    }

    // MARK: - Accessors used by the overlay

    /// Backing store. Exposed so `NetworkLensUI` can observe it without Core
    /// depending on the UI target.
    public static var store: ExchangeStore { state.store }

    public static var configuration: LensConfiguration { state.configuration }

    /// The capture decision for one host, and the only thing the interception
    /// layer should ask.
    ///
    /// `HostLock` wins over `capturedHostPatterns` when it is live: the app
    /// decided the patterns at `start()`, the tester decided the lock while
    /// looking at the traffic, and the later, more specific decision is the one
    /// that should hold.
    ///
    /// Records the host either way. This is the one place that sees a host
    /// before the decision to drop it, so it is the only place the Hosts list
    /// can be kept complete under a lock.
    public static func capturesHost(_ host: String?) -> Bool {
        HostInventory.shared.record(host)
        if let verdict = HostLock.shared.verdict(for: host) { return verdict }
        return state.configuration.capturesHost(host)
    }

    public static var isActive: Bool { state.isActive }

    /// Whether the gate is open. False in a build that linked the tool but was
    /// never allowed to run it — the App Store case.
    public static var isEnabled: Bool { state.configuration.isEnabled }

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
    private var _clock: LensClock = SystemClock()
    private var _uninterceptable: [String] = []
    private var _blockedRewrites: [String] = []
    private var _launchScenarioActivation: ScenarioActivation?

    /// Held for the process lifetime: the writer's only strong reference is
    /// its subscription token, and dropping it here would silently stop the
    /// trace one request in.
    private var _traceWriter: TraceWriter?

    let store = ExchangeStore()

    var uninterceptable: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _uninterceptable
    }

    var blockedRewrites: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _blockedRewrites
    }

    var launchScenarioActivation: ScenarioActivation? {
        lock.lock()
        defer { lock.unlock() }
        return _launchScenarioActivation
    }

    var traceWriter: TraceWriter? {
        lock.lock()
        defer { lock.unlock() }
        return _traceWriter
    }

    func clearTraceWriter() {
        lock.lock()
        let previous = _traceWriter
        _traceWriter = nil
        lock.unlock()
        previous?.detach()
    }

    func noteTraceWriter(_ writer: TraceWriter) {
        lock.lock()
        _traceWriter?.detach()
        _traceWriter = writer
        lock.unlock()
    }

    func noteLaunchScenario(_ activation: ScenarioActivation) {
        lock.lock()
        _launchScenarioActivation = activation
        lock.unlock()
    }

    func noteBlockedRewrite(_ description: String) {
        lock.lock()
        if !_blockedRewrites.contains(description) { _blockedRewrites.append(description) }
        lock.unlock()
    }

    func noteUninterceptable(_ description: String) {
        lock.lock()
        if !_uninterceptable.contains(description) { _uninterceptable.append(description) }
        lock.unlock()
    }

    var clock: LensClock {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _clock
        }
        set {
            lock.lock()
            _clock = newValue
            lock.unlock()
        }
    }

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
