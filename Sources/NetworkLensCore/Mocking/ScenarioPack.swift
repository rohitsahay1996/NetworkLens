//
//  ScenarioPack.swift
//  NetworkLensCore
//
//  Created by Rohit Sahay on 28/08/26.
//

import Foundation

/// Scenarios plus the rules they need, as one file that can leave the device.
///
/// A scenario on its own is a set of pointers — endpoint key, match, variant.
/// Handing someone that file gives them a scenario that resolves to nothing,
/// which is the worst possible failure here: it applies, reports success, and
/// the app quietly serves live traffic. So a pack carries the referenced
/// `MockRule`s with it, and `unresolved` names anything it could not.
///
/// This is what makes the work shareable. Until now a scenario lived in one
/// simulator's Application Support: QA could not get the one a developer built,
/// CI could not be given a known state, and nothing was reviewable in a pull
/// request. A pack is a plain JSON file — commit it, attach it to a ticket, or
/// AirDrop it to a device running a TestFlight build.
///
/// Redacted on export by default. A rule captured from a real response carries
/// whatever that response carried, and the whole point of this type is that the
/// file goes somewhere else — a repository, a ticket, a chat thread. Opting out
/// is possible and deliberate, for the case where a token's fidelity is what is
/// being tested.
public struct ScenarioPack: Codable, Sendable, Hashable {

    /// Bumped when the shape changes in a way an older build cannot read.
    /// Carried in the file so a mismatch can be reported rather than crashing
    /// out of a `JSONDecoder` with nothing a tester can act on.
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var name: String
    public var notes: String?
    public var createdAt: Date

    public var scenarios: [Scenario]

    /// Only the rules the scenarios reference. A pack is meant to be read in a
    /// diff, so shipping the device's whole rule set would bury the three
    /// endpoints that matter.
    public var mocks: [MockRule]

    public init(
        formatVersion: Int = ScenarioPack.currentFormatVersion,
        name: String,
        notes: String? = nil,
        createdAt: Date = Date(),
        scenarios: [Scenario],
        mocks: [MockRule]
    ) {
        self.formatVersion = formatVersion
        self.name = name
        self.notes = notes
        self.createdAt = createdAt
        self.scenarios = scenarios
        self.mocks = mocks
    }

    // MARK: - Export

    /// Collects `scenarios` and exactly the rules they point at.
    ///
    /// - Parameter redactor: applied to every rule on the way out. Pass `nil`
    ///   only when the pack is staying on the machine that made it.
    public static func exporting(
        _ scenarios: [Scenario],
        from rules: [MockRule],
        named name: String,
        notes: String? = nil,
        redactedBy redactor: Redactor? = DefaultRedactor()
    ) -> ScenarioPack {
        var referenced: [MockRule] = []
        for rule in rules where scenarios.contains(where: { $0.references(rule) }) {
            referenced.append(redactor.map { rule.redacted(by: $0) } ?? rule)
        }
        // Dates are truncated to the precision the file format carries, so a
        // pack decodes back to exactly what was exported. Without this a
        // round-tripped scenario compares unequal to the one it came from over
        // sub-millisecond digits no reviewer will ever see.
        let dated = scenarios.map { scenario -> Scenario in
            var copy = scenario
            copy.createdAt = Self.storable(scenario.createdAt)
            return copy
        }
        return ScenarioPack(
            name: name,
            notes: notes,
            createdAt: Self.storable(Date()),
            scenarios: dated,
            mocks: referenced
        )
    }

    /// A date at the precision `dateFormatter` writes: milliseconds.
    static func storable(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
    }

    // MARK: - Validation

    /// Entries that name a rule the pack does not carry.
    ///
    /// Checked before the file is written rather than after it is opened on
    /// someone else's device, where the only symptom is a scenario that applies
    /// and does nothing.
    public var unresolved: [Scenario.Entry] {
        scenarios.flatMap { scenario in
            scenario.entries.filter { entry in
                !mocks.contains { rule in
                    rule.endpointKey == entry.endpointKey && rule.match == entry.match
                }
            }
        }
    }

    public var isComplete: Bool { unresolved.isEmpty }

    // MARK: - Import

    /// What an import changed. Reported rather than assumed: a pack that half
    /// applied is the failure this type exists to make visible.
    public struct ImportOutcome: Sendable, Equatable {

        public var addedRules: Int
        public var replacedRules: Int
        public var addedScenarios: Int
        public var replacedScenarios: Int

        /// Entries still pointing at nothing after the import — only possible
        /// from a hand-edited or truncated pack.
        public var unresolved: [Scenario.Entry]

        public var isComplete: Bool { unresolved.isEmpty }

