//
//  NetworkLens.swift
//  NetworkLensNoOp
//
//  Created by Rohit Sahay on 29/07/26.
//

import Foundation

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Umbrella API mirror
//
// Every public symbol NetworkLensUI + NetworkLensCore expose is redeclared here
// with an inert body, so a release build swaps `import NetworkLensUI` for
// `import NetworkLensNoOp` and every call site compiles unchanged — no `#if`
// guards in host code.
//
// This target has no dependency on NetworkLensCore. That is deliberate: linking
// Core would defeat the point, which is that release builds ship none of the
// capture machinery.

/// Inert mirror of `NetworkLens`.
public enum NetworkLens {

    public static func start(configuration: LensConfiguration = .default) {}

    @discardableResult
    public static func install(into config: URLSessionConfiguration) -> Bool { false }

    public static func canIntercept(_ config: URLSessionConfiguration) -> Bool { false }

    public static var uninterceptable: [String] { [] }

    public static var blockedRewrites: [String] { [] }

    public static func record(_ exchange: NetworkExchange) {}

    /// Always a miss, and says so with an empty list rather than pretending it
    /// applied. A UI test asserting `isApplied` against a release build should
    /// fail loudly — that build has no mocking engine to apply anything with.
    @discardableResult
    public static func applyScenario(named name: String) -> ScenarioActivation {
        .noSuchScenario(name: name, available: [])
    }

    public static var launchScenarioActivation: ScenarioActivation? { nil }

    /// Always nil: nothing here writes a trace, so there is no path to report.
    public static var traceURL: URL? { nil }

    public static func flushTrace() {}

    /// Hands the request straight back. Nothing reads the tag in a release
    /// build, and a stamped `URLProtocol` property on a request nobody
    /// intercepts is dead weight on every call site that attributes traffic.
    public static func tagged(_ request: URLRequest, screen: String) -> URLRequest { request }

    public enum ReplayError: Error, Equatable, Sendable {
        case originalRequestUnavailable
    }

    /// Nothing is captured in a release build, so nothing can be sent again.
    @discardableResult
    public static func replay(_ exchange: NetworkExchange) async throws -> NetworkExchange? {
        throw ReplayError.originalRequestUnavailable
    }

    public static func canReplay(_ exchange: NetworkExchange) -> Bool { false }

    public static var clock: LensClock {
        get { SystemClock() }
        set {}
    }

    public static var store: ExchangeStore { ExchangeStore() }

    public static var configuration: LensConfiguration { .default }

    public static var isActive: Bool { false }

    public static func endpointKey(for request: URLRequest) -> String { "" }

    public static func stats() -> SessionStats { SessionStats(exchanges: []) }

    #if canImport(UIKit)
    public static func attachOverlay(to scene: UIWindowScene) {}

    public static func detachOverlay(from scene: UIWindowScene) {}

    /// Always `false` here: there is no overlay to attach in a release build.
    ///
    /// Worth stating because the real one returns `false` only when it finds no
    /// scene. Host code must therefore never retry until this returns `true` —
    /// that loop would never end in release. The README's legacy UIKit snippet
    /// makes a single deferred attempt for this reason.
    @discardableResult
    public static func attachOverlayToActiveScene() -> Bool { false }
    #endif
}

// MARK: - Trace

public struct TraceOptions: Sendable {
    public var url: URL?
    public var maxBytes: Int
    public var includesBodies: Bool

    public init(url: URL? = nil, maxBytes: Int = 32 * 1_048_576, includesBodies: Bool = true) {
        self.url = url
        self.maxBytes = maxBytes
        self.includesBodies = includesBodies
    }

    public static func defaultURL() -> URL { URL(fileURLWithPath: "/dev/null") }
}

// MARK: - Configuration

public struct LensConfiguration: Sendable {
    public var matchers: [RequestMatcher]
    public var redactor: Redactor
    public var maxStoredExchanges: Int
    public var automaticScreenAttribution: Bool
    public var maxCapturedRequestBodyBytes: Int
    public var maxCapturedResponseBodyBytes: Int
    public var productionHostPatterns: [String]
    public var keepBreakpointsAcrossLaunches: Bool
    public var persistsRules: Bool
    public var redactsPersistedRules: Bool
    public var trace: TraceOptions?

