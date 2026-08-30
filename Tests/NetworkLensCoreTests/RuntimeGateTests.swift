//
//  RuntimeGateTests.swift
//  NetworkLensCoreTests
//
//  Created by Rohit Sahay on 28/08/26.
//

import XCTest
@testable import NetworkLensCore

/// The gate that lets the tool ship in an App Store binary and stay dormant.
///
/// The failures worth catching are the ones that would make "off" a lie: a
/// disabled start that still writes a trace, still restores rules, or still
/// claims a request at `canInit`.
final class RuntimeGateTests: XCTestCase {

    private var traceURL: URL!

    override func setUp() {
        super.setUp()
        traceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gate-\(UUID().uuidString).ndjson")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: traceURL)
        NetworkLens.start(configuration: LensConfiguration())
        super.tearDown()
    }

    func testEnabledByDefault() {
        NetworkLens.start(configuration: LensConfiguration())
        XCTAssertTrue(NetworkLens.isEnabled)
    }

    func testDisabledStartReportsItself() {
        NetworkLens.start(configuration: LensConfiguration(isEnabled: false))
        XCTAssertFalse(NetworkLens.isEnabled)
    }

    /// The one that matters for a shipped build: nothing on disk.
    func testDisabledStartWritesNoTrace() throws {
        NetworkLens.start(
            configuration: LensConfiguration(isEnabled: false, trace: TraceOptions(url: traceURL))
        )

        XCTAssertNil(NetworkLens.traceURL)
        NetworkLens.store.record(Self.exchange())
        XCTAssertFalse(FileManager.default.fileExists(atPath: traceURL.path))
    }

    func testEnabledStartStillWritesTheTrace() throws {
        NetworkLens.start(
            configuration: LensConfiguration(isEnabled: true, trace: TraceOptions(url: traceURL))
        )

        XCTAssertEqual(NetworkLens.traceURL, traceURL)
    }

    /// A disabled lens must not claim requests. `canInit` returning true would
    /// put the whole interception path back on the wire with the gate shut.
    func testDisabledLensDoesNotClaimRequests() throws {
        NetworkLens.start(configuration: LensConfiguration(isEnabled: false))

        let url = try XCTUnwrap(URL(string: "https://bwa-qa2-gcp.gdn-app.com/backend/cart"))
        XCTAssertFalse(LensURLProtocol.canInit(with: URLRequest(url: url)))
    }

    func testEnabledLensClaimsRequests() throws {
        NetworkLens.start(configuration: LensConfiguration())

        let url = try XCTUnwrap(URL(string: "https://bwa-qa2-gcp.gdn-app.com/backend/cart"))
        XCTAssertTrue(LensURLProtocol.canInit(with: URLRequest(url: url)))
    }

    /// Re-enabling is a second `start()`, which is how a host app that resolves
    /// its flag late is meant to turn the lens on — accepting that it has
    /// already missed whatever went out before.
    func testStartCanReopenTheGate() {
        NetworkLens.start(configuration: LensConfiguration(isEnabled: false))
        XCTAssertFalse(NetworkLens.isEnabled)

        NetworkLens.start(configuration: LensConfiguration(isEnabled: true))
        XCTAssertTrue(NetworkLens.isEnabled)
    }

    private static func exchange() -> NetworkExchange {
        guard let url = URL(string: "https://bwa-qa2-gcp.gdn-app.com/backend/cart") else {
            fatalError("static test URL")
        }
        return NetworkExchange(
            endpointKey: "GET /backend/cart",
            request: RequestSnapshot(method: "GET", url: url, headers: [:], body: nil)
        )
    }
}
