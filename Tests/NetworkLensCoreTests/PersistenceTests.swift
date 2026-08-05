//
//  PersistenceTests.swift
//  NetworkLensCoreTests
//
//  Created by Rohit Sahay on 30/07/26.
//

import XCTest
@testable import NetworkLensCore

/// Rules are built from real responses, so they are as sensitive as the traffic
/// they came from — and they are the half that reaches disk.
final class PersistedRuleRedactionTests: XCTestCase {

    override func tearDown() {
        Mocks.shared.removeAll()
        NetworkLens.start(configuration: LensConfiguration())
        super.tearDown()
    }

    private func secretRule() -> MockRule {
        MockRule(
            endpointKey: "POST /login",
            response: .json(#"{"access_token":"super-secret-value","id":7}"#),
            name: "logged in"
        )
    }

    func testPersistedRulesAreRedactedByDefault() throws {
        NetworkLens.start(configuration: LensConfiguration(redactor: DefaultRedactor()))
        Mocks.shared.removeAll()
        Mocks.shared.set(secretRule())

        let saved = LensPersistence.shared.snapshot()
        let body = try XCTUnwrap(saved.mocks.first?.steps.first?.response?.body)
        let text = String(decoding: body, as: UTF8.self)

        XCTAssertFalse(text.contains("super-secret-value"), "a token must not reach disk")
        XCTAssertTrue(text.contains("\"id\""), "the rest of the payload has to survive")
    }

    /// The live rule keeps serving what was captured; only the copy that
    /// persists is scrubbed.
    func testRedactionDoesNotTouchTheRuleBeingServed() throws {
        NetworkLens.start(configuration: LensConfiguration(redactor: DefaultRedactor()))
        Mocks.shared.removeAll()
        Mocks.shared.set(secretRule())

        _ = LensPersistence.shared.snapshot()

        let live = try XCTUnwrap(Mocks.shared.rule(forEndpointKey: "POST /login"))
        let body = try XCTUnwrap(live.steps.first?.response?.body)
        XCTAssertTrue(
            String(decoding: body, as: UTF8.self).contains("super-secret-value"),
            "the session must keep serving the real captured bytes"
        )
    }

    func testRedactionOfPersistedRulesCanBeTurnedOff() throws {
        NetworkLens.start(
            configuration: LensConfiguration(
                redactor: DefaultRedactor(), redactsPersistedRules: false
            )
        )
        Mocks.shared.removeAll()
        Mocks.shared.set(secretRule())

        let saved = LensPersistence.shared.snapshot()
        let body = try XCTUnwrap(saved.mocks.first?.steps.first?.response?.body)
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("super-secret-value"))
    }
}

final class PersistenceTests: XCTestCase {

    private var persistence: LensPersistence!
    private var store: MemorySnapshotStore!

    override func setUp() {
        super.setUp()
        store = MemorySnapshotStore()
        persistence = LensPersistence(store: store)
        Mocks.shared.removeAll()
        Mocks.shared.setMockingEnabled(true)
        Breakpoints.shared.clearForRelaunch()
    }

    override func tearDown() {
        persistence.endAutosave()
        Mocks.shared.removeAll()
        // These tests exercise the master switch, which is global. Leaving it
        // off made unrelated suites fail depending on run order.
        Mocks.shared.setMockingEnabled(true)
        Breakpoints.shared.clearForRelaunch()
        persistence = nil
        store = nil
        super.tearDown()
    }

    private func makePerturbation() -> Perturbation {
        Perturbation(name: "empty cart", endpointKey: "GET /cart", ops: [])
    }

    // MARK: - Round trip

    func testSnapshotCapturesRulesAndTheMasterSwitch() {
        Mocks.shared.set(MockRule(endpointKey: "GET /users/{id}", response: .status(418)))
        Breakpoints.shared.set(Breakpoint(endpointKey: "GET /orders"))
        Breakpoints.shared.save(makePerturbation())
        Mocks.shared.setMockingEnabled(false)

        let snapshot = persistence.snapshot()

        XCTAssertEqual(snapshot.mocks.count, 1)
        XCTAssertEqual(snapshot.breakpoints.count, 1)
        XCTAssertEqual(snapshot.perturbations.count, 1)
        XCTAssertFalse(snapshot.isMockingEnabled)
    }

    func testPersistThenRestoreBringsArmedRulesBackWhenKeepingIsOn() {
        Mocks.shared.set(
            MockRule(endpointKey: "GET /users/{id}", steps: [.fail(.offline()), .respond(.status(200))])
        )
        Breakpoints.shared.set(Breakpoint(endpointKey: "GET /orders", stage: .both))
        persistence.persist()

        Mocks.shared.removeAll()
        Breakpoints.shared.clearForRelaunch()

        persistence.restore(keepingActiveRules: true)

        XCTAssertEqual(Mocks.shared.all.count, 1)
        XCTAssertEqual(Mocks.shared.all.first?.steps.count, 2)
        XCTAssertEqual(Breakpoints.shared.all.first?.stage, .both)
    }

    /// The default pair: rules are written, but only perturbations are allowed
    /// back. A mock that outlives its session reads as a backend bug.
    func testRestoreDropsArmedRulesButKeepsPerturbationsByDefault() {
        Mocks.shared.set(MockRule(endpointKey: "GET /users/{id}", response: .status(200)))
        Breakpoints.shared.set(Breakpoint(endpointKey: "GET /orders"))
        Breakpoints.shared.save(makePerturbation())
        persistence.persist()

        Mocks.shared.removeAll()
        Breakpoints.shared.clearForRelaunch()

        persistence.restore(keepingActiveRules: false)

        XCTAssertTrue(Mocks.shared.all.isEmpty)
        XCTAssertTrue(Breakpoints.shared.all.isEmpty)
        XCTAssertEqual(Breakpoints.shared.perturbations.map(\.name), ["empty cart"])
    }

