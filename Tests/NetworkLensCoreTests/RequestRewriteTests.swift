//
//  RequestRewriteTests.swift
//  NetworkLensCoreTests
//
//  Created by Rohit Sahay on 31/07/26.
//

import XCTest
@testable import NetworkLensCore

/// Mocking the request, not the response.
///
/// The distinguishing fact throughout: a rewrite reaches a **real server**.
/// Everything else the tool does stays on the device, so this is the only
/// feature whose bugs can create real records.
final class RequestRewriteTests: XCTestCase {

    override func setUp() {
        super.setUp()
        NetworkLens.start(configuration: LensConfiguration(maxStoredExchanges: 50))
        NetworkLens.store.removeAll()
        Mocks.shared.removeAll()
        // Stated rather than assumed: the master switch is global, and a suite
        // that leaves it off makes every serving test here fail for a reason
        // that has nothing to do with what it is testing.
        Mocks.shared.setMockingEnabled(true)
    }

    override func tearDown() {
        Mocks.shared.removeAll()
        NetworkLens.store.removeAll()
        NetworkLens.start(configuration: LensConfiguration(maxStoredExchanges: 50))
        super.tearDown()
    }

    private func request(_ url: String = "https://staging.test/orders") -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"sku":"A-1","qty":1}"#.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    // MARK: - Applying

    func testRewriteReplacesBodyAndRecomputesContentLength() {
        let body = Data(#"{"sku":"A-1","qty":9999}"#.utf8)
        let rewritten = MockRequestRewrite(body: body).applied(to: request())

        XCTAssertEqual(rewritten.httpBody, body)
        XCTAssertEqual(
            rewritten.value(forHTTPHeaderField: "Content-Length"), "\(body.count)",
            "a stale Content-Length truncates the body server-side"
        )
    }

    func testRewriteSetsAndRemovesHeadersAndMethod() {
        let rewrite = MockRequestRewrite(
            headers: ["X-Debug": "1", "Content-Type": "text/plain"],
            removedHeaders: ["Authorization"],
            method: "PUT"
        )
        var original = request()
        original.setValue("Bearer token", forHTTPHeaderField: "Authorization")

        let rewritten = rewrite.applied(to: original)

        XCTAssertEqual(rewritten.httpMethod, "PUT")
        XCTAssertEqual(rewritten.value(forHTTPHeaderField: "X-Debug"), "1")
        XCTAssertEqual(rewritten.value(forHTTPHeaderField: "Content-Type"), "text/plain")
        XCTAssertNil(rewritten.value(forHTTPHeaderField: "Authorization"))
    }

    func testEmptyRewriteChangesNothing() {
        let rewrite = MockRequestRewrite()
        XCTAssertTrue(rewrite.isEmpty)
        XCTAssertNil(rewrite.summary)

        let original = request()
        let rewritten = rewrite.applied(to: original)
        XCTAssertEqual(rewritten.httpBody, original.httpBody)
        XCTAssertEqual(rewritten.httpMethod, original.httpMethod)
    }

    // MARK: - The production guard

    /// The reason this feature has a guard at all: a fabricated order sent to a
    /// real backend is a real order.
    func testRewriteIsRefusedOnAProductionHost() async throws {
        NetworkLens.start(
            configuration: LensConfiguration(
                maxStoredExchanges: 50,
                productionHostPatterns: ["*.myapp.invalid"]
            )
        )
        NetworkLens.store.removeAll()

        Mocks.shared.set(
            MockRule(
                endpointKey: "POST /orders",
                steps: [.rewrite(MockRequestRewrite(body: Data(#"{"qty":9999}"#.utf8)))]
            )
        )

        let configuration = URLSessionConfiguration.ephemeral
        NetworkLens.install(into: configuration)
        let session = URLSession(configuration: configuration)

        // The pattern matches this host, and `.invalid` never resolves — so the
        // guard is exercised and nothing leaves the machine.
        _ = try? await session.data(for: request("https://api.myapp.invalid/orders"))

        let recorded = NetworkLens.store.exchanges.first { $0.endpointKey == "POST /orders" }
        XCTAssertEqual(
            recorded?.request.body, Data(#"{"sku":"A-1","qty":1}"#.utf8),
            "the app's own body must reach a production host unchanged"
        )
        XCTAssertNotEqual(recorded?.source.label, "edited")
    }

    /// Refusing silently would read as the tool being broken.
    func testRefusedRewritesAreReported() async throws {
        NetworkLens.start(
            configuration: LensConfiguration(
                maxStoredExchanges: 50,
                productionHostPatterns: ["*.myapp.invalid"]
            )
        )
        Mocks.shared.set(
            MockRule(
                endpointKey: "POST /orders",
                steps: [.rewrite(MockRequestRewrite(body: Data("{}".utf8)))]
            )
        )

        let configuration = URLSessionConfiguration.ephemeral
        NetworkLens.install(into: configuration)
        let session = URLSession(configuration: configuration)
        _ = try? await session.data(for: request("https://api.myapp.invalid/orders"))

        XCTAssertTrue(
            NetworkLens.blockedRewrites.contains { $0.contains("POST /orders") },
            "the tester has to be told the rewrite was refused"
        )
    }

    // MARK: - Recording

    /// A rewrite that reached a server has to be provable afterwards.
    func testAppliedRewriteIsRecordedWithTheOpsThatChangedIt() async throws {
        Mocks.shared.set(
            MockRule(
                endpointKey: "POST /orders",
                steps: [.rewrite(MockRequestRewrite(body: Data(#"{"sku":"A-1","qty":9999}"#.utf8)))]
            )
        )

        let configuration = URLSessionConfiguration.ephemeral
        NetworkLens.install(into: configuration)
        let session = URLSession(configuration: configuration)
        _ = try? await session.data(for: request("https://staging.test.invalid/orders"))

        let recorded = try XCTUnwrap(
            NetworkLens.store.exchanges.first { $0.endpointKey == "POST /orders" }
        )
        XCTAssertEqual(recorded.request.body, Data(#"{"sku":"A-1","qty":9999}"#.utf8))
        XCTAssertEqual(recorded.source.label, "edited")

        let edit = try XCTUnwrap(recorded.edits.first)
        XCTAssertEqual(edit.stage, .request)
        XCTAssertEqual(edit.ops.first?.path.description, "/qty")
    }

    /// A rewrite does not answer the request; the server does. The proof is
    /// that an unreachable host still fails.
    func testRewrittenRequestStillGoesToTheNetwork() async {
        Mocks.shared.set(
            MockRule(
                endpointKey: "POST /orders",
                steps: [.rewrite(MockRequestRewrite(body: Data("{}".utf8)))]
            )
        )

        let configuration = URLSessionConfiguration.ephemeral
        NetworkLens.install(into: configuration)
        let session = URLSession(configuration: configuration)

        do {
            _ = try await session.data(for: request("https://staging.test.invalid/orders"))
            XCTFail("a rewrite must not answer the request itself")
        } catch {
            XCTAssertNotNil(error as? URLError)
        }
    }

    // MARK: - Model

    func testRewriteSurvivesACodableRoundTrip() throws {
        let rule = MockRule(
            endpointKey: "POST /orders",
            steps: [
                .rewrite(
                    MockRequestRewrite(
                        body: Data(#"{"qty":9999}"#.utf8),
                        headers: ["X-Debug": "1"],
                        removedHeaders: ["Authorization"],
                        method: "PUT"
                    )
                )
            ]
        )

        let decoded = try JSONDecoder().decode(
            MockRule.self, from: JSONEncoder().encode(rule)
        )
        let rewrite = try XCTUnwrap(decoded.steps.first?.rewrite)

        XCTAssertEqual(rewrite.method, "PUT")
        XCTAssertEqual(rewrite.headers, ["X-Debug": "1"])
        XCTAssertEqual(rewrite.removedHeaders, ["Authorization"])
        XCTAssertEqual(decoded.steps.first?.label, "rewrite body, PUT, 2 headers")
    }
}
