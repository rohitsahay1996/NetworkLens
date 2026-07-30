//
//  Mocking.swift
//  NetworkLensNoOp
//
//  Created by Rohit Sahay on 30/07/26.
//

import Foundation

// MARK: - Mocking, breakpoints and persistence mirror
//
// Same contract as `NetworkLens.swift` in this target: every public symbol
// `NetworkLensCore` exposes is redeclared with an inert body, so release builds
// swap the import and compile unchanged. Nothing here does anything — a rule
// set built against this target is accepted, stored nowhere, and never served.

// MARK: - JSON pointers and patches

public struct JSONPointer: Codable, Sendable, Hashable, CustomStringConvertible {

    public let tokens: [String]

    public init(tokens: [String]) { self.tokens = tokens }

    public init(string: String) throws { self.tokens = [] }

    public var description: String { "" }
    public var isRoot: Bool { tokens.isEmpty }
    public func appending(_ token: String) -> JSONPointer { self }
    public var parent: JSONPointer? { nil }
    public var lastToken: String? { tokens.last }
}

public enum PatchError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidPointer(String)
    case pathNotFound(String)
    case typeMismatch(String)
    case indexOutOfRange(String)

    public var description: String { "" }
}

public struct PatchOp: Codable, Sendable, Hashable, Identifiable {

    public enum Kind: String, Codable, Sendable {
        case replace
        case remove
        case add
    }

    public let id: UUID
    public var kind: Kind
    public var path: JSONPointer
    public var value: JSONNode?

    public init(id: UUID = UUID(), kind: Kind, path: JSONPointer, value: JSONNode? = nil) {
        self.id = id
        self.kind = kind
        self.path = path
        self.value = value
    }

    public init(id: UUID = UUID(), kind: Kind, path: String, value: JSONNode? = nil) throws {
        self.init(id: id, kind: kind, path: JSONPointer(tokens: []), value: value)
    }

    public var summary: String { "" }
}

public enum JSONDiff {
    public static func ops(from original: JSONNode, to edited: JSONNode) -> [PatchOp] { [] }
}

extension JSONNode {
    public func applying(_ ops: [PatchOp]) throws -> JSONNode { self }
    public func applying(_ op: PatchOp) throws -> JSONNode { self }
    public func value(at pointer: JSONPointer) -> JSONNode? { nil }
    public var contentHash: String { "" }
    public var shapeHash: String { "" }
}

// MARK: - Edits

public struct EditRecord: Codable, Sendable, Hashable, Identifiable {

    public enum Stage: String, Codable, Sendable {
        case request
        case response
    }

    public let id: UUID
    public var stage: Stage
    public var originalHash: String
    public var ops: [PatchOp]
    public var perturbationName: String?
    public var shapeDrifted: Bool
    public var timestamp: Date

    public init(
        id: UUID = UUID(),
        stage: Stage,
        originalHash: String,
        ops: [PatchOp],
        perturbationName: String? = nil,
        shapeDrifted: Bool = false,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.stage = stage
        self.originalHash = originalHash
        self.ops = ops
        self.perturbationName = perturbationName
        self.shapeDrifted = shapeDrifted
        self.timestamp = timestamp
    }
}

// MARK: - Response payload

public struct ResponsePayload: @unchecked Sendable {

    public var response: HTTPURLResponse
    public var body: Data
    public var timing: Timing?
    public var bodyTruncated: Bool

    public init(
        response: HTTPURLResponse,
        body: Data,
        timing: Timing? = nil,
        bodyTruncated: Bool = false
    ) {
        self.response = response
        self.body = body
        self.timing = timing
        self.bodyTruncated = bodyTruncated
    }

    public var snapshot: ResponseSnapshot { ResponseSnapshot(statusCode: response.statusCode) }
    public func replacingBody(_ newBody: Data) -> ResponsePayload { self }
    public func replacingStatusCode(_ code: Int) -> ResponsePayload { self }
}

// MARK: - Request editing

public enum BodyPresentation: Sendable, Equatable {
    case json
    case text(String)
    case binary(byteCount: Int, hexPreview: String)
    case empty

