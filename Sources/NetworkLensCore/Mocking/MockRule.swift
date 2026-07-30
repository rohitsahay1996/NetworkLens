import Foundation

/// A rule that answers matching traffic from the device, with no network leg.
///
/// The unattended counterpart to a breakpoint. A breakpoint needs a human to
/// resume it, which makes it useless for a UI test, a demo, or an endpoint that
/// does not exist yet. A rule needs nobody.
public struct MockRule: Codable, Sendable, Hashable, Identifiable {

    public let id: UUID

    /// Matched against `NetworkExchange.endpointKey` — the same key breakpoints
    /// and stats use, so a rule survives path params and covers a GraphQL
    /// operation without special casing.
    public var endpointKey: String

    public var isEnabled: Bool

    /// Played one per hit, in order. Never empty.
    ///
    /// A single-element script is the ordinary "always answer this" rule; the
    /// list exists because the bugs worth reproducing are sequences — fail then
    /// succeed, 200 then 401, empty then populated. Expressing those as one
    /// rule keeps them reproducible; expressing them by hand-editing a rule
    /// between taps does not.
    public var steps: [MockOutcome]

    /// What happens after the last step. See `MockExhaustion`.
    public var exhaustion: MockExhaustion

    /// Short label for the rule list and for bug reports: "empty cart",
    /// "expired token".
    public var name: String?

    public init(
        id: UUID = UUID(),
        endpointKey: String,
        steps: [MockOutcome],
        exhaustion: MockExhaustion = .repeatLast,
        isEnabled: Bool = true,
        name: String? = nil
    ) {
        self.id = id
        self.endpointKey = endpointKey
        // An empty script would resolve to nothing on every hit, which reads as
        // "the mock is broken". A rule that exists always answers something.
        self.steps = steps.isEmpty ? [.respond(MockResponse())] : steps
        self.exhaustion = exhaustion
        self.isEnabled = isEnabled
        self.name = name
    }

    /// The common case: one canned response, served for every hit.
    public init(
        id: UUID = UUID(),
        endpointKey: String,
        response: MockResponse,
        isEnabled: Bool = true,
        name: String? = nil
    ) {
        self.init(
            id: id,
            endpointKey: endpointKey,
            steps: [.respond(response)],
            isEnabled: isEnabled,
            name: name
        )
    }

    /// One canned transport failure, served for every hit.
    public init(
        id: UUID = UUID(),
        endpointKey: String,
        failure: MockFailure,
        isEnabled: Bool = true,
        name: String? = nil
    ) {
        self.init(
            id: id,
            endpointKey: endpointKey,
            steps: [.fail(failure)],
            isEnabled: isEnabled,
            name: name
        )
    }

    public var isScripted: Bool { steps.count > 1 }

    /// The outcome for a 1-based hit, or `nil` when the script is spent and the
    /// rule has agreed to stand down.
    ///
    /// Pure — the hit accounting lives in `Mocks`, so this stays testable and
    /// can be called from a UI preview without moving a counter.
    public func outcome(forHit hit: Int) -> MockOutcome? {
        guard hit >= 1, !steps.isEmpty else { return nil }
        let index = hit - 1
        if index < steps.count { return steps[index] }

        switch exhaustion {
        case .repeatLast:
            return steps.last
        case .loop:
            return steps[index % steps.count]
        case .passThrough:
            return nil
        }
    }
}

/// A rule claiming one specific request.
///
/// Returned by `Mocks.resolve(_:)` and nothing else, because producing one has
/// a side effect: the rule's hit count moves.
public struct MockResolution: Sendable, Hashable {

    public let ruleID: UUID
    public let endpointKey: String
    public let name: String?
    public let outcome: MockOutcome
    /// 1 for the first request this rule claimed in the session.
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
