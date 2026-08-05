//
//  IntegrationSurfaceTests.swift
//  NetworkLensCoreTests
//
//  Created by Rohit Sahay on 31/07/26.
//

import XCTest
@testable import NetworkLensCore

/// What a host app's networking module touches.
///
/// In most teams that module ships to production and must not depend on a
/// debugging tool, so everything here has to work through API it already uses:
/// a `URLSessionConfiguration`, and a header on a request.
final class IntegrationSurfaceTests: XCTestCase {

    private var session: URLSession!

    override func setUp() {
        super.setUp()
        NetworkLens.start(configuration: LensConfiguration(maxStoredExchanges: 50))
        NetworkLens.store.removeAll()
        Mocks.shared.removeAll()

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

    // MARK: - Header attribution

    /// A networking module that cannot import the lens still gets attribution.
    func testScreenHeaderAttributesTheExchange() async throws {
        Mocks.shared.set(MockRule(endpointKey: "GET /cart", response: .json("{}")))

        var request = URLRequest(url: url("/cart"))
        request.setValue("Checkout", forHTTPHeaderField: LensHeaders.screen)
        _ = try await session.data(for: request)

        let recorded = try XCTUnwrap(
            NetworkLens.store.exchanges.first { $0.endpointKey == "GET /cart" }
        )
        XCTAssertEqual(recorded.screen, "Checkout")
    }

    /// The header is the tool's own and must never reach a server — nor a
    /// capture, nor a curl command, or the export would not reproduce.
    func testScreenHeaderIsStrippedFromWhatIsSentAndCaptured() async throws {
        Mocks.shared.set(MockRule(endpointKey: "GET /cart", response: .json("{}")))

        var request = URLRequest(url: url("/cart"))
        request.setValue("Checkout", forHTTPHeaderField: LensHeaders.screen)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        _ = try await session.data(for: request)

        let recorded = try XCTUnwrap(
            NetworkLens.store.exchanges.first { $0.endpointKey == "GET /cart" }
        )
        XCTAssertNil(recorded.request.headers[LensHeaders.screen])
        XCTAssertEqual(recorded.request.headers["Accept"], "application/json")
        XCTAssertFalse(CurlExport.command(for: recorded).contains(LensHeaders.screen))
    }

    /// The explicit tag wins: a caller that named a screen per request meant it.
    func testTaggedPropertyIsUsedWhenNoHeaderIsPresent() async throws {
        Mocks.shared.set(MockRule(endpointKey: "GET /orders", response: .json("{}")))

        let tagged = NetworkLens.tagged(URLRequest(url: url("/orders")), screen: "Orders")
        _ = try await session.data(for: tagged)

        let recorded = NetworkLens.store.exchanges.first { $0.endpointKey == "GET /orders" }
        XCTAssertEqual(recorded?.screen, "Orders")
    }

    // MARK: - Configurations

    func testDefaultAndEphemeralConfigurationsAreInterceptable() {
        XCTAssertTrue(NetworkLens.canIntercept(.default))
        XCTAssertTrue(NetworkLens.canIntercept(.ephemeral))
        XCTAssertTrue(NetworkLens.install(into: URLSessionConfiguration.ephemeral))
    }

    /// Background transfers run in another process, where a custom
    /// `URLProtocol` is never consulted. Installing silently would look like
    /// the tool was broken.
    func testBackgroundConfigurationIsRejectedAndReported() {
        let background = URLSessionConfiguration.background(withIdentifier: "test.background")

        XCTAssertFalse(NetworkLens.canIntercept(background))
        XCTAssertFalse(NetworkLens.install(into: background))
        XCTAssertNil(
            background.protocolClasses?.first { $0 == LensURLProtocol.self },
            "a protocol that will never be consulted must not be installed"
        )
        XCTAssertTrue(
            NetworkLens.uninterceptable.contains { $0.contains("background") },
            "the tester needs to be told, not left wondering where the traffic went"
        )
    }

    /// The swizzle hooks the *getter*, so a configuration obtained after
    /// `start()` carries the protocol with no work from the host at all. This
    /// is what makes a networking module in another package interceptable
    /// without touching it.
    func testConfigurationBuiltAfterStartIsInterceptedWithoutInstalling() async throws {
        Mocks.shared.set(MockRule(endpointKey: "GET /auto", response: .json(#"{"ok":true}"#)))

        // Exactly what a networking module writes, with no knowledge of the lens.
        let moduleSession = URLSession(configuration: .default)
        let (data, _) = try await moduleSession.data(from: url("/auto"))

        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"ok":true}"#)
        XCTAssertNotNil(
            NetworkLens.store.exchanges.first { $0.endpointKey == "GET /auto" },
            "a session built from .default after start() must be captured"
        )
    }

    func testInstallingTwiceDoesNotStackTheProtocol() {
        let configuration = URLSessionConfiguration.ephemeral
        NetworkLens.install(into: configuration)
        NetworkLens.install(into: configuration)

        let installed = configuration.protocolClasses?.filter { $0 == LensURLProtocol.self }
        XCTAssertEqual(installed?.count, 1)
    }

    /// A module with its own protocol classes must keep them, and the lens has
    /// to be consulted first or the system protocol claims the request.
    func testExistingProtocolClassesArePreservedAndTheLensGoesFirst() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OtherProtocol.self]

        NetworkLens.install(into: configuration)

        XCTAssertTrue(configuration.protocolClasses?.first == LensURLProtocol.self)
        XCTAssertTrue(configuration.protocolClasses?.contains { $0 == OtherProtocol.self } ?? false)
    }
}

private final class OtherProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { false }
}
