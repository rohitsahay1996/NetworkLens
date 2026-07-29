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

    public static func install(into config: URLSessionConfiguration) {}

    public static func record(_ exchange: NetworkExchange) {}

    public static var store: ExchangeStore { ExchangeStore() }

    public static var configuration: LensConfiguration { .default }

    public static var isActive: Bool { false }

    public static func endpointKey(for request: URLRequest) -> String { "" }

    public static func stats() -> SessionStats { SessionStats(exchanges: []) }

    #if canImport(UIKit)
    public static func attachOverlay(to scene: UIWindowScene) {}
    #endif
}

// MARK: - Configuration

public struct LensConfiguration: Sendable {
    public var matchers: [RequestMatcher]
    public var redactor: Redactor
    public var maxStoredExchanges: Int
    public var automaticScreenAttribution: Bool
    public var maxCapturedRequestBodyBytes: Int
    public var maxCapturedResponseBodyBytes: Int

    public init(
        matchers: [RequestMatcher] = [PathMatcher()],
        redactor: Redactor = DefaultRedactor(),
        maxStoredExchanges: Int = 500,
        automaticScreenAttribution: Bool = true,
        maxCapturedRequestBodyBytes: Int = 1_048_576,
        maxCapturedResponseBodyBytes: Int = 1_048_576
    ) {
        self.matchers = matchers
        self.redactor = redactor
        self.maxStoredExchanges = maxStoredExchanges
        self.automaticScreenAttribution = automaticScreenAttribution
        self.maxCapturedRequestBodyBytes = maxCapturedRequestBodyBytes
        self.maxCapturedResponseBodyBytes = maxCapturedResponseBodyBytes
    }

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

    public init(response: HTTPURLResponse, body: Data?, bodyTruncated: Bool = false) {
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

public enum Source: String, Codable, Sendable, CaseIterable {
    case live, mocked
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

    public init(
        id: UUID = UUID(),
        endpointKey: String,
        screen: String? = nil,
        request: RequestSnapshot,
        response: ResponseSnapshot? = nil,
        failure: FailureInfo? = nil,
        timing: Timing? = nil,
        startedAt: Date = Date(),
        source: Source = .live
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
    }

    public var isInFlight: Bool { false }

    public func completed(response: ResponseSnapshot, timing: Timing?) -> NetworkExchange { self }
    public func failed(_ failure: FailureInfo, timing: Timing? = nil) -> NetworkExchange { self }
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

public indirect enum JSONNode: Sendable, Hashable {
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
