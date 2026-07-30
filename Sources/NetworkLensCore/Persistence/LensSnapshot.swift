import Foundation

/// Everything worth carrying across a relaunch.
///
/// Deliberately does **not** carry `isRequestEditingEnabled`. That flag is a
/// safety gate on sending altered data to a real backend, and a gate that
/// re-arms itself on launch is not a gate. It is opened by hand, every session.
public struct LensSnapshot: Codable, Sendable, Hashable {

    public var mocks: [MockRule]
    public var breakpoints: [Breakpoint]

    /// Saved reusable edits. Unlike the two above, these are artifacts the
    /// tester built on purpose and expects to find again — "the empty-cart
    /// perturbation" is a thing they name and reuse, not session state.
    public var perturbations: [Perturbation]

    /// The mocking master switch, so a session left "gone live" comes back
    /// that way instead of silently re-arming every rule at launch.
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

    public var isEmpty: Bool {
        mocks.isEmpty && breakpoints.isEmpty && perturbations.isEmpty
    }
}

/// Where a snapshot lives.
///
/// A protocol so tests get a store that never touches disk, and so a host app
/// can point the rules at a shared container or a bundled fixture.
public protocol LensSnapshotStore: Sendable {
    func load() throws -> LensSnapshot?
    func save(_ snapshot: LensSnapshot) throws
    func clear() throws
}

/// JSON on disk, under Application Support.
///
/// Application Support rather than Caches: these are documents the tester
/// authored, and the system evicts Caches under pressure. A mock set that
/// vanishes because the device got low on space is indistinguishable from a
/// bug in the tool.
public struct FileSnapshotStore: LensSnapshotStore {

    public let url: URL

    public init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL()
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("NetworkLens", isDirectory: true)
            .appendingPathComponent("session.json")
    }

    public func load() throws -> LensSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        // A snapshot written by an older build can fail to decode after a rule
        // shape changes. Losing the rules is annoying; refusing to launch is
        // worse, so a corrupt file reads as "no rules".
        return try? JSONDecoder().decode(LensSnapshot.self, from: data)
    }

    public func save(_ snapshot: LensSnapshot) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Atomic, because autosave fires on every rule edit and a half-written
        // file read at next launch would present as lost work.
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
