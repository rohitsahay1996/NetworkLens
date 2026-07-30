//
//  MockInterceptionTests.swift
//  NetworkLensCoreTests
//
//  Created by Rohit Sahay on 30/07/26.
//

import XCTest
@testable import NetworkLensCore

/// End-to-end proof that a rule short-circuits the network leg.
///
/// Every request goes to a `.invalid` host, which can never resolve. A mock that
/// fails to claim the request therefore fails the test loudly instead of quietly
/// hitting something real.
final class MockInterceptionTests: XCTestCase {

    private var session: URLSession!

    override func setUp() {
        super.setUp()
        NetworkLens.start(configuration: LensConfiguration(maxStoredExchanges: 50))
        NetworkLens.store.removeAll()
        Mocks.shared.removeAll()
        Breakpoints.shared.removeAll()

        let configuration = URLSessionConfiguration.ephemeral
        NetworkLens.install(into: configuration)
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        Mocks.shared.removeAll()
        NetworkLens.store.removeAll()
        session = nil
        super.tearDown()
    }

    private func url(_ path: String) -> URL {
        URL(string: "https://mock.invalid\(path)")!
    }

    // MARK: - Attribution

    /// One row per request, carrying the caller's screen tag. The demo used to
    /// record by hand on top of interception, which produced two rows per
    /// request under two ids.
    func testTaggedRequestIsRecordedOnceWithItsScreen() async throws {
        Mocks.shared.set(
            MockRule(endpointKey: "GET /orders", response: .json("{}"))
        )

        let tagged = NetworkLens.tagged(
            URLRequest(url: url("/orders")), screen: "Checkout"
        )
        _ = try await session.data(for: tagged)

        let recorded = NetworkLens.store.exchanges.filter { $0.endpointKey == "GET /orders" }
        XCTAssertEqual(recorded.count, 1, "interception must be the only writer")
        XCTAssertEqual(recorded.first?.screen, "Checkout")
    }

    /// The tag travels with the request, so concurrent fires cannot take each
    /// other's screen the way overlapping `ScreenContext` pushes would.
    func testConcurrentTaggedRequestsKeepTheirOwnScreens() async throws {
        for path in ["/a", "/b", "/c"] {
            Mocks.shared.set(
                MockRule(endpointKey: "GET \(path)", response: .json("{}"))
            )
        }

        await withTaskGroup(of: Void.self) { group in
            for path in ["/a", "/b", "/c"] {
                group.addTask { [session] in
                    let request = NetworkLens.tagged(
                        URLRequest(url: self.url(path)), screen: "screen\(path)"
                    )
                    _ = try? await session?.data(for: request)
                }
            }
        }

        for path in ["/a", "/b", "/c"] {
            let match = NetworkLens.store.exchanges.first { $0.endpointKey == "GET \(path)" }
            XCTAssertEqual(match?.screen, "screen\(path)")
        }
    }

    // MARK: - Serving

