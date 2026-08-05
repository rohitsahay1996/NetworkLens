//
//  InterceptionFidelityTests.swift
//  NetworkLensCoreTests
//
//  Created by Rohit Sahay on 01/08/26.
//

import XCTest
@testable import NetworkLensCore

/// What the tool is allowed to change about the app it is attached to, and what
/// it must retain of what it saw. Both are ways the same class of bug shows up:
/// the tool becomes the thing under test.
final class InterceptionFidelityTests: XCTestCase {

    private var session: URLSession!

    override func setUp() {
        super.setUp()
        NetworkLens.start(
            configuration: LensConfiguration(
                maxStoredExchanges: 50, maxCapturedResponseBodyBytes: 64
            )
        )
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
        PassthroughSession.shared.reset()
        session = nil
        NetworkLens.start(configuration: LensConfiguration(maxStoredExchanges: 50))
        super.tearDown()
    }

    private func url(_ path: String) -> URL {
        URL(string: "https://mock.invalid\(path)")!
    }

    // MARK: - Retention

    /// The cap used to set a flag and nothing else: the whole body went into a
    /// 500-entry ring buffer, so a screen that loads images ran the host app out
    /// of memory.
    func testLargeResponseIsRetainedOnlyUpToTheCap() async throws {
        let big = Data(String(repeating: "x", count: 5_000).utf8)
        Mocks.shared.set(
            MockRule(
                endpointKey: "GET /big",
                response: MockResponse(
                    statusCode: 200,
                    headers: ["Content-Type": "text/plain"],
                    body: big
                )
            )
        )

        let (delivered, _) = try await session.data(from: url("/big"))
        XCTAssertEqual(
            delivered.count, big.count,
            "the app is entitled to every byte — the cap is about what is kept"
        )

        let recorded = try XCTUnwrap(
            NetworkLens.store.exchanges.first { $0.endpointKey == "GET /big" }
        )
        XCTAssertEqual(recorded.response?.body?.count, 64)
        XCTAssertEqual(recorded.response?.bodyTruncated, true)
        XCTAssertEqual(
            recorded.response?.originalBodyByteCount, 5_000,
            "a truncated capture reporting its own length loses the one number that explains it"
        )
    }