    public init(
        matchers: [RequestMatcher] = [PathMatcher()],
        redactor: Redactor = DefaultRedactor(),
        maxStoredExchanges: Int = 500,
        automaticScreenAttribution: Bool = true,
        maxCapturedRequestBodyBytes: Int = 1_048_576,
        maxCapturedResponseBodyBytes: Int = 1_048_576,
        productionHostPatterns: [String] = [],
        keepBreakpointsAcrossLaunches: Bool = false,
        persistsRules: Bool = false,
        redactsPersistedRules: Bool = true,
        trace: TraceOptions? = nil
    ) {
        self.matchers = matchers
        self.redactor = redactor
        self.maxStoredExchanges = maxStoredExchanges
        self.automaticScreenAttribution = automaticScreenAttribution
        self.maxCapturedRequestBodyBytes = maxCapturedRequestBodyBytes
        self.maxCapturedResponseBodyBytes = maxCapturedResponseBodyBytes
        self.productionHostPatterns = productionHostPatterns
        self.keepBreakpointsAcrossLaunches = keepBreakpointsAcrossLaunches
        self.persistsRules = persistsRules
        self.redactsPersistedRules = redactsPersistedRules
        self.trace = trace
    }

    /// Always false here. Nothing in this target can arm a breakpoint, so
    /// there is nothing for the production guard to refuse.
    public func isProductionHost(_ host: String?) -> Bool { false }

    public static var `default`: LensConfiguration { LensConfiguration() }

    public static func graphQL(paths: Set<String> = ["/graphql"]) -> LensConfiguration {
        LensConfiguration()
    }
}

// MARK: - Matching

public protocol RequestMatcher: Sendable {
    var identifier: String { get }
    func endpointKey(for request: URLRequest) -> String?
}

public struct MatcherChain: Sendable {
    public let matchers: [RequestMatcher]
    public init(_ matchers: [RequestMatcher]) { self.matchers = matchers }
    public func endpointKey(for request: URLRequest) -> String { "" }
}

public struct PathMatcher: RequestMatcher {
    public let identifier: String
    public let placeholder: String
    public let hosts: Set<String>

    public init(
        identifier: String = "path",
        placeholder: String = "{id}",
        hosts: Set<String> = []
    ) {
        self.identifier = identifier
        self.placeholder = placeholder
        self.hosts = hosts
    }

    public func endpointKey(for request: URLRequest) -> String? { nil }

    public static func template(forPath path: String, placeholder: String = "{id}") -> String { "" }
}

public struct GraphQLMatcher: RequestMatcher {
    public let identifier: String
    public let paths: Set<String>

    public init(identifier: String = "graphql", paths: Set<String> = ["/graphql"]) {
        self.identifier = identifier
        self.paths = paths
    }

    public func endpointKey(for request: URLRequest) -> String? { nil }
}

public struct RegexMatcher: RequestMatcher {
    public struct Rule: Sendable {
        public let regex: NSRegularExpression
        public let template: String
        public let method: String?

        public init(pattern: String, template: String, method: String? = nil) throws {
            self.regex = try NSRegularExpression(pattern: pattern, options: [])
            self.template = template
            self.method = method
        }
    }

    public let identifier: String
    public let rules: [Rule]

    public init(identifier: String = "regex", rules: [Rule]) {
        self.identifier = identifier
        self.rules = rules
    }

    public func endpointKey(for request: URLRequest) -> String? { nil }
}

// MARK: - Redaction

public protocol Redactor: Sendable {
    func redact(_ request: RequestSnapshot) -> RequestSnapshot
    func redact(_ response: ResponseSnapshot) -> ResponseSnapshot
}

public struct NoRedactor: Redactor {
    public init() {}
    public func redact(_ request: RequestSnapshot) -> RequestSnapshot { request }
    public func redact(_ response: ResponseSnapshot) -> ResponseSnapshot { response }
}

public struct DefaultRedactor: Redactor {
    public static let defaultHeaderNames: Set<String> = [
        "authorization", "cookie", "set-cookie", "x-api-key",
    ]
    public static let defaultBodyKeyTerms: Set<String> = [
        "card", "cvv", "pan", "password", "token", "secret",
    ]
    public static let defaultPlaceholder = "<redacted>"

    public let headerNames: Set<String>
    public let bodyKeyTerms: Set<String>
    public let placeholder: String

    public init(
        headerNames: Set<String> = DefaultRedactor.defaultHeaderNames,
        bodyKeyTerms: Set<String> = DefaultRedactor.defaultBodyKeyTerms,
        placeholder: String = DefaultRedactor.defaultPlaceholder
    ) {
        self.headerNames = headerNames
        self.bodyKeyTerms = bodyKeyTerms
        self.placeholder = placeholder
    }

    public func redact(_ request: RequestSnapshot) -> RequestSnapshot { request }
    public func redact(_ response: ResponseSnapshot) -> ResponseSnapshot { response }
    public func matches(key: String) -> Bool { false }
}

// MARK: - Models

public struct RequestSnapshot: Codable, Sendable, Hashable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    public var bodyTruncated: Bool
    public var originalBodyByteCount: Int?

    public init(
        method: String,
        url: URL,
        headers: [String: String] = [:],
        body: Data? = nil,
        bodyTruncated: Bool = false,
        originalBodyByteCount: Int? = nil
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.bodyTruncated = bodyTruncated
        self.originalBodyByteCount = originalBodyByteCount
    }

    public init(request: URLRequest) {
        self.init(
            method: request.httpMethod ?? "GET",
            url: request.url ?? URL(string: "about:blank")!
        )
    }

    public func header(_ name: String) -> String? { nil }
}