    func testMockedRequestNeverLeavesTheDevice() async throws {
        Mocks.shared.set(
            MockRule(
                endpointKey: "GET /users/{id}",
                response: .json(#"{"id":7,"name":"mocked"}"#, headers: ["X-Lens": "1"]),
                name: "user"
            )
        )

        let (data, response) = try await session.data(from: url("/users/7"))
        let http = try XCTUnwrap(response as? HTTPURLResponse)

        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.value(forHTTPHeaderField: "X-Lens"), "1")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Length"), "\(data.count)")
        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"id":7,"name":"mocked"}"#)
    }

    func testMockedErrorStatusIsDeliveredAsAResponseNotAFailure() async throws {
        Mocks.shared.set(
            MockRule(endpointKey: "POST /orders", response: .status(503))
        )

        var request = URLRequest(url: url("/orders"))
        request.httpMethod = "POST"
        let (_, response) = try await session.data(for: request)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 503)
    }

    func testMockedExchangeIsRecordedAsMockedAndCounted() async throws {
        let rule = MockRule(endpointKey: "GET /users/{id}", response: .json("{}"))
        Mocks.shared.set(rule)

        _ = try await session.data(from: url("/users/7"))
        _ = try await session.data(from: url("/users/8"))

        let exchanges = NetworkLens.store.exchanges.filter { $0.endpointKey == "GET /users/{id}" }
        XCTAssertEqual(exchanges.count, 2)
        XCTAssertTrue(exchanges.allSatisfy { $0.source == .mocked })
        XCTAssertTrue(exchanges.allSatisfy { $0.response?.statusCode == 200 })
        XCTAssertTrue(exchanges.allSatisfy { !$0.isInFlight })
        XCTAssertEqual(Mocks.shared.hitCount(forRuleID: rule.id), 2)
        XCTAssertEqual(NetworkLens.stats().endpoints.first?.count, 2)
    }

    // MARK: - Latency

    func testDelayIsImposedBeforeTheResponseArrives() async throws {
        Mocks.shared.set(
            MockRule(endpointKey: "GET /slow", response: .status(200, delay: 0.4))
        )

        let startedAt = Date()
        _ = try await session.data(from: url("/slow"))
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertGreaterThanOrEqual(elapsed, 0.35)
    }

    /// A delay past the request timeout must produce the error the real stack
    /// would, not an indefinite hang.
    func testDelayBeyondTheRequestTimeoutFailsWithTimedOut() async {
        Mocks.shared.set(
            MockRule(endpointKey: "GET /hang", response: .status(200, delay: 30))
        )

        var request = URLRequest(url: url("/hang"))
        request.timeoutInterval = 0.3

        do {
            _ = try await session.data(for: request)
            XCTFail("expected the mock to time out")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
    }

    // MARK: - Failure injection

    func testInjectedFailureReachesTheAppAsAPlainURLError() async {
        Mocks.shared.set(
            MockRule(endpointKey: "GET /users/{id}", failure: .offline(), name: "airplane mode")
        )

        do {
            _ = try await session.data(from: url("/users/7"))
            XCTFail("expected the injected failure")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
    }

    func testInjectedFailureIsRecordedAsAMockedTransportFailure() async throws {
        Mocks.shared.set(
            MockRule(endpointKey: "GET /users/{id}", failure: .connectionLost())
        )

        _ = try? await session.data(from: url("/users/7"))

        let exchange = try XCTUnwrap(
            NetworkLens.store.exchanges.first { $0.endpointKey == "GET /users/{id}" }
        )
        XCTAssertEqual(exchange.source, .mocked)
        XCTAssertEqual(exchange.failure?.kind, .transport)
        XCTAssertEqual(exchange.failure?.code, URLError.networkConnectionLost.rawValue)
        XCTAssertFalse(exchange.isInFlight)
    }

    func testFailureDelayIsImposedBeforeItFires() async {
        Mocks.shared.set(
            MockRule(endpointKey: "GET /slow-fail", failure: .offline(delay: 0.4))
        )

        let startedAt = Date()
        _ = try? await session.data(from: url("/slow-fail"))

        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(startedAt), 0.35)
    }

    // MARK: - Scripts

    /// The retry case, end to end: two failures from the device, then a
    /// success, without touching a server at any point.
    func testScriptedRuleServesADifferentOutcomePerAttempt() async throws {
        Mocks.shared.set(
            MockRule(
                endpointKey: "GET /flaky",
                steps: [
                    .fail(.connectionLost()),
                    .respond(.status(503)),
                    .respond(.json(#"{"ok":true}"#))
                ],
                name: "flaky endpoint"
            )
        )

        do {
            _ = try await session.data(from: url("/flaky"))
            XCTFail("expected the first attempt to fail")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
        }

        let (_, second) = try await session.data(from: url("/flaky"))
        XCTAssertEqual((second as? HTTPURLResponse)?.statusCode, 503)

        let (body, third) = try await session.data(from: url("/flaky"))
        XCTAssertEqual((third as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(data: body, encoding: .utf8), #"{"ok":true}"#)

        // Exhaustion defaults to repeating the last step.
        let (_, fourth) = try await session.data(from: url("/flaky"))
        XCTAssertEqual((fourth as? HTTPURLResponse)?.statusCode, 200)
    }

    /// A spent `.passThrough` script hands the endpoint back to the network.
    /// The host is `.invalid`, so "went live" shows up as a DNS failure rather
    /// than as another mocked answer.
    func testPassThroughScriptReleasesTheEndpointOnceSpent() async throws {
        Mocks.shared.set(
            MockRule(
                endpointKey: "GET /once",
                steps: [.respond(.status(201))],
                exhaustion: .passThrough
            )
        )

        let (_, response) = try await session.data(from: url("/once"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 201)

        do {
            _ = try await session.data(from: url("/once"))
            XCTFail("expected the second request to go to the network and fail DNS")
        } catch {
            XCTAssertNotEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
    }

    // MARK: - Replay

    /// Iterating on a state used to mean navigating away and back. Replay is
    /// what removes that from the loop.
    func testReplaySendsTheRequestAgainThroughThePipeline() async throws {
        Mocks.shared.set(
            MockRule(endpointKey: "GET /cart", response: .json(#"{"v":1}"#), name: "one")
        )
        _ = try await session.data(from: url("/cart"))

        let original = try XCTUnwrap(
            NetworkLens.store.exchanges.first { $0.endpointKey == "GET /cart" }
        )
        XCTAssertTrue(NetworkLens.canReplay(original))

        // Swap the answer, then replay: the replay must pick up what is armed
        // now, not repeat what was captured.
        Mocks.shared.set(
            MockRule(endpointKey: "GET /cart", response: .json(#"{"v":2}"#), name: "two")
        )
        let result = try await NetworkLens.replay(original)
        let replayed = try XCTUnwrap(result)

        XCTAssertEqual(replayed.replayOf, original.id)
        XCTAssertTrue(replayed.isReplay)
        XCTAssertNotEqual(replayed.id, original.id, "a replay is its own exchange")
        XCTAssertEqual(
            String(decoding: replayed.response?.body ?? Data(), as: UTF8.self), #"{"v":2}"#
        )
        XCTAssertEqual(replayed.screen, original.screen)
    }

    /// Replaying the redacted snapshot would send `Authorization: ***`, so the
    /// unredacted request is kept separately — and it has to be used.
    func testReplayCarriesTheOriginalUnredactedHeaders() async throws {
        NetworkLens.start(
            configuration: LensConfiguration(redactor: DefaultRedactor(), maxStoredExchanges: 50)
        )
        NetworkLens.store.removeAll()
        Mocks.shared.set(MockRule(endpointKey: "GET /secure", response: .json("{}")))

        var request = URLRequest(url: url("/secure"))
        request.setValue("Bearer real-token", forHTTPHeaderField: "Authorization")
        _ = try await session.data(for: request)

        let original = try XCTUnwrap(
            NetworkLens.store.exchanges.first { $0.endpointKey == "GET /secure" }
        )
        XCTAssertNotEqual(
            original.request.headers["Authorization"], "Bearer real-token",
            "the stored snapshot is redacted, which is why replay cannot use it"
        )

        let sent = try XCTUnwrap(ReplayStore.shared.request(for: original.id))
        XCTAssertEqual(
            sent.value(forHTTPHeaderField: "Authorization"), "Bearer real-token",
            "the replayable copy must be the real one"
        )

        NetworkLens.start(configuration: LensConfiguration(maxStoredExchanges: 50))
    }

    /// An exchange from a previous launch has no replayable request, and saying
    /// so beats sending a redacted one that fails for unrelated reasons.
    func testReplayingAnUnknownExchangeThrows() async {
        let stranger = NetworkExchange(
            endpointKey: "GET /gone",
            request: RequestSnapshot(method: "GET", url: url("/gone"))
        )

        XCTAssertFalse(NetworkLens.canReplay(stranger))
        do {
            _ = try await NetworkLens.replay(stranger)
            XCTFail("expected a replay error")
        } catch {
            XCTAssertEqual(error as? NetworkLens.ReplayError, .originalRequestUnavailable)
        }
    }

    func testReplayStoreEvictsOldestBeyondItsLimit() {
        let store = ReplayStore(limit: 2)
        let ids = (0..<3).map { _ in UUID() }
        for id in ids {
            store.record(URLRequest(url: url("/x")), for: id)
        }

        XCTAssertEqual(store.count, 2)
        XCTAssertFalse(store.canReplay(ids[0]), "the oldest goes first")
        XCTAssertTrue(store.canReplay(ids[2]))
    }

    // MARK: - Provenance

    /// The label moves to the perturbation; the fact that no server was
    /// involved must not move with it.
    func testPerturbingAMockedResponseKeepsBothClaims() async throws {
        Mocks.shared.set(
            MockRule(endpointKey: "GET /cart", response: .json(#"{"items":[1]}"#))
        )
        Breakpoints.shared.save(
            Perturbation(
                name: "empty cart",
                endpointKey: "GET /cart",
                ops: [try PatchOp(kind: .replace, path: "/items", value: .array([]))],
                isEnabled: true
            )
        )

        _ = try await session.data(from: url("/cart"))

        let recorded = try XCTUnwrap(
            NetworkLens.store.exchanges.first { $0.endpointKey == "GET /cart" }
        )
        XCTAssertEqual(recorded.source.label, "empty cart", "the latest label is what changed it")
        XCTAssertTrue(
            recorded.isMockServed,
            "a perturbation relabelling a mocked payload must not imply a server answered"
        )

        Breakpoints.shared.removeAll()
    }

    func testLiveResponseIsNotMarkedAsMockServed() async throws {
        Mocks.shared.set(MockRule(endpointKey: "GET /cart", response: .json("{}")))
        _ = try await session.data(from: url("/cart"))

        let mocked = NetworkLens.store.exchanges.first { $0.endpointKey == "GET /cart" }
        XCTAssertEqual(mocked?.isMockServed, true)

        Mocks.shared.removeAll()
        NetworkLens.store.removeAll()
        _ = try? await session.data(from: url("/cart"))

        let live = NetworkLens.store.exchanges.first { $0.endpointKey == "GET /cart" }
        XCTAssertEqual(live?.isMockServed, false)
    }

    /// A released hang goes to the real server, so it has to give the device
    /// origin back rather than keep claiming it.
    func testReleasedHangStopsClaimingDeviceOrigin() async throws {
        Mocks.shared.set(MockRule(endpointKey: "GET /slow", steps: [.hang]))

        var request = URLRequest(url: url("/slow"))
        request.timeoutInterval = 30
        let task = Task { try await session.data(for: request) }

        let deadline = Date().addingTimeInterval(3)
        while HangingRequests.shared.hanging.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        HangingRequests.shared.releaseAll()
        _ = try? await task.value

        let recorded = try XCTUnwrap(
            NetworkLens.store.exchanges.first { $0.endpointKey == "GET /slow" }
        )
        XCTAssertFalse(recorded.isMockServed)
        XCTAssertEqual(recorded.source.label, "live")
    }

    // MARK: - Audit trail for hand edits

    /// A bug report says "with this field set to null". Only the ops prove
    /// that is what happened — recording just `source = .edited` does not.
    func testHandEditedResponseRecordsTheOpsThatProducedIt() async throws {
        Breakpoints.shared.set(Breakpoint(endpointKey: "GET /cart", stage: .response))
        Mocks.shared.set(
            MockRule(endpointKey: "GET /cart", response: .json(#"{"total":42,"items":[]}"#))
        )

        async let load: (Data, URLResponse) = session.data(from: url("/cart"))

        let coordinator = BreakpointCoordinator.shared
        let deadline = Date().addingTimeInterval(5)
        var held: BreakpointCoordinator.Pending?
        while held == nil, Date() < deadline {
            held = await coordinator.presented
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let pending = try XCTUnwrap(held)
        guard case .response(let payload) = pending.payload else {
            return XCTFail("expected a response payload")
        }

        await coordinator.resolve(
            id: pending.id,
            with: .proceed(
                .response(payload.replacingBody(Data(#"{"total":0,"items":[]}"#.utf8)))
            )
        )
        _ = try await load

        let recorded = try XCTUnwrap(
            NetworkLens.store.exchanges.first { $0.endpointKey == "GET /cart" }
        )
        XCTAssertEqual(recorded.source.label, "edited")
        let record = try XCTUnwrap(recorded.edits.first)
        XCTAssertEqual(record.stage, .response)
        XCTAssertNil(record.perturbationName, "a hand edit belongs to no saved variant")
        XCTAssertEqual(record.ops.count, 1)
        XCTAssertEqual(record.ops.first?.path.description, "/total")
        XCTAssertFalse(record.originalHash.isEmpty)

        Breakpoints.shared.removeAll()
    }

    /// Resuming unchanged is not an edit and must not look like one.
    func testResumingUnchangedRecordsNoEdit() async throws {
        Breakpoints.shared.set(Breakpoint(endpointKey: "GET /cart", stage: .response))
        Mocks.shared.set(MockRule(endpointKey: "GET /cart", response: .json(#"{"a":1}"#)))

        async let load: (Data, URLResponse) = session.data(from: url("/cart"))

        let coordinator = BreakpointCoordinator.shared
        let deadline = Date().addingTimeInterval(5)
        var held: BreakpointCoordinator.Pending?
        while held == nil, Date() < deadline {
            held = await coordinator.presented
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let pending = try XCTUnwrap(held)
        await coordinator.resolve(id: pending.id, with: .proceed(pending.payload))
        _ = try await load

        let recorded = NetworkLens.store.exchanges.first { $0.endpointKey == "GET /cart" }
        XCTAssertTrue(recorded?.edits.isEmpty ?? false)
        XCTAssertEqual(recorded?.source.label, "mocked")

        Breakpoints.shared.removeAll()
    }

    // MARK: - Perturbations

    private func perturbation(
        _ name: String, path: String, value: JSONNode, kind: PatchOp.Kind = .replace,
        enabled: Bool = true, shape: String? = nil
    ) throws -> Perturbation {
        Perturbation(
            name: name,
            endpointKey: "GET /cart",
            ops: [try PatchOp(kind: kind, path: path, value: value)],
            isEnabled: enabled,
            verifiedAgainstShape: shape
        )
    }

    /// The whole point: a saved edit rewrites live traffic with nobody present.
    func testArmedPerturbationRewritesTheResponse() async throws {
        Mocks.shared.set(
            MockRule(
                endpointKey: "GET /cart",
                response: .json(#"{"items":[{"sku":"A"}],"total":42}"#)
            )
        )
        Breakpoints.shared.save(
            try perturbation("empty cart", path: "/items", value: .array([]))
        )

        let (data, _) = try await session.data(from: url("/cart"))
        let node = try JSONNodeParser.parse(data)

        XCTAssertEqual(node.value(at: try JSONPointer(string: "/items")), .array([]))
        XCTAssertEqual(
            node.value(at: try JSONPointer(string: "/total"))?.numberLiteral, "42",
            "untouched fields must survive"
        )

        let recorded = NetworkLens.store.exchanges.first { $0.endpointKey == "GET /cart" }
        XCTAssertEqual(recorded?.source.label, "empty cart")
        XCTAssertEqual(recorded?.edits.first?.perturbationName, "empty cart")
        XCTAssertFalse(recorded?.edits.first?.shapeDrifted ?? true)

        Breakpoints.shared.removeAll()
    }

    /// Saving a variant must not start rewriting traffic on its own.
    func testDisabledPerturbationIsNotApplied() async throws {
        Mocks.shared.set(
            MockRule(endpointKey: "GET /cart", response: .json(#"{"items":[{"sku":"A"}]}"#))
        )
        Breakpoints.shared.save(
            try perturbation("empty cart", path: "/items", value: .array([]), enabled: false)
        )

        let (data, _) = try await session.data(from: url("/cart"))
        let node = try JSONNodeParser.parse(data)

        guard case .array(let items)? = node.value(at: try JSONPointer(string: "/items")) else {
            return XCTFail("expected the original array")
        }
        XCTAssertEqual(items.count, 1)

        let recorded = NetworkLens.store.exchanges.first { $0.endpointKey == "GET /cart" }
        XCTAssertTrue(recorded?.edits.isEmpty ?? false)

        Breakpoints.shared.removeAll()
    }

    /// A contract change flags the edit rather than silently declining it —
    /// skipping looks exactly like a broken tool.
    func testDriftedPerturbationStillAppliesAndIsFlagged() async throws {
        Mocks.shared.set(
            MockRule(endpointKey: "GET /cart", response: .json(#"{"items":[],"newField":1}"#))
        )
        Breakpoints.shared.save(
            try perturbation(
                "empty cart", path: "/items", value: .array([]),
                shape: "a-shape-the-server-no-longer-sends"
            )
        )

        _ = try await session.data(from: url("/cart"))

        let recorded = NetworkLens.store.exchanges.first { $0.endpointKey == "GET /cart" }
        XCTAssertEqual(recorded?.edits.count, 1)
        XCTAssertTrue(
            recorded?.edits.first?.shapeDrifted ?? false,
            "drift has to be reported, not swallowed"
        )

        Breakpoints.shared.removeAll()
    }

    func testMultiplePerturbationsComposeInSaveOrder() async throws {
        Mocks.shared.set(
            MockRule(endpointKey: "GET /cart", response: .json(#"{"items":[],"total":42}"#))
        )
        Breakpoints.shared.save(try perturbation("zero total", path: "/total", value: .number("0")))
        Breakpoints.shared.save(
            try perturbation("flag", path: "/promo", value: .string("SUMMER"), kind: .add)
        )

        let (data, _) = try await session.data(from: url("/cart"))
        let node = try JSONNodeParser.parse(data)

        XCTAssertEqual(node.value(at: try JSONPointer(string: "/total"))?.numberLiteral, "0")
        XCTAssertEqual(node.value(at: try JSONPointer(string: "/promo"))?.stringValue, "SUMMER")

        let recorded = NetworkLens.store.exchanges.first { $0.endpointKey == "GET /cart" }
        XCTAssertEqual(recorded?.edits.count, 2)

        Breakpoints.shared.removeAll()
    }

    /// Nothing for a JSON Pointer to address, so the bytes are left alone
    /// rather than rewritten blind.
    func testPerturbationLeavesNonJSONBodiesUntouched() async throws {
        Mocks.shared.set(
            MockRule(
                endpointKey: "GET /cart",
                response: MockResponse(
                    statusCode: 200,
                    headers: ["Content-Type": "text/html"],
                    body: Data("<html>hi</html>".utf8)
                )
            )
        )
        Breakpoints.shared.save(
            try perturbation("empty cart", path: "/items", value: .array([]))
        )

        let (data, _) = try await session.data(from: url("/cart"))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "<html>hi</html>")

        Breakpoints.shared.removeAll()
    }

    // MARK: - Hanging

    /// The loading state, which a delay cannot reach: a delay is clamped to the
    /// request timeout and converted to `.timedOut`, so it never just sits.
    /// Here the app's own timeout is what ends it, exactly as a dead server
    /// would.
    func testHangingMockLeavesTheRequestPendingUntilTheAppsOwnTimeout() async throws {
        Mocks.shared.set(
            MockRule(endpointKey: "GET /slow", steps: [.hang], name: "stuck loading")
        )

        var request = URLRequest(url: url("/slow"))
        request.timeoutInterval = 2

        let started = Date()
        do {
            _ = try await session.data(for: request)
            XCTFail("a hanging mock must not produce a response")
        } catch {
            let elapsed = Date().timeIntervalSince(started)
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
            XCTAssertGreaterThan(elapsed, 1.5, "it must actually stay pending, not fail early")
        }

        let recorded = NetworkLens.store.exchanges.first { $0.endpointKey == "GET /slow" }
        XCTAssertEqual(recorded?.source.label, "mocked")
    }

    /// Navigating away mid-load has to release it, or the protocol instance
    /// sits parked long after the app stopped caring.
    func testHangingMockIsReleasedByCancellation() async throws {
        Mocks.shared.set(MockRule(endpointKey: "GET /slow", steps: [.hang]))

        var request = URLRequest(url: url("/slow"))
        request.timeoutInterval = 60

        let task = Task { try await session.data(for: request) }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cancelled)
        }
    }

    /// "Fine, now let it load." Waiting out a 60s timeout to reach the loaded
    /// state is not a workflow.
    func testReleasingAHangResumesToTheNetwork() async throws {
        Mocks.shared.set(MockRule(endpointKey: "GET /slow", steps: [.hang]))

        var request = URLRequest(url: url("/slow"))
        request.timeoutInterval = 30
        let started = Date()
        let task = Task { try await session.data(for: request) }

        // Wait for it to actually park.
        let deadline = Date().addingTimeInterval(3)
        while HangingRequests.shared.hanging.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let parked = try XCTUnwrap(HangingRequests.shared.hanging.first)

        HangingRequests.shared.release(parked)

        // `.invalid` cannot resolve, which is the proof it went to the network
        // rather than being handed a response the tool made up.
        do {
            _ = try await task.value
            XCTFail("expected the real network leg, which cannot resolve")
        } catch {
            XCTAssertNotEqual(
                (error as? URLError)?.code, .timedOut,
                "it must resume on release, not sit until the app's timeout"
            )
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        XCTAssertTrue(
            HangingRequests.shared.hanging.isEmpty,
            "a released request must not stay registered"
        )
    }

    /// A screen's calls park together, so they have to be releasable together.
    func testReleaseAllFreesEveryParkedRequest() async throws {
        for path in ["/a", "/b"] {
            Mocks.shared.set(MockRule(endpointKey: "GET \(path)", steps: [.hang]))
        }

        let tasks = ["/a", "/b"].map { path in
            Task { [session] in try await session?.data(from: self.url(path)) }
        }

        let deadline = Date().addingTimeInterval(3)
        while HangingRequests.shared.hanging.count < 2, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(HangingRequests.shared.hanging.count, 2)

        HangingRequests.shared.releaseAll()
        for task in tasks { _ = try? await task.value }

        XCTAssertTrue(HangingRequests.shared.hanging.isEmpty)
    }

    /// Cancelling must deregister too, or the list fills with rows nobody can
    /// clear.
    func testCancelledHangIsDeregistered() async throws {
        Mocks.shared.set(MockRule(endpointKey: "GET /slow", steps: [.hang]))

        var request = URLRequest(url: url("/slow"))
        request.timeoutInterval = 30
        let task = Task { try await session.data(for: request) }

        let deadline = Date().addingTimeInterval(3)
        while HangingRequests.shared.hanging.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        task.cancel()
        _ = try? await task.value

        let cleared = Date().addingTimeInterval(2)
        while !HangingRequests.shared.hanging.isEmpty, Date() < cleared {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(HangingRequests.shared.hanging.isEmpty)
    }

    // MARK: - Precedence

    /// Request editing pauses traffic on its way to a server. A mocked request
    /// has no server, so the breakpoint must not hold it — otherwise a mock
    /// armed alongside a breakpoint hangs with no one watching.
    func testRequestBreakpointDoesNotHoldAMockedRequest() async throws {
        Breakpoints.shared.setRequestEditingEnabled(true)
        Breakpoints.shared.set(Breakpoint(endpointKey: "GET /users/{id}", stage: .request))
        Mocks.shared.set(MockRule(endpointKey: "GET /users/{id}", response: .status(201)))

        var request = URLRequest(url: url("/users/7"))
        request.timeoutInterval = 5
        let (_, response) = try await session.data(for: request)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 201)

        Breakpoints.shared.setRequestEditingEnabled(false)
        Breakpoints.shared.removeAll()
    }

    /// Editing a held response and resuming must deliver it. Reported as "the
    /// API never completes" after arming a breakpoint and tapping Resume.
    func testEditedResponseIsDeliveredAfterResume() async throws {
        Breakpoints.shared.set(Breakpoint(endpointKey: "GET /users/{id}", stage: .response))
        Mocks.shared.set(
            MockRule(endpointKey: "GET /users/{id}", response: .json(#"{"name":"live"}"#))
        )

        var request = URLRequest(url: url("/users/7"))
        request.timeoutInterval = 10

        async let load: (Data, URLResponse) = session.data(for: request)

        // Stand in for the sheet: wait for the hold, edit, resume.
        let coordinator = BreakpointCoordinator.shared
        let deadline = Date().addingTimeInterval(5)
        var held: BreakpointCoordinator.Pending?
        while held == nil, Date() < deadline {
            held = await coordinator.presented
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let pending = try XCTUnwrap(held, "the response breakpoint never held")
        guard case .response(let payload) = pending.payload else {
            return XCTFail("expected a response payload")
        }

        await coordinator.resolve(
            id: pending.id,
            with: .proceed(.response(payload.replacingBody(Data(#"{"name":"edited"}"#.utf8))))
        )

        let (data, response) = try await load
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"name":"edited"}"#)

        let recorded = NetworkLens.store.exchanges.first { $0.endpointKey == "GET /users/{id}" }
        XCTAssertFalse(recorded?.isInFlight ?? true, "the row must not be left in flight")
        XCTAssertEqual(recorded?.source.label, "edited")

        Breakpoints.shared.removeAll()
    }

    func testDisabledRuleFallsThroughToTheNetwork() async {
        Mocks.shared.set(
            MockRule(endpointKey: "GET /users/{id}", response: .status(200), isEnabled: false)
        )

        do {
            _ = try await session.data(from: url("/users/7"))
            XCTFail("expected the unmocked request to fail DNS resolution")
        } catch {
            // Any transport error proves the request was not served locally.
            XCTAssertTrue(error is URLError)
        }
    }
}