    public var isEditable: Bool { self == .json }
}

extension URLRequest {
    public func replacingJSONBody(_ node: JSONNode) -> URLRequest { self }
    public func replacingBody(_ data: Data?) -> URLRequest { self }
    public var jsonBody: JSONNode? { nil }
    public var bodyIsEditableAsJSON: Bool { false }
    public func replacingQueryItem(name: String, value: String?) -> URLRequest { self }
    public func replacingHeader(name: String, value: String?) -> URLRequest { self }
    public var queryItems: [URLQueryItem] { [] }
}

extension Data {
    public func bodyPresentation(contentType: String? = nil) -> BodyPresentation { .empty }
}

// MARK: - Breakpoints

public enum BreakpointStage: String, Codable, Sendable, CaseIterable {
    case request, response, both

    public var pausesRequest: Bool { self == .request || self == .both }
    public var pausesResponse: Bool { self == .response || self == .both }
    public var label: String { rawValue }
}

public struct Breakpoint: Codable, Sendable, Hashable, Identifiable {

    public let id: UUID
    public var endpointKey: String
    public var stage: BreakpointStage
    public var isEnabled: Bool
    public var oneShot: Bool

    public init(
        id: UUID = UUID(),
        endpointKey: String,
        stage: BreakpointStage = .response,
        isEnabled: Bool = true,
        oneShot: Bool = false
    ) {
        self.id = id
        self.endpointKey = endpointKey
        self.stage = stage
        self.isEnabled = isEnabled
        self.oneShot = oneShot
    }
}

public struct Perturbation: Codable, Sendable, Hashable, Identifiable {

    public let id: UUID
    public var name: String
    public var endpointKey: String
    public var ops: [PatchOp]
    public var isEnabled: Bool
    public var qaVerified: Bool
    public var verifiedAgainstShape: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        endpointKey: String,
        ops: [PatchOp],
        isEnabled: Bool = false,
        qaVerified: Bool = false,
        verifiedAgainstShape: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.endpointKey = endpointKey
        self.ops = ops
        self.isEnabled = isEnabled
        self.qaVerified = qaVerified
        self.verifiedAgainstShape = verifiedAgainstShape
        self.createdAt = createdAt
    }

    public func apply(to tree: JSONNode) throws -> (result: JSONNode, shapeDrifted: Bool) {
        (tree, false)
    }
}

public final class Breakpoints: @unchecked Sendable {

    public static let shared = Breakpoints()

    public init() {}

    public var all: [Breakpoint] { [] }
    public var perturbations: [Perturbation] { [] }
    public var isRequestEditingEnabled: Bool { false }

    public func setRequestEditingEnabled(_ enabled: Bool) {}
    public func set(_ breakpoint: Breakpoint) {}
    public func remove(id: UUID) {}
    public func removeAll() {}
    public func disableAll() {}
    public func breakpoint(forEndpointKey key: String) -> Breakpoint? { nil }
    public func skipForSession(endpointKey: String) {}
    public func clearSkips() {}
    public func save(_ perturbation: Perturbation) {}
    public func removePerturbation(id: UUID) {}
    public func perturbations(forEndpointKey key: String) -> [Perturbation] { [] }
    public func enabledPerturbations(forEndpointKey key: String) -> [Perturbation] { [] }
    public func clearForRelaunch() {}
    public func clearRulesForRelaunch() {}
    public func replaceAll(_ breakpoints: [Breakpoint]) {}
    public func replacePerturbations(_ perturbations: [Perturbation]) {}
    public func shouldPauseRequest(for request: URLRequest) -> Bool { false }
    public func shouldPauseResponse(for request: URLRequest) -> Bool { false }
    public func didHit(endpointKey key: String) {}

    public func addObserver(_ observer: @escaping @Sendable () -> Void) -> ObservationToken {
        ObservationToken()
    }

    public final class ObservationToken: Sendable {
        init() {}
    }
}

public enum BreakpointPayload: @unchecked Sendable {
    case request(URLRequest)
    case response(ResponsePayload)

