//
//  TraceWriter.swift
//  NetworkLensCore
//
//  Created by Rohit Sahay on 27/08/26.
//

import Foundation

/// Where the trace is written and how large it may grow.
///
/// A separate type rather than three more flags on `LensConfiguration`: the
/// three are meaningless apart, and `trace == nil` reads as "off" where a bare
/// `writesTrace: false` would leave the other two dangling.
public struct TraceOptions: Sendable {

    public var url: URL?

    /// Rotation threshold. One generation is kept, so the ceiling on disk is
    /// roughly twice this.
    public var maxBytes: Int

    /// Bodies are the reason to read a trace at all, but they are also all of
    /// its size. Off keeps headers, timing and status — enough to see the shape
    /// of a session without carrying the payloads.
    public var includesBodies: Bool

    public init(url: URL? = nil, maxBytes: Int = 32 * 1_048_576, includesBodies: Bool = true) {
        self.url = url
        self.maxBytes = maxBytes
        self.includesBodies = includesBodies
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("NetworkLens", isDirectory: true)
            .appendingPathComponent("trace.ndjson")
    }
}

/// One line of the trace file.
///
/// `sessionID` is what separates one launch from the next in an append-only
/// file — without it a reader cannot tell a relaunch from more traffic, and
/// every "what did the app do this run" question needs that split.
public struct TraceRecord: Codable, Sendable {
    public static let currentSchema = 1

    public let schema: Int
    public let sessionID: UUID
    public let recordedAt: Date
    public let exchange: NetworkExchange

    public init(sessionID: UUID, recordedAt: Date, exchange: NetworkExchange) {
        self.schema = Self.currentSchema
        self.sessionID = sessionID
        self.recordedAt = recordedAt
        self.exchange = exchange
    }
}

/// Appends finished exchanges to a newline-delimited JSON file.
///
/// NDJSON rather than a JSON array because the file is written for its whole
/// life and read while the app is still running: appending a line costs one
/// write with no re-encode, a reader can tail it, and a process killed
/// mid-write loses the last line instead of the document.
///
/// An exchange is written when it finishes, and again on every later edit, so
/// the last line for an id is its current state. A reader collapsing by id
/// takes the last occurrence; the earlier ones are the audit trail.
public final class TraceWriter: @unchecked Sendable {

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.networklens.trace")
    private let url: URL
    private let maxBytes: Int
    private let includesBodies: Bool
    private let redactor: Redactor
    private let sessionID: UUID
    private let clock: LensClock

    private var token: ExchangeStore.ObservationToken?
    private var bytesWritten = 0

    public init(
        options: TraceOptions,
        redactor: Redactor,
        sessionID: UUID = UUID(),
        clock: LensClock = SystemClock()
    ) {
        self.url = options.url ?? TraceOptions.defaultURL()
        self.maxBytes = max(1, options.maxBytes)
        self.includesBodies = options.includesBodies
        self.redactor = redactor
        self.sessionID = sessionID
        self.clock = clock
        self.bytesWritten = Self.fileSize(at: self.url)
    }

    public var fileURL: URL { url }

    /// Subscribes to the store. Safe to call twice — the second call replaces
    /// the first subscription rather than doubling every line.
    public func attach(to store: ExchangeStore) {
        let observation = store.addExchangeObserver { [weak self] exchange in
            self?.record(exchange)
        }
        lock.lock()
        token = observation
        lock.unlock()
    }

    public func detach() {
        lock.lock()
        token = nil
        lock.unlock()
    }

    /// Drops in-flight exchanges: a request with no response is not yet a fact
    /// about the app, and it is written again the moment it becomes one.
    public func record(_ exchange: NetworkExchange) {
        guard !exchange.isInFlight else { return }
        let prepared = prepare(exchange)
        let record = TraceRecord(sessionID: sessionID, recordedAt: clock.now, exchange: prepared)
        queue.async { [weak self] in
            self?.append(record)
        }
    }

    /// Blocks until everything queued has landed. For a test, or a caller about
    /// to read the file it just wrote.
    public func flush() {
        queue.sync { }
    }

    // MARK: - Writing

    private func prepare(_ exchange: NetworkExchange) -> NetworkExchange {
        var request = redactor.redact(exchange.request)
        var response = exchange.response.map { redactor.redact($0) }

        if !includesBodies {
            request.body = nil
            response?.body = nil
        }

        return NetworkExchange(
            id: exchange.id,
            endpointKey: exchange.endpointKey,
            screen: exchange.screen,
            request: request,
            response: response,
            failure: exchange.failure,
            timing: exchange.timing,
            startedAt: exchange.startedAt,
            source: exchange.source,
            edits: exchange.edits,
            isMockServed: exchange.isMockServed,
            replayOf: exchange.replayOf
        )
    }

    private func append(_ record: TraceRecord) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Sorted so a diff of two traces shows changed values, not reordered
        // keys. Never pretty-printed — one record must stay one line.
        encoder.outputFormatting = [.sortedKeys]

        guard var data = try? encoder.encode(record) else { return }
        data.append(0x0A)

        rotateIfNeeded(adding: data.count)

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url, options: .atomic)
            }
            bytesWritten += data.count
        } catch {
            // A trace that cannot be written must not take the app down with
            // it. The traffic list in the overlay is unaffected either way.
        }
    }

    /// Keeps one previous generation. Two files bound the disk cost and still
    /// leave the run before this one readable, which is usually the one with
    /// the bug in it.
    private func rotateIfNeeded(adding count: Int) {
        guard bytesWritten + count > maxBytes, bytesWritten > 0 else { return }
        let rotated = url.deletingPathExtension().appendingPathExtension("1.ndjson")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: url, to: rotated)
        bytesWritten = 0
    }

    private static func fileSize(at url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? Int) ?? 0
    }
}