        public init(
            addedRules: Int = 0,
            replacedRules: Int = 0,
            addedScenarios: Int = 0,
            replacedScenarios: Int = 0,
            unresolved: [Scenario.Entry] = []
        ) {
            self.addedRules = addedRules
            self.replacedRules = replacedRules
            self.addedScenarios = addedScenarios
            self.replacedScenarios = replacedScenarios
            self.unresolved = unresolved
        }
    }

    /// Merges the pack into the live registries. The pack wins on conflict.
    ///
    /// Rules replace by endpoint key and match — the pair `Mocks` already
    /// treats as identity — not by id, because the same endpoint mocked on two
    /// devices has two different ids and matching on them would silently
    /// duplicate every rule. The pack's own ids come along, so its scenario
    /// entries resolve by id rather than falling back to variant names.
    ///
    /// Pack-wins is the right default for the job: someone is being handed a
    /// known state to reproduce, and a merge that kept half their local edits
    /// would reproduce something else. The outcome says how much was
    /// overwritten so it is never silent.
    @discardableResult
    public func `import`(
        into mocks: Mocks = .shared,
        scenarios scenarioStore: Scenarios = .shared
    ) -> ImportOutcome {
        var outcome = ImportOutcome()

        let existingRules = mocks.all
        for rule in self.mocks {
            let isReplacement = existingRules.contains {
                $0.endpointKey == rule.endpointKey && $0.match == rule.match
            }
            mocks.set(rule)
            if isReplacement {
                outcome.replacedRules += 1
            } else {
                outcome.addedRules += 1
            }
        }

        let existingScenarios = scenarioStore.all
        for var scenario in scenarios {
            let isReplacement = existingScenarios.contains {
                $0.id == scenario.id || $0.name == scenario.name
            }
            // Stamped on the way in, not written into the file, so a pack
            // renamed on disk regroups its scenarios on the next import rather
            // than leaving two groups that are really one.
            scenario.group = name
            scenarioStore.save(scenario)
            if isReplacement {
                outcome.replacedScenarios += 1
            } else {
                outcome.addedScenarios += 1
            }
        }

        let landed = mocks.all
        outcome.unresolved = scenarios.flatMap { scenario in
            scenario.entries.filter { entry in
                !landed.contains { rule in
                    rule.endpointKey == entry.endpointKey && rule.match == entry.match
                }
            }
        }
        return outcome
    }

    // MARK: - File

    /// Fractional seconds, because `Date` carries them and the stock `.iso8601`
    /// strategy silently drops them — a pack would not round-trip its own
    /// `createdAt`, and two scenarios that differ only by the truncated part
    /// would compare equal after a save.
    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Stable and diff-friendly: sorted keys so a re-export of an unchanged
    /// pack is an empty diff, and ISO-8601 dates so a reviewer can read them.
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(dateFormatter.string(from: date))
        }
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = dateFormatter.date(from: text) else {
                throw PackError.malformedDate(text)
            }
            return date
        }
        return decoder
    }

    public func encoded() throws -> Data {
        try Self.encoder().encode(self)
    }

    /// Reads a pack, refusing one written by a newer format rather than
    /// decoding half of it.
    public static func decoding(_ data: Data) throws -> ScenarioPack {
        let pack = try decoder().decode(ScenarioPack.self, from: data)
        guard pack.formatVersion <= currentFormatVersion else {
            throw PackError.unsupportedFormat(found: pack.formatVersion, supported: currentFormatVersion)
        }
        return pack
    }

    public enum PackError: Error, Equatable, CustomStringConvertible {

        case unsupportedFormat(found: Int, supported: Int)
        case malformedDate(String)

        public var description: String {
            switch self {
                case let .unsupportedFormat(found, supported):
                    return "Pack format \(found) is newer than this build understands (\(supported)). Update the app."
                case let .malformedDate(text):
                    return "Pack carries a date this build cannot read: \(text)"
            }
        }
    }

    /// `Checkout, promos down.networklens-pack.json` — named after the pack so
    /// a folder of them is readable, with the double extension so the file type
    /// is still obvious.
    public var suggestedFileName: String {
        let safe = name
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_")).inverted)
            .joined()
            .trimmingCharacters(in: .whitespaces)
        let base = safe.isEmpty ? "scenarios" : safe
        return "\(base).networklens-pack.json"
    }
}

extension Scenario {

    /// Whether any entry points at this rule, by the same key-and-match pair
    /// `Mocks` treats as identity.
    func references(_ rule: MockRule) -> Bool {
        entries.contains { $0.endpointKey == rule.endpointKey && $0.match == rule.match }
    }
}
