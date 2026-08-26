//
//  TraceWriterTests.swift
//  NetworkLensCoreTests
//
//  Created by Rohit Sahay on 27/08/26.
//

import XCTest
@testable import NetworkLensCore

final class TraceWriterTests: XCTestCase {

    private var directory = URL(fileURLWithPath: NSTemporaryDirectory())

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("networklens-trace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private var traceURL: URL { directory.appendingPathComponent("trace.ndjson") }

    private func writer(
        includesBodies: Bool = true,
        maxBytes: Int = 32 * 1_048_576,
        redactor: Redactor = NoRedactor()
    ) -> TraceWriter {
        let options = TraceOptions(url: traceURL, maxBytes: maxBytes, includesBodies: includesBodies)
        return TraceWriter(options: options, redactor: redactor)
    }

    private func finished(
        _ key: String = "GET /users/{id}",
        status: Int = 200,
        body: String = #"{"ok":true}"#
    ) -> NetworkExchange {
        let request = RequestSnapshot(
            method: "GET",
            url: URL(string: "https://api.test/users/7")!,
            headers: ["Authorization": "Bearer secret-token"]
        )
        let response = ResponseSnapshot(
            statusCode: status,
            headers: ["Content-Type": "application/json"],
            body: Data(body.utf8)
        )
        return NetworkExchange(endpointKey: key, request: request)
            .completed(response: response, timing: nil)
    }

    private func lines() throws -> [String] {
        guard FileManager.default.fileExists(atPath: traceURL.path) else { return [] }
        let text = try String(contentsOf: traceURL, encoding: .utf8)
        return text.split(separator: "\n").map(String.init)
    }

    private func records() throws -> [TraceRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try lines().map { try decoder.decode(TraceRecord.self, from: Data($0.utf8)) }
    }

    // MARK: - Writing

    func testWritesOneLinePerFinishedExchange() throws {
        let subject = writer()
        subject.record(finished("GET /a"))
        subject.record(finished("GET /b"))
        subject.flush()

        let written = try records()
        XCTAssertEqual(written.count, 2)
        XCTAssertEqual(written.map(\.exchange.endpointKey), ["GET /a", "GET /b"])
    }

    /// A request with no response yet is not a fact about the app, and it is
    /// written the moment it becomes one.
    func testSkipsInFlightExchanges() throws {
        let subject = writer()
        let pending = NetworkExchange(
            endpointKey: "GET /pending",
            request: RequestSnapshot(method: "GET", url: URL(string: "https://api.test/p")!)
        )
        XCTAssertTrue(pending.isInFlight)

        subject.record(pending)
        subject.flush()
        XCTAssertTrue(try lines().isEmpty)
    }

    /// One record must stay one line, or a reader splitting on newlines gets
    /// fragments of JSON.
    func testRecordIsNeverPrettyPrinted() throws {
        let subject = writer()
        subject.record(finished(body: #"{"nested":{"deep":[1,2,3]}}"#))
        subject.flush()

        XCTAssertEqual(try lines().count, 1)
    }

    func testCarriesSchemaAndStableSessionID() throws {
        let subject = writer()
        subject.record(finished("GET /a"))
        subject.record(finished("GET /b"))
        subject.flush()

        let written = try records()
        XCTAssertEqual(Set(written.map(\.schema)), [TraceRecord.currentSchema])
        XCTAssertEqual(Set(written.map(\.sessionID)).count, 1, "one launch is one session")
    }

    /// Two launches writing to the same file must stay tellable apart, else a
    /// reader cannot answer "what did the app do this run".
    func testSeparateWritersGetSeparateSessionIDs() throws {
        let first = writer()
        first.record(finished("GET /a"))
        first.flush()

        let second = writer()
        second.record(finished("GET /b"))
        second.flush()

        XCTAssertEqual(Set(try records().map(\.sessionID)).count, 2)
    }

    // MARK: - Redaction

    func testRedactsBeforeWritingToDisk() throws {
        let subject = writer(redactor: DefaultRedactor())
        subject.record(finished())
        subject.flush()

        let text = try String(contentsOf: traceURL, encoding: .utf8)
        XCTAssertFalse(text.contains("secret-token"), "an auth header must never reach the trace")
    }

    func testKeepsBodiesOutWhenAsked() throws {
        let subject = writer(includesBodies: false)
        subject.record(finished(body: #"{"marker":"payload"}"#))
        subject.flush()

        let text = try String(contentsOf: traceURL, encoding: .utf8)
        XCTAssertFalse(text.contains("payload"))

        let written = try XCTUnwrap(records().first)
        XCTAssertEqual(written.exchange.response?.statusCode, 200, "status survives, only the body goes")
    }

    // MARK: - Store subscription

    func testAttachRecordsFinishedTrafficFromTheStore() throws {
        let store = ExchangeStore()
        let subject = writer()
        subject.attach(to: store)

        let pending = NetworkExchange(
            endpointKey: "GET /users/{id}",
            request: RequestSnapshot(method: "GET", url: URL(string: "https://api.test/users/7")!)
        )
        store.upsert(pending)
        store.upsert(pending.completed(
            response: ResponseSnapshot(statusCode: 204, headers: [:], body: nil), timing: nil
        ))
        subject.flush()

        let written = try records()
        XCTAssertEqual(written.count, 1, "the in-flight write is skipped, the completion is kept")
        XCTAssertEqual(written.first?.exchange.response?.statusCode, 204)
    }

    /// Attaching twice must replace the subscription, not double every line.
    func testAttachingTwiceDoesNotDoubleWrite() throws {
        let store = ExchangeStore()
        let subject = writer()
        subject.attach(to: store)
        subject.attach(to: store)

        store.record(finished())
        subject.flush()

        XCTAssertEqual(try lines().count, 1)
    }

    func testDetachStopsWriting() throws {
        let store = ExchangeStore()
        let subject = writer()
        subject.attach(to: store)
        subject.detach()

        store.record(finished())
        subject.flush()

        XCTAssertTrue(try lines().isEmpty)
    }

    /// The last line for an id is its current state; the earlier ones are the
    /// audit trail a reader collapsing by id discards.
    func testLaterEditAppendsRatherThanRewrites() throws {
        let store = ExchangeStore()
        let subject = writer()
        subject.attach(to: store)

        let original = finished(status: 200)
        store.record(original)
        store.update(id: original.id) {
            $0.completed(response: ResponseSnapshot(statusCode: 500, headers: [:], body: nil), timing: nil)
        }
        subject.flush()

        let written = try records()
        XCTAssertEqual(written.count, 2)
        XCTAssertEqual(written.last?.exchange.response?.statusCode, 500)
        XCTAssertEqual(Set(written.map(\.exchange.id)).count, 1)
    }

    // MARK: - Rotation

    func testRotatesAtThresholdKeepingOneGeneration() throws {
        let subject = writer(maxBytes: 512)
        for index in 0..<40 {
            subject.record(finished("GET /\(index)", body: String(repeating: "x", count: 200)))
        }
        subject.flush()

        let rotated = directory.appendingPathComponent("trace.1.ndjson")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotated.path), "previous generation is kept")
        XCTAssertLessThanOrEqual(try lines().count, 40)
    }

    /// A trace that cannot be written must not take the app down with it.
    func testUnwritableDestinationIsSurvivable() {
        let options = TraceOptions(url: URL(fileURLWithPath: "/proc/no/such/place/trace.ndjson"))
        let subject = TraceWriter(options: options, redactor: NoRedactor())
        subject.record(finished())
        subject.flush()
    }
}

extension TraceWriterTests {

    /// start() replaces the configuration, so a second call without a trace
    /// option must stop the first one's writer rather than leaving it writing
    /// under a configuration that says tracing is off.
    func testRestartingWithoutTraceStopsWriting() throws {
        NetworkLens.start(configuration: LensConfiguration(trace: TraceOptions(url: traceURL)))
        XCTAssertNotNil(NetworkLens.traceURL)

        NetworkLens.start(configuration: LensConfiguration())
        XCTAssertNil(NetworkLens.traceURL, "the writer is gone, not merely unreachable")
    }
}
