//
//  NetworkExchange.swift
//  NetworkLensCore
//
//  Created by Rohit Sahay on 29/07/26.
//

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

    /// Combines two provenances into one, keeping both claims.
    ///
    /// Overwriting loses the part that matters. A mocked response that a saved
    /// perturbation then rewrote used to report only `perturbed`, so a bug
    /// report could not say whether the bytes came from a server or from the
    /// device — which is the first thing anyone reading it needs to know.
    ///
    /// `live` never survives contact with anything else: once a payload has
    /// been touched, calling it live would be a lie.
    public func combined(with next: Source) -> Source {
        switch (self, next) {
        case (.live, _):
            return next
        case (_, .live):
            return self
        case (.mocked, .mocked):
            return .mocked
        default:
            // Later provenance names what the reader sees now; the trail of how
            // it got there lives in `NetworkExchange.edits`.
            return next
        }
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
    /// The payload no longer had the shape this perturbation was captured
    /// against — the contract moved under a saved edit.
    ///
    /// Recorded rather than used to skip the edit: an edit that silently
    /// declines to apply is indistinguishable from a broken tool, while one
    /// that applies and says so sends the tester to look at the contract.
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

    /// These bytes were produced on the device, never received.
    ///
    /// Separate from `source`, which carries the *latest* label and moves when
    /// a perturbation rewrites a mocked response. Whether the network was
    /// involved cannot be relabelled away — it is the first thing a bug report
    /// needs and the last thing that should be inferred from a display string.
    public var isMockServed: Bool

    /// The exchange this one was fired from, when a tester replayed it.
    ///
    /// Kept so a row can say it is a repeat rather than something the app did,
    /// which matters most on the screens replay is for: four calls, three of
    /// them replayed, one real.
    public var replayOf: UUID?

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

    /// True when this request was fired by the tool rather than the app.
    public var isReplay: Bool { replayOf != nil }

    /// True until a response or failure lands.
    public var isInFlight: Bool { response == nil && failure == nil }

    /// `endpointKey` without its leading HTTP method, so a key a matcher did not build from the method — `"GRAPHQL OpName"` — comes back whole.
    public var endpointPath: String {
        let prefix = request.method.uppercased() + " "
        guard endpointKey.hasPrefix(prefix) else { return endpointKey }
        return String(endpointKey.dropFirst(prefix.count))
    }

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
            edits: edits,
            isMockServed: isMockServed,
            replayOf: replayOf
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
            edits: edits,
            isMockServed: isMockServed,
            replayOf: replayOf
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
            edits: edits,
            isMockServed: isMockServed,
            replayOf: replayOf
        )
    }

    /// Copy that records these bytes as device-produced.
    public func servedFromMock() -> NetworkExchange {
        var copy = withSource(source.combined(with: .mocked))
        copy.isMockServed = true
        return copy
    }

    /// Copy that hands the request back to the network.
    ///
    /// A released hang was claimed by a mock and then resumed to the real
    /// server, so the bytes about to arrive are the server's — the device
    /// origin has to be given back, not just relabelled.
    public func resumedToNetwork() -> NetworkExchange {
        var copy = withSource(.live)
        copy.isMockServed = false
        return copy
    }

    /// Copy whose provenance label folds in `source` rather than replacing it.
    public func addingSource(_ source: Source) -> NetworkExchange {
        withSource(self.source.combined(with: source))
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
            edits: edits,
            isMockServed: isMockServed,
            replayOf: replayOf
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
            edits: edits + [record],
            isMockServed: isMockServed,
            replayOf: replayOf
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
            edits: edits,
            isMockServed: isMockServed,
            replayOf: replayOf
        )
    }
}
