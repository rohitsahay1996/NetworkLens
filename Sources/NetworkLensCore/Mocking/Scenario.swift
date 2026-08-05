//
//  Scenario.swift
//  NetworkLensCore
//
//  Created by Rohit Sahay on 30/07/26.
//

import Foundation

/// A named setup across several endpoints, applied in one go.
///
/// Variants made one endpoint's states switchable. The unit a screen is
/// actually debugged in is larger than that: four calls, each with four
/// interesting states, and the bugs live in the combinations — cart empty
/// *while* promos 500 *while* profile loads slowly. Reaching one of those by
/// hand is four taps in four places, and getting back to it tomorrow means
/// remembering which four.
///
/// A scenario is that combination, named: "checkout, promos down".
public struct Scenario: Codable, Sendable, Hashable, Identifiable {

    public let id: UUID
    public var name: String
    public var entries: [Entry]
    public var createdAt: Date

    /// One endpoint's part in the setup.
    public struct Entry: Codable, Sendable, Hashable {

        /// Identifies the rule the same way `Mocks` does — key plus conditions,
        /// so a `page=2` rule and its catch-all are separate entries.
        public var endpointKey: String
        public var match: MockMatch

        /// Which answer to select.
        public var variantID: UUID

        /// The variant's name when the scenario was captured.
        ///
        /// Kept as a fallback because ids do not survive a rule being rebuilt —
        /// re-imported, re-captured, edited on another device — and a scenario
        /// that silently selects nothing is worse than one that matches by the
        /// name a person actually recognises.
        public var variantName: String

        /// Whether the rule was serving. A scenario that could not turn a rule
        /// *off* could not express "everything mocked except search".
        public var isEnabled: Bool

        public init(
            endpointKey: String,
            match: MockMatch = .any,
            variantID: UUID,
            variantName: String,
            isEnabled: Bool = true
        ) {
            self.endpointKey = endpointKey
            self.match = match
            self.variantID = variantID
            self.variantName = variantName
            self.isEnabled = isEnabled
        }
    }

    public init(
        id: UUID = UUID(),
        name: String,
        entries: [Entry],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.entries = entries
        self.createdAt = createdAt
    }

    /// Short summary for a list: `3 endpoints · empty cart, 500, loaded`.
    public var summary: String {
        let names = entries.map(\.variantName).joined(separator: ", ")
        let count = "\(entries.count) endpoint\(entries.count == 1 ? "" : "s")"
        return names.isEmpty ? count : "\(count) · \(names)"
    }

    // MARK: - Capture

    /// Snapshots the current selection across `rules`.
    ///
    /// Captured rather than authored: the setup already exists on screen by the
    /// time anyone wants to keep it, and retyping it into a form is how a
    /// feature like this goes unused.
    public static func capturing(
        _ name: String,
        from rules: [MockRule],
        limitedTo endpointKeys: Set<String>? = nil
    ) -> Scenario {
        let included = rules.filter { endpointKeys?.contains($0.endpointKey) ?? true }
        return Scenario(
            name: name,
            entries: included.map { rule in
                Entry(
                    endpointKey: rule.endpointKey,
                    match: rule.match,
                    variantID: rule.activeVariantID,
                    variantName: rule.activeVariant.name,
                    isEnabled: rule.isEnabled
                )
            }
        )
    }

    /// Whether `rules` are currently set exactly as this scenario describes.
    ///
    /// Lets "applied" verify itself rather than be remembered. A flag would go
    /// stale the moment someone switched one endpoint by hand, and a label
    /// claiming "checkout, promos down" while promos are live misdescribes what
    /// the app is being told — the one thing this tool must never do.
    public func matches(_ rules: [MockRule]) -> Bool {
        entries.allSatisfy { entry in
            guard
                let rule = rules.first(
                    where: { $0.endpointKey == entry.endpointKey && $0.match == entry.match }
                )
            else { return false }

            let active = rule.activeVariant
            let sameVariant = active.id == entry.variantID || active.name == entry.variantName
            return sameVariant && rule.isEnabled == entry.isEnabled
        }
    }

    // MARK: - Apply

    /// What applying this scenario would change, without changing it.
    ///
    /// Used to report honestly afterwards: an entry whose endpoint is no longer
    /// mocked is skipped, and a scenario that quietly applies half of itself is
    /// indistinguishable from a broken one.
    public func resolve(against rules: [MockRule]) -> (applied: [MockRule], missing: [Entry]) {
        var applied: [MockRule] = []
        var missing: [Entry] = []

        for entry in entries {
            guard
                var rule = rules.first(
                    where: { $0.endpointKey == entry.endpointKey && $0.match == entry.match }
                )
            else {
                missing.append(entry)
                continue
            }

            // By id first, by name second: a rebuilt rule keeps its names but
            // not its ids.
            let target = rule.variants.first { $0.id == entry.variantID }
                ?? rule.variants.first { $0.name == entry.variantName }

            guard let target else {
                missing.append(entry)
                continue
            }

            rule.activate(variantID: target.id)
            rule.isEnabled = entry.isEnabled
            applied.append(rule)
        }

        return (applied, missing)
    }
}
