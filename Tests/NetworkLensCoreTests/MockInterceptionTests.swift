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
