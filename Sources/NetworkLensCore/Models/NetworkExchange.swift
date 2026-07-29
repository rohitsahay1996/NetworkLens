import Foundation

/// Where the bytes came from. Nothing produces `.mocked` in milestone 1, but
/// the field exists now so every UI surface renders the distinction from day
/// one and milestone 2 does not have to touch the storage or view layer.
public enum Source: String, Codable, Sendable, CaseIterable {
    case live
    case mocked
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
            source: source
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
            source: source
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
            source: source
        )
    }
}
