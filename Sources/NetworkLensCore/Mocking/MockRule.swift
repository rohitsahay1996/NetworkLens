//
//  MockRule.swift
//  NetworkLensCore
//
//  Created by Rohit Sahay on 30/07/26.
//

import Foundation

/// A rule that answers matching traffic from the device, with no network leg.
///
/// The unattended counterpart to a breakpoint. A breakpoint needs a human to
/// resume it, which makes it useless for a UI test, a demo, or an endpoint that
/// does not exist yet. A rule needs nobody.
///
/// A rule holds many named `variants` with exactly one active, and claims an
/// endpoint either wholly or under `match` conditions.
///
/// Several rules may share an `endpointKey` when their conditions differ —
/// `page=1` and `page=2` — but never ambiguously: `Mocks.resolve` picks the
/// narrowest match, so the answer never depends on which rule was armed first.
/// "Which of these is winning?" is not a question a debugging tool should pose.
public struct MockRule: Codable, Sendable, Hashable, Identifiable {

    public let id: UUID

    /// Matched against `NetworkExchange.endpointKey` — the same key breakpoints
    /// and stats use, so a rule survives path params and covers a GraphQL
    /// operation without special casing.
    public var endpointKey: String

    public var isEnabled: Bool

    /// Extra conditions narrowing this rule to some of the endpoint's traffic.
    ///
    /// `.any` — the default — is the old behaviour: one rule answers everything
    /// the key matches. Identity is `endpointKey` *plus* this, so `page=1` and
    /// `page=2` are two rules rather than one overwriting the other.
    public var match: MockMatch

    /// The library of answers for this endpoint. Never empty.
    public private(set) var variants: [MockVariant]

    /// Which one is being served.
    public private(set) var activeVariantID: UUID

    public init(
        id: UUID = UUID(),
        endpointKey: String,
        variants: [MockVariant],
        activeVariantID: UUID? = nil,
        isEnabled: Bool = true,
        match: MockMatch = .any
    ) {
        self.id = id
        self.endpointKey = endpointKey
        self.match = match
        let resolved = variants.isEmpty
            ? [MockVariant(name: "default", steps: [.respond(MockResponse())])]
            : variants
        self.variants = resolved
        // Falls back to the first rather than trusting the id: an active id
        // naming a variant that is not here would serve nothing at all.
        self.activeVariantID = resolved.contains { $0.id == activeVariantID }
            ? activeVariantID! : resolved[0].id
        self.isEnabled = isEnabled
    }

    /// A single script, unnamed. The shape most rules are still born in.
    public init(
        id: UUID = UUID(),
        endpointKey: String,
        steps: [MockOutcome],
        exhaustion: MockExhaustion = .repeatLast,
        isEnabled: Bool = true,
        name: String? = nil,
        requestSample: Data? = nil,
        match: MockMatch = .any
    ) {
        self.init(
            id: id,
            endpointKey: endpointKey,
            variants: [
                MockVariant(
                    name: name ?? "default",
                    steps: steps,
                    exhaustion: exhaustion,
                    requestSample: requestSample
                )
            ],
            isEnabled: isEnabled,
            match: match
        )
    }