    public var stage: EditRecord.Stage {
        switch self {
        case .request: return .request
        case .response: return .response
        }
    }
}

public enum BreakpointOutcome: @unchecked Sendable {
    case proceed(BreakpointPayload)
    case abort(Error)
}

public actor BreakpointCoordinator {

    public static let shared = BreakpointCoordinator()

    public struct Pending: Identifiable, @unchecked Sendable {
        public let id: UUID
        public let owner: UUID
        public let exchangeID: UUID
        public let endpointKey: String
        public let payload: BreakpointPayload
        public let autoResumeAt: Date
        public let pausedAt: Date
        public var isAutoResumeEnabled: Bool = true

        public var stage: EditRecord.Stage { payload.stage }
    }

    public struct PresentationState: @unchecked Sendable {
        public var presented: Pending?
        public var queuedCount: Int
        public var position: Int
        public var total: Int
        public var heldByExchangeID: [UUID: UUID]

        public static let empty = PresentationState(
            presented: nil, queuedCount: 0, position: 0, total: 0,
            heldByExchangeID: [:]
        )
    }

    public enum ResumeReason: Sendable {
        case user, timedOut, cancelled, resumeAll
    }

    public init() {}

    public func setStateObserver(_ observer: @escaping @Sendable (PresentationState) -> Void) {}

    /// Returns immediately with the payload untouched. Nothing can hold a
    /// request in a release build, which is the entire point of this target.
    public func pause(
        _ payload: BreakpointPayload,
        owner: UUID,
        exchangeID: UUID,
        endpointKey: String,
        timeout: TimeInterval
    ) async -> BreakpointOutcome {
        .proceed(payload)
    }

    public func setAutoResumeEnabled(_ enabled: Bool, for id: UUID) {}
    public func stageEdit(_ payload: BreakpointPayload, for id: UUID) {}
    public func resolve(id: UUID, with outcome: BreakpointOutcome, reason: ResumeReason = .user) {}
    public func resume(id: UUID) {}
    public func resumeAll() {}
    public func resumeAllAndDisableBreakpoints() {}
    nonisolated public func dismissPending(for owner: UUID) {}

    public private(set) var lastResumeReason: ResumeReason?
    public var pendingCount: Int { 0 }
    public var presented: Pending? { nil }
}

// MARK: - Mocking

public struct MockResponse: Codable, Sendable, Hashable {

    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data
    public var delay: TimeInterval

    public init(
        statusCode: Int = 200,
        headers: [String: String] = [:],
        body: Data = Data(),
        delay: TimeInterval = 0
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.delay = delay
    }

    public static func json(
        _ string: String,
        statusCode: Int = 200,
        headers: [String: String] = [:],
        delay: TimeInterval = 0
    ) -> MockResponse {
        MockResponse(statusCode: statusCode, headers: headers, body: Data(string.utf8), delay: delay)
    }

    public static func json(
        _ node: JSONNode,
        statusCode: Int = 200,
        headers: [String: String] = [:],
        delay: TimeInterval = 0
    ) -> MockResponse {
        MockResponse(statusCode: statusCode, headers: headers, delay: delay)
    }

    public static func status(
        _ statusCode: Int,
        headers: [String: String] = [:],
        delay: TimeInterval = 0
    ) -> MockResponse {
        MockResponse(statusCode: statusCode, headers: headers, delay: delay)
    }

    public func payload(for url: URL, elapsed: TimeInterval? = nil) -> ResponsePayload {
        ResponsePayload(
            response: HTTPURLResponse(
                url: url, statusCode: statusCode, httpVersion: nil, headerFields: headers
            ) ?? HTTPURLResponse(),
            body: body
        )
    }
}

public struct MockFailure: Codable, Sendable, Hashable {

    public var errorCode: Int
    public var label: String
    public var delay: TimeInterval

    public init(code: URLError.Code, label: String, delay: TimeInterval = 0) {
        self.errorCode = code.rawValue
        self.label = label
        self.delay = delay
    }

