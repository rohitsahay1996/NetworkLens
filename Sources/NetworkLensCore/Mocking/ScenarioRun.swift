//
//  ScenarioRun.swift
//  NetworkLensCore
//
//  Created by Rohit Sahay on 28/08/26.
//

import Foundation

/// One pass through a pack, and what the tester saw at each state.
///
/// A scenario proves the app *was* put into a state. It proves nothing about
/// what the screen then did, which is the only thing a reviewer cares about —
/// so a run pairs each scenario with a screenshot, a verdict and a sentence.
///
/// The artifact matters as much as the mechanism. "Flash sale 14.6.0, nine edge
/// states, two failures" attached to a ticket is something a PM reads; a tester
/// saying "I checked the empty states" is not.
public struct ScenarioRun: Codable, Sendable, Hashable, Identifiable {

    public let id: UUID
    public var packName: String
    public var startedAt: Date
    public var captures: [Capture]

    /// What one scenario looked like when it was applied.
    public struct Capture: Codable, Sendable, Hashable, Identifiable {

        public enum Verdict: String, Codable, Sendable {
            case unset
            case pass
            case fail
        }

        public let id: UUID
        public var scenarioName: String

        /// Endpoint → variant, as the scenario pinned it. Recorded rather than
        /// looked up later: the rules will have moved on by the time anyone
        /// reads the report, and a page that cannot say what was mocked is a
        /// screenshot with a caption.
        public var pinned: [String]

        public var verdict: Verdict
        public var note: String

        /// File name within the run's directory, or nil when the tester moved
        /// on without capturing. A skipped state is worth recording — it is the
        /// one nobody looked at.
        public var imageFileName: String?

        public var capturedAt: Date

        public init(
            id: UUID = UUID(),
            scenarioName: String,
            pinned: [String],
            verdict: Verdict = .unset,
            note: String = "",
            imageFileName: String? = nil,
            capturedAt: Date = Date()
        ) {
            self.id = id
            self.scenarioName = scenarioName
            self.pinned = pinned
            self.verdict = verdict
            self.note = note
            self.imageFileName = imageFileName
            self.capturedAt = capturedAt
        }
    }

    public init(
        id: UUID = UUID(),
        packName: String,
        startedAt: Date = Date(),
        captures: [Capture] = []
    ) {
        self.id = id
        self.packName = packName
        self.startedAt = startedAt
        self.captures = captures
    }

    public var passed: Int { captures.filter { $0.verdict == .pass }.count }
    public var failed: Int { captures.filter { $0.verdict == .fail }.count }
    public var unreviewed: Int { captures.filter { $0.verdict == .unset }.count }

    /// The line that goes at the top of the report and in the Slack message.
    public var summary: String {
        var parts = ["\(captures.count) states"]
        if passed > 0 { parts.append("\(passed) passed") }
        if failed > 0 { parts.append("\(failed) failed") }
        if unreviewed > 0 { parts.append("\(unreviewed) unreviewed") }
        return parts.joined(separator: " · ")
    }
}

/// Where a run's screenshots and manifest live.
///
/// One directory per run under Application Support, so a run can be deleted
/// whole and a half-finished one never contaminates the next. Images are PNG on
/// disk rather than held in memory: a nine-state pass on a Pro Max is a few tens
/// of megabytes, and a debugging tool that pushes the host app into a memory
/// warning has made things worse.
public final class RunStore: @unchecked Sendable {

    public static let shared = RunStore()

    private let lock = NSLock()
    private let root: URL

    public init(root: URL? = nil) {
        self.root = root ?? Self.defaultRoot()
    }

    public static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("NetworkLens", isDirectory: true)
            .appendingPathComponent("Runs", isDirectory: true)
    }

    public func directory(for run: ScenarioRun) -> URL {
        root.appendingPathComponent(run.id.uuidString, isDirectory: true)
    }

    public func imageURL(for run: ScenarioRun, fileName: String) -> URL {
        directory(for: run).appendingPathComponent(fileName)
    }

    @discardableResult
    public func writeImage(_ data: Data, for run: ScenarioRun, index: Int) throws -> String {
        let fileName = String(format: "%02d.png", index)
        let directory = directory(for: run)
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
        return fileName
    }

    public func save(_ run: ScenarioRun) throws {
        let directory = directory(for: run)
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(run).write(to: directory.appendingPathComponent("run.json"), options: .atomic)
    }

    public func runs() -> [ScenarioRun] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let directories = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return directories
            .compactMap { try? Data(contentsOf: $0.appendingPathComponent("run.json")) }
            .compactMap { try? decoder.decode(ScenarioRun.self, from: $0) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func delete(_ run: ScenarioRun) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: directory(for: run))
    }
}
