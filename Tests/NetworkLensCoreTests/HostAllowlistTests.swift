//
//  HostAllowlistTests.swift
//  NetworkLensCoreTests
//
//  Created by Rohit Sahay on 27/08/26.
//

import XCTest
@testable import NetworkLensCore

/// The allowlist decides what the tool can see at all, so the interesting cases
/// are the two ways it can be wrong: silently capturing nothing because a
/// pattern did not match, and silently capturing everything because an empty
/// list was read as a filter.
final class HostAllowlistTests: XCTestCase {

    private let allowed = ["bwa-qa2-gcp.gdn-app.com", "wwwuatb.gdn-app.com"]

    override func tearDown() {
        NetworkLens.start(configuration: LensConfiguration())
        super.tearDown()
    }

    private func request(_ urlString: String) -> URLRequest {
        guard let url = URL(string: urlString) else {
            XCTFail("malformed test URL \(urlString)")
            return URLRequest(url: URL(fileURLWithPath: "/"))
        }
        return URLRequest(url: url)
    }

    // MARK: - Matching

    func testEmptyListCapturesEverything() {
        let configuration = LensConfiguration()
        XCTAssertTrue(configuration.capturesHost("bwa-qa2-gcp.gdn-app.com"))
        XCTAssertTrue(configuration.capturesHost("firebaselogging-pa.googleapis.com"))
        XCTAssertTrue(configuration.capturesHost(nil))
    }

    func testListedHostsAreCapturedAndOthersAreNot() {
        let configuration = LensConfiguration(capturedHostPatterns: allowed)
        XCTAssertTrue(configuration.capturesHost("bwa-qa2-gcp.gdn-app.com"))
        XCTAssertTrue(configuration.capturesHost("wwwuatb.gdn-app.com"))
        XCTAssertFalse(configuration.capturesHost("static-uatb.gdn-app.com"))
        XCTAssertFalse(configuration.capturesHost("sdk-01.moengage.com"))
        XCTAssertFalse(configuration.capturesHost("ep2.facebook.com"))
    }

    /// A sibling subdomain must not ride in on a shared parent domain — the
    /// image CDN this list exists to exclude is one label away from the API
    /// host it keeps.
    func testSiblingSubdomainOfAListedHostIsNotCaptured() {
        let configuration = LensConfiguration(capturedHostPatterns: ["wwwuatb.gdn-app.com"])
        XCTAssertFalse(configuration.capturesHost("gdn-app.com"))
        XCTAssertFalse(configuration.capturesHost("static-uatb.gdn-app.com"))
    }

    func testParentDomainPatternCoversItsSubdomains() {
        let configuration = LensConfiguration(capturedHostPatterns: ["gdn-app.com"])
        XCTAssertTrue(configuration.capturesHost("gdn-app.com"))
        XCTAssertTrue(configuration.capturesHost("bwa-qa2-gcp.gdn-app.com"))
        XCTAssertTrue(configuration.capturesHost("static-uatb.gdn-app.com"))
    }

    func testWildcardPrefixAndCaseAreNormalised() {
        let configuration = LensConfiguration(capturedHostPatterns: ["*.GDN-App.com"])
        XCTAssertTrue(configuration.capturesHost("BWA-QA2-GCP.gdn-app.com"))
        XCTAssertTrue(configuration.capturesHost("gdn-app.com"))
    }

    /// The one place this deliberately disagrees with `isProductionHost`: an
    /// unknown host is safe to let through a production guard and is not safe
    /// to let through a filter someone set to see less.
    func testNilHostIsNotCapturedOnceAListIsSet() {
        let configuration = LensConfiguration(capturedHostPatterns: allowed)
        XCTAssertFalse(configuration.capturesHost(nil))
        XCTAssertFalse(configuration.capturesHost(""))
    }

    func testEmptyPatternDoesNotMatchEveryHost() {
        let configuration = LensConfiguration(capturedHostPatterns: [""])
        XCTAssertFalse(configuration.capturesHost("bwa-qa2-gcp.gdn-app.com"))
    }

