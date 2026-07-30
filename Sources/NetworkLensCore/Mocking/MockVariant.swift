//
//  MockVariant.swift
//  NetworkLensCore
//
//  Created by Rohit Sahay on 30/07/26.
//

import Foundation

/// One named answer an endpoint can give: "empty", "500", "ten items",
/// "expired token".
///
/// The unit a tester actually thinks in. Verifying a screen means walking the
/// same endpoint through several shapes — loaded, empty, failed, paginated —
/// and the slow part has never been describing any one of them. It is switching
/// between them: in a proxy that means editing a rewrite rule or swapping a map
/// file for every case, so most people build one and stop.
///
/// A variant is deliberately the whole script rather than a single response, so
/// "fails twice then succeeds" is as switchable as "returns empty".
public struct MockVariant: Codable, Sendable, Hashable, Identifiable {

    public let id: UUID

    /// Short and human: it is what the switcher shows.
    public var name: String

    /// Played one per hit, in order. Never empty.
    public var steps: [MockOutcome]

    /// What happens after the last step. See `MockExhaustion`.
    public var exhaustion: MockExhaustion

    /// The request body this variant was written against, kept for reference.
    /// Never sent — see `MockRule.requestSample`.
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
        // An empty script resolves to nothing on every hit, which reads as a
        // broken mock. A variant that exists always answers something.
        self.steps = steps.isEmpty ? [.respond(MockResponse())] : steps
        self.exhaustion = exhaustion
        self.requestSample = requestSample
    }

    public var isScripted: Bool { steps.count > 1 }

    /// The same variant with its captured bodies and headers run through the
    /// redactor.
    ///
    /// Rules are built from real responses, so a rule is exactly as sensitive
    /// as the traffic it was captured from. The traffic list has always been
    /// redacted; rules were not, and they are the half that gets written to
    /// disk and survives the session.
    func redacted(by redactor: Redactor) -> MockVariant {
        var copy = self
        copy.steps = steps.map { step in
            guard let response = step.response else { return step }
            let cleaned = redactor.redact(
                ResponseSnapshot(
                    statusCode: response.statusCode,
                    headers: response.headers,
                    body: response.body
                )
            )
            var redactedResponse = response
            redactedResponse.headers = cleaned.headers
            redactedResponse.body = cleaned.body ?? Data()
            return .respond(redactedResponse)
        }
        // Captured from a real request, so it carries auth headers' worth of
        // risk in its body just as often as a response does.
        if let sample = requestSample {
            copy.requestSample = redactor.redact(
                ResponseSnapshot(statusCode: 200, headers: [:], body: sample)
            ).body
        }
        return copy
    }

    /// The outcome for a 1-based hit, or `nil` when the script is spent and the
    /// variant has agreed to stand down.
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