public struct ResponseSnapshot: Codable, Sendable, Hashable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data?
    public var bodyTruncated: Bool
    public var originalBodyByteCount: Int?
    public var mimeType: String?

    public init(
        statusCode: Int,
        headers: [String: String] = [:],
        body: Data? = nil,
        bodyTruncated: Bool = false,
        originalBodyByteCount: Int? = nil,
        mimeType: String? = nil
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.bodyTruncated = bodyTruncated
        self.originalBodyByteCount = originalBodyByteCount
        self.mimeType = mimeType
    }

    public init(
        response: HTTPURLResponse,
        body: Data?,
        bodyTruncated: Bool = false,
        originalBodyByteCount: Int? = nil
    ) {
        self.init(statusCode: response.statusCode)
    }

    public func header(_ name: String) -> String? { nil }
    public var isSuccess: Bool { (200..<300).contains(statusCode) }
}

public struct Timing: Codable, Sendable, Hashable {
    public var total: TimeInterval
    public var domainLookup: TimeInterval?
    public var connect: TimeInterval?
    public var tls: TimeInterval?
    public var requestUpload: TimeInterval?
    public var serverThink: TimeInterval?
    public var responseDownload: TimeInterval?
    public var isReusedConnection: Bool
    public var isProxyConnection: Bool
    public var fromCache: Bool
    public var networkProtocolName: String?

    public init(
        total: TimeInterval,
        domainLookup: TimeInterval? = nil,
        connect: TimeInterval? = nil,
        tls: TimeInterval? = nil,
        requestUpload: TimeInterval? = nil,
        serverThink: TimeInterval? = nil,
        responseDownload: TimeInterval? = nil,
        isReusedConnection: Bool = false,
        isProxyConnection: Bool = false,
        fromCache: Bool = false,
        networkProtocolName: String? = nil
    ) {
        self.total = total
        self.domainLookup = domainLookup
        self.connect = connect
        self.tls = tls
        self.requestUpload = requestUpload
        self.serverThink = serverThink
        self.responseDownload = responseDownload
        self.isReusedConnection = isReusedConnection
        self.isProxyConnection = isProxyConnection
        self.fromCache = fromCache
        self.networkProtocolName = networkProtocolName
    }

    public init?(metrics: URLSessionTaskMetrics) { return nil }
}

public struct FailureInfo: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case transport, clientError, serverError, decode
    }

    public var kind: Kind
    public var domain: String?
    public var code: Int?
    public var message: String

    public init(kind: Kind, domain: String? = nil, code: Int? = nil, message: String) {
        self.kind = kind
        self.domain = domain
        self.code = code
        self.message = message
    }

    public init(error: Error) {
        self.init(kind: .transport, message: "")
    }

    public init?(statusCode: Int) { return nil }
}

public enum Source: Codable, Sendable, Hashable {
    case live
    case mocked
    case edited
    case perturbed(name: String)

    public var label: String {
        switch self {
        case .live: return "live"
        case .mocked: return "mocked"
        case .edited: return "edited"
        case .perturbed(let name): return name
        }
    }

    public var isSynthetic: Bool {
        if case .live = self { return false }
        return true
    }

    public static var displayCases: [Source] {
        [.live, .mocked, .edited, .perturbed(name: "perturbed")]
    }
}

public struct NetworkExchange: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public let endpointKey: String
    public let screen: String?
    public let request: RequestSnapshot
    public let response: ResponseSnapshot?
    public let failure: FailureInfo?
    public let timing: Timing?
    public let startedAt: Date
    public let source: Source
    public let edits: [EditRecord]
    public var isMockServed: Bool
    public var replayOf: UUID?
    public var isReplay: Bool { false }

    public init(
        id: UUID = UUID(),
        endpointKey: String,
        screen: String? = nil,
        request: RequestSnapshot,
        response: ResponseSnapshot? = nil,
        failure: FailureInfo? = nil,
        timing: Timing? = nil,
        startedAt: Date = Date(),
        source: Source = .live,
        edits: [EditRecord] = [],
        isMockServed: Bool = false,
        replayOf: UUID? = nil
    ) {
        self.id = id
        self.endpointKey = endpointKey
        self.screen = screen
        self.request = request
        self.response = response
        self.failure = failure
        self.timing = timing
        self.startedAt = startedAt
        self.source = source
        self.edits = edits
        self.isMockServed = isMockServed
        self.replayOf = replayOf
    }

    public var isInFlight: Bool { false }

    public func completed(response: ResponseSnapshot, timing: Timing?) -> NetworkExchange { self }
    public func failed(_ failure: FailureInfo, timing: Timing? = nil) -> NetworkExchange { self }
    public func replacingRequest(_ request: RequestSnapshot, source: Source) -> NetworkExchange { self }
    public func withSource(_ source: Source) -> NetworkExchange { self }
    public func servedFromMock() -> NetworkExchange { self }
    public func addingSource(_ source: Source) -> NetworkExchange { self }
    public func resumedToNetwork() -> NetworkExchange { self }
    public func loggingEdit(_ record: EditRecord) -> NetworkExchange { self }
    public func redacted(by redactor: Redactor) -> NetworkExchange { self }
}