    public init(errorCode: Int, label: String, delay: TimeInterval = 0) {
        self.errorCode = errorCode
        self.label = label
        self.delay = delay
    }

    public var urlError: URLError { URLError(URLError.Code(rawValue: errorCode)) }

    public static func offline(delay: TimeInterval = 0) -> MockFailure {
        MockFailure(code: .notConnectedToInternet, label: "offline", delay: delay)
    }

    public static func timedOut(delay: TimeInterval = 0) -> MockFailure {
        MockFailure(code: .timedOut, label: "timed out", delay: delay)
    }

    public static func connectionLost(delay: TimeInterval = 0) -> MockFailure {
        MockFailure(code: .networkConnectionLost, label: "connection lost", delay: delay)
    }

    public static func cannotFindHost(delay: TimeInterval = 0) -> MockFailure {
        MockFailure(code: .cannotFindHost, label: "DNS failure", delay: delay)
    }

    public static func secureConnectionFailed(delay: TimeInterval = 0) -> MockFailure {
        MockFailure(code: .secureConnectionFailed, label: "TLS failure", delay: delay)
    }

    public static var presets: [MockFailure] {
        [offline(), timedOut(), connectionLost(), cannotFindHost(), secureConnectionFailed()]
    }
}

public enum MockOutcome: Codable, Sendable, Hashable {
    case respond(MockResponse)
    case fail(MockFailure)
    case hang

    public var response: MockResponse? {
        if case .respond(let response) = self { return response }
        return nil
    }

    public var failure: MockFailure? {
        if case .fail(let failure) = self { return failure }
        return nil
    }

    public func settingDelay(_ delay: TimeInterval) -> MockOutcome { self }

    public static let delayPresets: [TimeInterval] = [0, 0.5, 1, 3, 10]

    public var isHang: Bool {
        if case .hang = self { return true }
        return false
    }

    public var delay: TimeInterval {
        switch self {
        case .respond(let response): return response.delay
        case .fail(let failure): return failure.delay
        case .hang: return 0
        }
    }

    public var label: String {
        switch self {
        case .respond(let response): return "\(response.statusCode)"
        case .fail(let failure): return failure.label
        case .hang: return "never answers"
        }
    }
}

public enum MockExhaustion: String, Codable, Sendable, CaseIterable {
    case repeatLast, loop, passThrough

    public var label: String {
        switch self {
        case .repeatLast: return "repeat last"
        case .loop: return "loop"
        case .passThrough: return "go live"
        }
    }
}

/// Mirror of the variant library. Nothing is ever served, so nothing switches.
/// Mirror of the match conditions. Nothing resolves here, so nothing matches.
public struct MockMatch: Codable, Sendable, Hashable {

    public var query: [String: String]
    public var headers: [String: String]
    public var bodyContains: String?

    public static let anyValue = "*"
    public static let any = MockMatch()

    public init(
        query: [String: String] = [:],
        headers: [String: String] = [:],
        bodyContains: String? = nil
    ) {
        self.query = query
        self.headers = headers
        self.bodyContains = bodyContains
    }

    public var isCatchAll: Bool { true }
    public var specificity: Int { 0 }
    public var summary: String? { nil }
    public func matches(_ request: URLRequest) -> Bool { false }
    public static func matchingQuery(of request: RequestSnapshot) -> MockMatch { .any }
}

public struct MockVariant: Codable, Sendable, Hashable, Identifiable {

    public let id: UUID
    public var name: String
    public var steps: [MockOutcome]
    public var exhaustion: MockExhaustion
    public var requestSample: Data?

    public init(
        id: UUID = UUID(),
        name: String,
        steps: [MockOutcome],
        exhaustion: MockExhaustion = .repeatLast,
        requestSample: Data? = nil
    ) {
        self.id = id
        self.name = name
        self.steps = steps.isEmpty ? [.respond(MockResponse())] : steps
        self.exhaustion = exhaustion
        self.requestSample = requestSample
    }

    public var isScripted: Bool { steps.count > 1 }