    func testResponseUnderTheCapIsKeptWhole() async throws {
        Mocks.shared.set(
            MockRule(endpointKey: "GET /small", response: .json(#"{"a":1}"#))
        )

        _ = try await session.data(from: url("/small"))

        let recorded = try XCTUnwrap(
            NetworkLens.store.exchanges.first { $0.endpointKey == "GET /small" }
        )
        XCTAssertEqual(recorded.response?.bodyTruncated, false)
        XCTAssertEqual(String(decoding: recorded.response?.body ?? Data(), as: UTF8.self), #"{"a":1}"#)
    }

    // MARK: - Cancellation

    /// Navigating away mid-request is ordinary. It used to leave the exchange
    /// exactly as recorded on the way in — no response, no failure — which the
    /// list reads as still running, forever.
    func testCancelledRequestStopsBeingInFlight() async throws {
        Mocks.shared.set(MockRule(endpointKey: "GET /slow", steps: [.hang]))

        var request = URLRequest(url: url("/slow"))
        request.timeoutInterval = 60
        let task = Task { try await session.data(for: request) }

        let parked = Date().addingTimeInterval(3)
        while HangingRequests.shared.hanging.isEmpty, Date() < parked {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        task.cancel()
        _ = try? await task.value

        let recorded = try await settledExchange(forEndpointKey: "GET /slow")
        XCTAssertFalse(recorded.isInFlight)
        XCTAssertEqual(recorded.failure?.kind, .transport)
        XCTAssertEqual(recorded.failure?.code, URLError.cancelled.rawValue)
        XCTAssertEqual(
            NetworkLens.stats().inFlightCount, 0,
            "the in-flight count used to keep counting cancelled requests forever"
        )
    }

    /// Waits for the recording, which lands after the task has already thrown.
    private func settledExchange(forEndpointKey key: String) async throws -> NetworkExchange {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let match = NetworkLens.store.exchanges.first(
                where: { $0.endpointKey == key && !$0.isInFlight }
            ) {
                return match
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        // A failure, never a skip: "still in flight" is exactly the bug.
        XCTFail("\(key) never settled — it is still recorded as in flight")
        throw CocoaError(.featureUnsupported)
    }

    // MARK: - Passthrough fidelity

    /// The real leg runs on the lens's session, not the app's. Anything that
    /// session does not carry is dropped from every request while the tool is
    /// attached — and an empty cookie jar turns a cookie-authenticated app into
    /// a stream of 401s that only happen in debug builds.
    func testPassthroughAdoptsTheAppsConfiguration() {
        let app = URLSessionConfiguration.default
        app.httpAdditionalHeaders = ["X-App": "1"]
        app.allowsCellularAccess = false
        app.timeoutIntervalForResource = 42

        NetworkLens.install(into: app)
        let used = PassthroughSession.shared.session.configuration

        XCTAssertEqual(used.httpAdditionalHeaders?["X-App"] as? String, "1")
        XCTAssertFalse(used.allowsCellularAccess)
        XCTAssertEqual(used.timeoutIntervalForResource, 42)
    }

    func testPassthroughSharesTheAppsCookieJarByDefault() {
        PassthroughSession.shared.reset()

        let used = PassthroughSession.shared.session.configuration
        XCTAssertTrue(
            used.httpCookieStorage === HTTPCookieStorage.shared,
            "URLSession.shared and any .default session use the shared jar; so must the real leg"
        )
    }

    /// The tool's own protocol never goes on the passthrough leg, and caching
    /// stays off: a cached answer is one the lens cannot see, mock or edit.
    func testPassthroughExcludesTheLensAndItsCache() {
        let used = PassthroughSession.configuration(from: nil)

        XCTAssertFalse(used.protocolClasses?.contains { $0 == LensURLProtocol.self } ?? false)
        XCTAssertNil(used.urlCache)
        XCTAssertEqual(used.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }

    // MARK: - Redirects

    /// The passthrough leg used to follow redirects itself, which hid them from
    /// the app's own `willPerformHTTPRedirection` and left only the last hop on
    /// the timeline.
    func testPassthroughDeclinesToFollowRedirectsItself() throws {
        let observer = PassthroughObserver()
        let hop = try XCTUnwrap(
            HTTPURLResponse(
                url: url("/old"), statusCode: 302,
                httpVersion: "HTTP/1.1", headerFields: ["Location": "/new"]
            )
        )

        var followed: URLRequest?? = nil
        observer.urlSession(
            URLSession.shared,
            task: URLSession.shared.dataTask(with: url("/old")),
            willPerformHTTPRedirection: hop,
            newRequest: URLRequest(url: url("/new"))
        ) { followed = $0 }

        XCTAssertEqual(followed, .some(nil), "the hop belongs to the app, not to the tool")
        XCTAssertEqual(observer.offeredRedirect?.response.statusCode, 302)
        XCTAssertEqual(observer.offeredRedirect?.request.url, url("/new"))
    }

    /// A mocked 3xx is an answer, not an instruction: following it would send
    /// the app to a real server, and a mock that reaches the network is not one.
    func testMockedRedirectIsDeliveredAsAResponse() async throws {
        Mocks.shared.set(
            MockRule(
                endpointKey: "GET /old",
                response: MockResponse(statusCode: 302, headers: ["Location": "/new"])
            )
        )

        let (_, response) = try await session.data(from: url("/old"))

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 302)
        XCTAssertEqual(response.url, url("/old"), "it must not have gone anywhere")
    }

    /// The swizzled getters fire on every `.default` / `.ephemeral` access in
    /// the process, including from inside this tool. Letting them set the
    /// template would hand the app's cookie jar to whichever call ran last.
    func testSwizzledInstallDoesNotAdoptTheTemplate() {
        let app = URLSessionConfiguration.default
        app.httpAdditionalHeaders = ["X-App": "1"]
        NetworkLens.install(into: app)

        let incidental = URLSessionConfiguration.ephemeral
        incidental.httpAdditionalHeaders = ["X-Incidental": "1"]
        NetworkLens.install(into: incidental, adoptingForPassthrough: false)

        let used = PassthroughSession.shared.session.configuration
        XCTAssertEqual(used.httpAdditionalHeaders?["X-App"] as? String, "1")
        XCTAssertNil(used.httpAdditionalHeaders?["X-Incidental"])
    }
}