    /// Request editing sends altered data to a real backend. A gate that
    /// re-arms itself at launch is not a gate.
    func testRequestEditingIsNeverRestored() {
        Breakpoints.shared.setRequestEditingEnabled(true)
        persistence.persist()
        Breakpoints.shared.setRequestEditingEnabled(false)

        persistence.restore(keepingActiveRules: true)

        XCTAssertFalse(Breakpoints.shared.isRequestEditingEnabled)
    }

    func testRestoreRewindsScriptsToTheFirstStep() {
        let rule = MockRule(
            endpointKey: "GET /users/{id}",
            steps: [.respond(.status(500)), .respond(.status(200))]
        )
        Mocks.shared.set(rule)
        var request = URLRequest(url: URL(string: "https://api.test/users/1")!)
        request.httpMethod = "GET"
        _ = Mocks.shared.resolve(request)
        persistence.persist()

        persistence.restore(keepingActiveRules: true)

        XCTAssertEqual(Mocks.shared.hitCount(forRuleID: rule.id), 0)
        XCTAssertEqual(Mocks.shared.resolve(request)?.response?.statusCode, 500)
    }

    func testRestoreOnAnEmptyStoreLeavesTheRegistriesAlone() {
        Breakpoints.shared.save(makePerturbation())

        persistence.restore(keepingActiveRules: true)

        XCTAssertEqual(Breakpoints.shared.perturbations.count, 1)
    }

    // MARK: - Autosave

    func testAutosaveWritesOnEveryRuleMutation() {
        persistence.beginAutosave()

        Mocks.shared.set(MockRule(endpointKey: "GET /users/{id}", response: .status(200)))
        persistence.flush()

        XCTAssertEqual(store.saved?.mocks.count, 1)

        Mocks.shared.removeAll()
        persistence.flush()

        XCTAssertEqual(store.saved?.mocks.count, 0)
    }

    /// `resolve` runs on the network task for every mocked request. Writing to
    /// disk from there would put file IO on the hot path.
    func testServingAMockDoesNotTriggerASave() {
        Mocks.shared.set(MockRule(endpointKey: "GET /users/{id}", response: .status(200)))
        persistence.beginAutosave()
        store.saveCount = 0

        var request = URLRequest(url: URL(string: "https://api.test/users/1")!)
        request.httpMethod = "GET"
        _ = Mocks.shared.resolve(request)
        persistence.flush()

        XCTAssertEqual(store.saveCount, 0)
    }

    func testRestoringDoesNotEchoBackToDisk() {
        Mocks.shared.set(MockRule(endpointKey: "GET /users/{id}", response: .status(200)))
        persistence.persist()
        persistence.beginAutosave()
        store.saveCount = 0

        persistence.restore(keepingActiveRules: true)
        persistence.flush()

        XCTAssertEqual(store.saveCount, 0, "restore must not write back what it just read")
    }

    func testEndAutosaveStopsWriting() {
        persistence.beginAutosave()
        persistence.endAutosave()
        store.saveCount = 0

        Mocks.shared.set(MockRule(endpointKey: "GET /users/{id}", response: .status(200)))
        persistence.flush()

        XCTAssertEqual(store.saveCount, 0)
    }

    // MARK: - File store

    func testFileStoreRoundTripsThroughDisk() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lens-tests-\(UUID().uuidString)")
            .appendingPathComponent("session.json")
        let fileStore = FileSnapshotStore(url: url)
        defer { try? fileStore.clear() }

        let snapshot = LensSnapshot(
            mocks: [MockRule(endpointKey: "GET /x", failure: .timedOut())],
            isMockingEnabled: false
        )
        try fileStore.save(snapshot)

        let loaded = try XCTUnwrap(fileStore.load())
        XCTAssertEqual(loaded, snapshot)

        try fileStore.clear()
        XCTAssertNil(try fileStore.load())
    }

    /// A snapshot from an older build can stop decoding when a rule shape
    /// changes. Losing rules is annoying; refusing to launch is worse.
    func testCorruptFileReadsAsNoRulesRatherThanThrowing() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lens-tests-\(UUID().uuidString)")
            .appendingPathComponent("session.json")
        let fileStore = FileSnapshotStore(url: url)
        defer { try? fileStore.clear() }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: url)

        XCTAssertNil(try fileStore.load())
    }

    func testLoadingAMissingFileReturnsNil() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lens-tests-\(UUID().uuidString)")
            .appendingPathComponent("session.json")

        XCTAssertNil(try FileSnapshotStore(url: url).load())
    }
}

/// In-memory store, so the suite never touches Application Support.
private final class MemorySnapshotStore: LensSnapshotStore, @unchecked Sendable {

    private let lock = NSLock()
    private var storage: LensSnapshot?
    private var count = 0

    var saved: LensSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var saveCount: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
        set {
            lock.lock()
            count = newValue
            lock.unlock()
        }
    }

    func load() throws -> LensSnapshot? { saved }

    func save(_ snapshot: LensSnapshot) throws {
        lock.lock()
        storage = snapshot
        count += 1
        lock.unlock()
    }

    func clear() throws {
        lock.lock()
        storage = nil
        lock.unlock()
    }
}