    public private(set) var variants: [MockVariant] = []
    public private(set) var activeVariantID: UUID = UUID()
    public var activeVariant: MockVariant {
        get { MockVariant(name: name ?? "default", steps: steps, exhaustion: exhaustion) }
        set {}
    }
    public mutating func activate(variantID: UUID) {}
    public mutating func addVariant(_ variant: MockVariant, activate: Bool = true) {}
    public mutating func updateVariant(_ variant: MockVariant) {}
    public mutating func removeVariant(id: UUID) {}
    public func outcome(forHit hit: Int) -> MockOutcome? { nil }
}

public struct MockRule: Codable, Sendable, Hashable, Identifiable {

    public let id: UUID
    public var endpointKey: String
    public var isEnabled: Bool
    public var match: MockMatch = .any
    public var steps: [MockOutcome]
    public var exhaustion: MockExhaustion
    public var name: String?
    public var requestSample: Data?

    public init(
        id: UUID = UUID(),
        endpointKey: String,
        steps: [MockOutcome],
        exhaustion: MockExhaustion = .repeatLast,
        isEnabled: Bool = true,
        name: String? = nil,
        requestSample: Data? = nil
    ) {
        self.id = id
        self.endpointKey = endpointKey
        self.steps = steps.isEmpty ? [.respond(MockResponse())] : steps
        self.exhaustion = exhaustion
        self.isEnabled = isEnabled
        self.name = name
        self.requestSample = requestSample
    }

    public init(
        id: UUID = UUID(),
        endpointKey: String,
        response: MockResponse,
        isEnabled: Bool = true,
        name: String? = nil,
        requestSample: Data? = nil
    ) {
        self.init(
            id: id, endpointKey: endpointKey, steps: [.respond(response)],
            isEnabled: isEnabled, name: name, requestSample: requestSample
        )
    }

    public init(
        id: UUID = UUID(),
        endpointKey: String,
        failure: MockFailure,
        isEnabled: Bool = true,
        name: String? = nil
    ) {
        self.init(
            id: id, endpointKey: endpointKey, steps: [.fail(failure)],
            isEnabled: isEnabled, name: name
        )
    }

    public var isScripted: Bool { steps.count > 1 }

    public func outcome(forHit hit: Int) -> MockOutcome? { nil }
}

public struct MockResolution: Sendable, Hashable {

    public let ruleID: UUID
    public let endpointKey: String
    public let name: String?
    public let outcome: MockOutcome
    public let hitIndex: Int

    public init(
        ruleID: UUID,
        endpointKey: String,
        name: String?,
        outcome: MockOutcome,
        hitIndex: Int
    ) {
        self.ruleID = ruleID
        self.endpointKey = endpointKey
        self.name = name
        self.outcome = outcome
        self.hitIndex = hitIndex
    }

    public var response: MockResponse? { outcome.response }
    public var failure: MockFailure? { outcome.failure }
}

/// Nothing ever hangs in a release build, so nothing is ever parked here.
public final class HangingRequests: @unchecked Sendable {

    public static let shared = HangingRequests()

    public struct ObservationToken: Sendable {
        public func invalidate() {}
    }

    public init() {}

    public var hanging: [UUID] { [] }
    public func register(_ exchangeID: UUID) {}
    public func unregister(_ exchangeID: UUID) {}
    public func isReleased(_ exchangeID: UUID) -> Bool { false }
    public func isHanging(_ exchangeID: UUID) -> Bool { false }
    public func release(_ exchangeID: UUID) {}
    public func releaseAll() {}
    public func addObserver(_ observer: @escaping () -> Void) -> ObservationToken {
        ObservationToken()
    }
}

public final class Mocks: @unchecked Sendable {

    public static let shared = Mocks()

    public init() {}

    public var all: [MockRule] { [] }
    public var isMockingEnabled: Bool { false }

