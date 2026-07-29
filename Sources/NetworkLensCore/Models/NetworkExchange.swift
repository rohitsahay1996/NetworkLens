import Foundation

/// Where the bytes came from.
///
/// Not `RawRepresentable` any more — `.perturbed` carries the perturbation name
/// so a row can say which one was applied. Use `label` wherever a display or
/// grouping string is needed.
public enum Source: Codable, Sendable, Hashable {
    case live
    case mocked
    /// Hand-edited at a breakpoint, one time only.
    case edited
    /// A saved, replayable `Perturbation` was applied.
    case perturbed(name: String)

    /// Stable short name for display and grouping.
    public var label: String {
        switch self {
        case .live: return "live"
        case .mocked: return "mocked"
        case .edited: return "edited"
        case .perturbed(let name): return name
        }
    }

    /// True for anything the tool changed. The distinction an engineer reading
    /// a bug report actually cares about.
    public var isSynthetic: Bool {
        if case .live = self { return false }
        return true
    }

    /// Every case, with a placeholder name for the associated-value one, for
    /// legends and filter pickers.
    public static var displayCases: [Source] {
        [.live, .mocked, .edited, .perturbed(name: "perturbed")]
    }
}

/// One applied edit, kept on the exchange so a bug report can prove what the
/// tool changed and what the server actually sent.
public struct EditRecord: Codable, Sendable, Hashable, Identifiable {

    public enum Stage: String, Codable, Sendable {
        case request
        case response
    }

    public let id: UUID
    public var stage: Stage
    /// Hash of the payload before editing, so the original is identifiable
    /// without storing it twice.
    public var originalHash: String
    public var ops: [PatchOp]
    /// Set when the edit came from a saved perturbation rather than by hand.
    public var perturbationName: String?
    public var timestamp: Date

    public init(
        id: UUID = UUID(),
        stage: Stage,
        originalHash: String,
        ops: [PatchOp],
        perturbationName: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.stage = stage
        self.originalHash = originalHash
        self.ops = ops
        self.perturbationName = perturbationName
        self.timestamp = timestamp
    }
}

/// One request/response pair, start to finish.
///
/// Immutable by design. Interception records a request-only exchange and then
/// replaces it via `completed(...)` / `failed(...)` once the task finishes,
/// so a partially observed exchange is never mutated in place under a reader.
public struct NetworkExchange: Identifiable, Codable, Sendable, Hashable {

    public let id: UUID

    /// Stable grouping key from the winning `RequestMatcher`, e.g.
    /// `"GET /users/{id}"`. Falls back to method + path when no matcher claims
    /// the request, so this is never empty.
    public let endpointKey: String

    /// Screen that fired the request, captured at task-creation time on the
    /// caller's thread. `nil` when attribution is off or the screen is unknown.
    public let screen: String?

    public let request: RequestSnapshot
    public let response: ResponseSnapshot?
    public let failure: FailureInfo?
    public let timing: Timing?
    public let startedAt: Date
    public let source: Source

    /// Audit log of every edit applied to this exchange. Lands in the trace
    /// export and the bug report bundle.
    public let edits: [EditRecord]

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
        edits: [EditRecord] = []
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
    }

    /// True until a response or failure lands.
    public var isInFlight: Bool { response == nil && failure == nil }

    /// Copy carrying the finished response. Derives the 4xx/5xx failure bucket
    /// so callers cannot forget to.
    public func completed(response: ResponseSnapshot, timing: Timing?) -> NetworkExchange {
        NetworkExchange(
            id: id,
            endpointKey: endpointKey,
            screen: screen,
            request: request,
            response: response,
            failure: FailureInfo(statusCode: response.statusCode),
            timing: timing,
            startedAt: startedAt,
            source: source,
            edits: edits
        )
    }

    /// Copy carrying a transport failure.
    public func failed(_ failure: FailureInfo, timing: Timing? = nil) -> NetworkExchange {
        NetworkExchange(
            id: id,
            endpointKey: endpointKey,
            screen: screen,
            request: request,
            response: response,
            failure: failure,
            timing: timing ?? self.timing,
            startedAt: startedAt,
            source: source,
            edits: edits
        )
    }

    /// Copy carrying an edited request, from a request-stage breakpoint.
    public func replacingRequest(_ request: RequestSnapshot, source: Source) -> NetworkExchange {
        NetworkExchange(
            id: id,
            endpointKey: endpointKey,
            screen: screen,
            request: request,
            response: response,
            failure: failure,
            timing: timing,
            startedAt: startedAt,
            source: source,
            edits: edits
        )
    }

    /// Copy with a different provenance, for when a breakpoint changed a payload.
    public func withSource(_ source: Source) -> NetworkExchange {
        NetworkExchange(
            id: id,
            endpointKey: endpointKey,
            screen: screen,
            request: request,
            response: response,
            failure: failure,
            timing: timing,
            startedAt: startedAt,
            source: source,
            edits: edits
        )
    }

    /// Copy with one more entry in the audit log.
    public func loggingEdit(_ record: EditRecord) -> NetworkExchange {
        NetworkExchange(
            id: id,
            endpointKey: endpointKey,
            screen: screen,
            request: request,
            response: response,
            failure: failure,
            timing: timing,
            startedAt: startedAt,
            source: source,
            edits: edits + [record]
        )
    }

    /// Copy with redacted snapshots. Applied on the way into storage.
    public func redacted(by redactor: Redactor) -> NetworkExchange {
        NetworkExchange(
            id: id,
            endpointKey: endpointKey,
            screen: screen,
            request: redactor.redact(request),
            response: response.map { redactor.redact($0) },
            failure: failure,
            timing: timing,
            startedAt: startedAt,
            source: source,
            edits: edits
        )
    }
}