    func testProductionHostListIsUnaffectedByTheCaptureList() {
        let configuration = LensConfiguration(
            capturedHostPatterns: ["wwwuatb.gdn-app.com"],
            productionHostPatterns: ["api.acme.com"]
        )
        XCTAssertTrue(configuration.isProductionHost("api.acme.com"))
        XCTAssertFalse(configuration.isProductionHost("wwwuatb.gdn-app.com"))
        XCTAssertFalse(configuration.capturesHost("api.acme.com"))
    }

    // MARK: - Interception

    func testCanInitRefusesHostsOutsideTheList() {
        NetworkLens.start(configuration: LensConfiguration(capturedHostPatterns: allowed))

        XCTAssertTrue(LensURLProtocol.canInit(with: request("https://wwwuatb.gdn-app.com/backend/x")))
        XCTAssertFalse(LensURLProtocol.canInit(with: request("https://static-uatb.gdn-app.com/siva/asset/a.png")))
        XCTAssertFalse(LensURLProtocol.canInit(with: request("https://ep2.facebook.com/v17.0/x")))
    }

    func testCanInitStillAcceptsEveryHostWithoutAList() {
        NetworkLens.start(configuration: LensConfiguration())

        XCTAssertTrue(LensURLProtocol.canInit(with: request("https://ep2.facebook.com/v17.0/x")))
        XCTAssertTrue(LensURLProtocol.canInit(with: request("https://wwwuatb.gdn-app.com/backend/x")))
    }

    /// The allowlist must not become a way to intercept a scheme the lens never
    /// handled, so the scheme guard has to survive in front of it.
    func testNonHTTPSchemesStayRefusedRegardlessOfTheList() {
        NetworkLens.start(configuration: LensConfiguration(capturedHostPatterns: ["gdn-app.com"]))

        XCTAssertFalse(LensURLProtocol.canInit(with: request("ws://wwwuatb.gdn-app.com/socket")))
        XCTAssertFalse(LensURLProtocol.canInit(with: request("file:///tmp/x.json")))
    }

    // MARK: - End to end

    /// The default is the one that has to be right, because it is the one every
    /// existing host gets without asking: with no list, an arbitrary host the
    /// caller never named still reaches the store.
    func testWithNoListAnUnnamedHostIsStillRecorded() async throws {
        let session = interceptingSession(capturing: [])
        defer { teardown(session) }
        Mocks.shared.set(MockRule(endpointKey: "GET /anything", response: .json("{}")))

        _ = try await session.data(from: XCTUnwrap(URL(string: "https://vendor.invalid/anything")))

        XCTAssertEqual(NetworkLens.store.exchanges.count, 1)
        XCTAssertEqual(NetworkLens.store.exchanges.first?.request.url.host, "vendor.invalid")
    }

    func testWithAListOnlyTheListedHostIsRecorded() async throws {
        let session = interceptingSession(capturing: ["listed.invalid"])
        defer { teardown(session) }
        Mocks.shared.set(MockRule(endpointKey: "GET /anything", response: .json("{}")))

        _ = try await session.data(from: XCTUnwrap(URL(string: "https://listed.invalid/anything")))

        // Never intercepted, so the mock cannot claim it and the unresolvable
        // host is what answers — which is the point: the lens is not in the way.
        let excluded = try XCTUnwrap(URL(string: "https://vendor.invalid/anything"))
        do {
            _ = try await session.data(from: excluded)
            XCTFail("an excluded host must reach the real network, not the mocking engine")
        } catch {
            // Expected: `.invalid` cannot resolve.
        }

        XCTAssertEqual(NetworkLens.store.exchanges.count, 1)
        XCTAssertEqual(NetworkLens.store.exchanges.first?.request.url.host, "listed.invalid")
    }

    private func interceptingSession(capturing patterns: [String]) -> URLSession {
        NetworkLens.start(
            configuration: LensConfiguration(
                maxStoredExchanges: 50, capturedHostPatterns: patterns
            )
        )
        NetworkLens.store.removeAll()
        Mocks.shared.removeAll()
        Breakpoints.shared.removeAll()

        let configuration = URLSessionConfiguration.ephemeral
        NetworkLens.install(into: configuration)
        return URLSession(configuration: configuration)
    }

    private func teardown(_ session: URLSession) {
        Mocks.shared.removeAll()
        NetworkLens.store.removeAll()
        session.invalidateAndCancel()
    }
}