    public var isServing: Bool { false }
    public func isServing(endpointKey: String) -> Bool { false }
    public func activateVariant(_ variantID: UUID, forRuleID ruleID: UUID) {}
    public func setMockingEnabled(_ enabled: Bool) {}
    public func set(_ rule: MockRule) {}
    public func remove(id: UUID) {}
    public func removeAll() {}
    public func replaceAll(_ rules: [MockRule]) {}
    public func disableAll() {}
    public func rule(forEndpointKey key: String) -> MockRule? { nil }
    public func clearForRelaunch() {}
    public func hitCount(forRuleID id: UUID) -> Int { 0 }
    public func hitCount(forEndpointKey key: String) -> Int { 0 }
    public func resetHitCounts() {}
    public func resolve(_ request: URLRequest) -> MockResolution? { nil }

    public func addObserver(_ observer: @escaping @Sendable () -> Void) -> ObservationToken {
        ObservationToken()
    }

    public final class ObservationToken: Sendable {
        init() {}
    }
}

// MARK: - Persistence

public struct LensSnapshot: Codable, Sendable, Hashable {

    public var mocks: [MockRule]
    public var breakpoints: [Breakpoint]
    public var perturbations: [Perturbation]
    public var isMockingEnabled: Bool

    public init(
        mocks: [MockRule] = [],
        breakpoints: [Breakpoint] = [],
        perturbations: [Perturbation] = [],
        isMockingEnabled: Bool = true
    ) {
        self.mocks = mocks
        self.breakpoints = breakpoints
        self.perturbations = perturbations
        self.isMockingEnabled = isMockingEnabled
    }

    public var isEmpty: Bool { true }
}

public protocol LensSnapshotStore: Sendable {
    func load() throws -> LensSnapshot?
    func save(_ snapshot: LensSnapshot) throws
    func clear() throws
}

public struct FileSnapshotStore: LensSnapshotStore {

    public let url: URL

    public init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL()
    }

    public static func defaultURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("session.json")
    }

    /// Never reads and never writes. A release build must not leave a rule
    /// file on a user's device.
    public func load() throws -> LensSnapshot? { nil }
    public func save(_ snapshot: LensSnapshot) throws {}
    public func clear() throws {}
}

public final class LensPersistence: @unchecked Sendable {

    public static let shared = LensPersistence()

    public init(store: LensSnapshotStore = FileSnapshotStore()) {}

    public func setStore(_ store: LensSnapshotStore) {}
    public func snapshot() -> LensSnapshot { LensSnapshot() }

    @discardableResult
    public func persist() -> Bool { false }

    public func restore(keepingActiveRules: Bool) {}
    public func beginAutosave() {}
    public func endAutosave() {}
    public func clear() {}
    public func flush() {}
}

// MARK: - Attribution and interception

public final class ScreenContext: @unchecked Sendable {

    public static let shared = ScreenContext()

    public init() {}

    public var current: String? { nil }
    public var trail: [String] { [] }

    @discardableResult
    public func push(_ name: String) -> UUID { UUID() }

    public func pop(_ token: UUID) {}
    public func removeAll() {}
}

public enum BodyReader {

    public struct Result: Sendable {
        public var data: Data
        public var truncated: Bool
        public var originalByteCount: Int?
    }

    public static func read(from request: URLRequest, cap: Int) -> Result? { nil }

    public static func drain(_ stream: InputStream, cap: Int) -> Result {
        Result(data: Data(), truncated: false, originalByteCount: nil)
    }

    public static func materialisingStreamBody(
        in request: URLRequest, cap: Int
    ) -> (request: URLRequest, capture: Result?) {
        (request, nil)
    }
}

public enum LensSwizzler {
    public static func installConfigurationHooks() {}
    public static func installTaskHooks() {}
}

/// Nothing is recorded in a release build, so nothing is replayable.
public final class ReplayStore: @unchecked Sendable {

    public static let shared = ReplayStore()

    public init(limit: Int = 200) {}

    public func record(_ request: URLRequest, for exchangeID: UUID) {}
    public func request(for exchangeID: UUID) -> URLRequest? { nil }
    public func canReplay(_ exchangeID: UUID) -> Bool { false }
    public func removeAll() {}
    public var count: Int { 0 }
}