    /// The common case: one canned response, served for every hit.
    public init(
        id: UUID = UUID(),
        endpointKey: String,
        response: MockResponse,
        isEnabled: Bool = true,
        name: String? = nil,
        requestSample: Data? = nil,
        match: MockMatch = .any
    ) {
        self.init(
            id: id,
            endpointKey: endpointKey,
            steps: [.respond(response)],
            isEnabled: isEnabled,
            name: name,
            requestSample: requestSample,
            match: match
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

    // MARK: - The active variant

    /// Always present: `variants` is never empty and `activeVariantID` is
    /// validated against it on every mutation.
    public var activeVariant: MockVariant {
        get { variants.first { $0.id == activeVariantID } ?? variants[0] }
        set {
            guard let index = variants.firstIndex(where: { $0.id == newValue.id }) else { return }
            variants[index] = newValue
        }
    }

    /// Reads and writes route to the active variant, so every caller written
    /// against a single-answer rule keeps working unchanged.
    public var steps: [MockOutcome] {
        get { activeVariant.steps }
        set { activeVariant.steps = newValue.isEmpty ? [.respond(MockResponse())] : newValue }
    }

    public var exhaustion: MockExhaustion {
        get { activeVariant.exhaustion }
        set { activeVariant.exhaustion = newValue }
    }

    public var name: String? {
        get { activeVariant.name }
        set { activeVariant.name = newValue?.isEmpty == false ? newValue! : "default" }
    }

    public var requestSample: Data? {
        get { activeVariant.requestSample }
        set { activeVariant.requestSample = newValue }
    }

    public var isScripted: Bool { activeVariant.isScripted }

    /// The outcome for a 1-based hit, or `nil` when the script is spent and the
    /// rule has agreed to stand down.
    public func outcome(forHit hit: Int) -> MockOutcome? {
        activeVariant.outcome(forHit: hit)
    }

    /// Every variant, redacted. Used on the way to disk.
    func redacted(by redactor: Redactor) -> MockRule {
        var copy = self
        copy.variants = variants.map { $0.redacted(by: redactor) }
        return copy
    }

    // MARK: - Editing the library

    /// Switches which answer is served. Unknown ids are ignored rather than
    /// leaving the rule pointing at nothing.
    public mutating func activate(variantID: UUID) {
        guard variants.contains(where: { $0.id == variantID }) else { return }
        activeVariantID = variantID
    }

    public mutating func addVariant(_ variant: MockVariant, activate: Bool = true) {
        variants.append(variant)
        if activate { activeVariantID = variant.id }
    }

    public mutating func updateVariant(_ variant: MockVariant) {
        guard let index = variants.firstIndex(where: { $0.id == variant.id }) else { return }
        variants[index] = variant
    }

    /// Removes a variant, refusing to remove the last one — a rule with no
    /// answers would claim requests and serve nothing.
    public mutating func removeVariant(id: UUID) {
        guard variants.count > 1, let index = variants.firstIndex(where: { $0.id == id }) else {
            return
        }
        variants.remove(at: index)
        if activeVariantID == id { activeVariantID = variants[0].id }
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, endpointKey, isEnabled, variants, activeVariantID, match
        // Pre-variant shape, still on disk in anyone's saved rules.
        case steps, exhaustion, name, requestSample
    }

    /// Reads both shapes. A rule saved before variants existed decodes into a
    /// one-variant library rather than failing — a debugging tool that loses a
    /// tester's saved rules on upgrade does not get used again.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let endpointKey = try container.decode(String.self, forKey: .endpointKey)
        let isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        let match = try container.decodeIfPresent(MockMatch.self, forKey: .match) ?? .any

        if let variants = try container.decodeIfPresent([MockVariant].self, forKey: .variants) {
            self.init(
                id: id,
                endpointKey: endpointKey,
                variants: variants,
                activeVariantID: try container.decodeIfPresent(UUID.self, forKey: .activeVariantID),
                isEnabled: isEnabled,
                match: match
            )
        } else {
            self.init(
                id: id,
                endpointKey: endpointKey,
                steps: try container.decodeIfPresent([MockOutcome].self, forKey: .steps) ?? [],
                exhaustion: try container.decodeIfPresent(
                    MockExhaustion.self, forKey: .exhaustion
                ) ?? .repeatLast,
                isEnabled: isEnabled,
                name: try container.decodeIfPresent(String.self, forKey: .name),
                requestSample: try container.decodeIfPresent(Data.self, forKey: .requestSample),
                match: match
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(endpointKey, forKey: .endpointKey)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(variants, forKey: .variants)
        try container.encode(activeVariantID, forKey: .activeVariantID)
        try container.encode(match, forKey: .match)
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