public struct SessionStats: Sendable, Hashable {
    public struct EndpointStat: Sendable, Hashable, Identifiable {
        public var endpointKey: String
        public var count: Int
        public var failureCount: Int
        public var averageDuration: TimeInterval?
        public var id: String { endpointKey }
    }

    public var totalRequests: Int = 0
    public var inFlightCount: Int = 0
    public var endpoints: [EndpointStat] = []
    public var failuresByKind: [FailureInfo.Kind: Int] = [:]
    public var countsBySource: [Source: Int] = [:]

    public var totalFailures: Int { 0 }

    public init(exchanges: [NetworkExchange]) {}
}

// MARK: - Storage

public final class ExchangeStore: @unchecked Sendable {
    public private(set) var capacity: Int

    public init(capacity: Int = 500) { self.capacity = capacity }

    public var exchanges: [NetworkExchange] { [] }
    public var count: Int { 0 }
    public func exchange(id: UUID) -> NetworkExchange? { nil }
    public func record(_ exchange: NetworkExchange) {}

    @discardableResult
    public func update(id: UUID, transform: (NetworkExchange) -> NetworkExchange) -> Bool { false }

    public func removeAll() {}
    public func setCapacity(_ newCapacity: Int) { capacity = newCapacity }

    public func addObserver(_ observer: @escaping @Sendable () -> Void) -> ObservationToken {
        ObservationToken()
    }

    public final class ObservationToken: Sendable {
        init() {}
    }
}

// MARK: - JSON

public indirect enum JSONNode: Sendable, Hashable, Codable {
    case object([Entry])
    case array([JSONNode])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    public struct Entry: Sendable, Hashable {
        public var key: String
        public var value: JSONNode

        public init(key: String, value: JSONNode) {
            self.key = key
            self.value = value
        }
    }

    /// Core round-trips a tree through real JSON. Here the conformance exists
    /// only so `PatchOp` and `Perturbation` stay `Codable` for host call
    /// sites; nothing in this target has a tree worth encoding.
    public init(from decoder: Decoder) throws { self = .null }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encodeNil()
    }

    public subscript(key: String) -> JSONNode? { nil }
    public subscript(index: Int) -> JSONNode? { nil }
    public var stringValue: String? { nil }
    public var numberLiteral: String? { nil }
    public var doubleValue: Double? { nil }
    public var boolValue: Bool? { nil }
    public var isNull: Bool { false }
    public var isContainer: Bool { false }
}

public enum JSONNodeParser {
    public struct Error: Swift.Error, CustomStringConvertible, Sendable {
        public let message: String
        public let byteOffset: Int
        public var description: String { message }
    }

    public static func parse(_ data: Data) throws -> JSONNode { .null }
    public static func parse(_ string: String) throws -> JSONNode { .null }
}

public enum JSONNodeSerializer {
    public enum Format: Sendable { case compact, pretty }

    public static func string(from node: JSONNode, format: Format = .compact) -> String { "" }
    public static func data(from node: JSONNode, format: Format = .compact) -> Data { Data() }
}

/// Mirror of the clock seam. A release build has nothing that waits.
public protocol LensClock: Sendable {
    var now: Date { get }
    func sleep(for interval: TimeInterval) async throws
}

public struct SystemClock: LensClock {
    public init() {}
    public var now: Date { Date() }
    public func sleep(for interval: TimeInterval) async throws {}
}

public final class TestClock: LensClock, @unchecked Sendable {
    public init(now: Date = Date(timeIntervalSince1970: 0)) {}
    public var now: Date { Date(timeIntervalSince1970: 0) }
    public var sleeperCount: Int { 0 }
    public func sleep(for interval: TimeInterval) async throws {}
    public func advance(by interval: TimeInterval) {}
    public func advance(by interval: TimeInterval, afterSleepers count: Int) async throws {}
}

/// Mirror of the header seam. A networking module can set these
/// unconditionally; in a release build nothing reads them, and they are still
/// stripped so a header the app never meant to send cannot escape.
public enum LensHeaders {
    public static let screen = "X-NetworkLens-Screen"
}
