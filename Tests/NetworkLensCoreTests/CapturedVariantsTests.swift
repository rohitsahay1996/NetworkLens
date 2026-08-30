//
//  CapturedVariantsTests.swift
//  NetworkLensCoreTests
//
//  Created by Rohit Sahay on 28/08/26.
//

import XCTest
@testable import NetworkLensCore

/// Derivation is only useful if the derived body still decodes in the app. A
/// variant the app cannot parse exercises the error path while claiming to be
/// the empty state, which is worse than having no variant at all.
final class CapturedVariantsTests: XCTestCase {

    private let envelope = Data(#"{"code":200,"status":"OK","data":{"items":[{"id":"1"}],"total":1}}"#.utf8)

    private func json(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    // MARK: - Empty

    /// The envelope has to survive, or the app fails to decode and shows an
    /// error instead of the empty state.
    func testEmptiedKeepsTheEnvelopeAndDropsThePayload() {
        let result = json(CapturedVariants.emptied(envelope))

        XCTAssertEqual(result["code"] as? Int, 200)
        XCTAssertEqual(result["status"] as? String, "OK")
        let data = result["data"] as? [String: Any]
        XCTAssertEqual((data?["items"] as? [Any])?.count, 0)
        XCTAssertEqual(data?["total"] as? Int, 1)
    }

    func testEmptiedTurnsATopLevelArrayIntoAnEmptyOne() {
        let result = CapturedVariants.emptied(Data(#"[{"id":"1"},{"id":"2"}]"#.utf8))
        XCTAssertEqual(String(data: result, encoding: .utf8), "[]")
    }

    func testEmptiedFallsBackForABodyItCannotRead() {
        XCTAssertEqual(String(data: CapturedVariants.emptied(Data("not json".utf8)), encoding: .utf8), "{}")
    }

    // MARK: - Failure

    /// A generic error body would be parsed by the decoder, not by the error
    /// path, so the mocked 500 would test the wrong branch.
    func testFailedRewritesTheAppsOwnEnvelope() {
        let result = json(CapturedVariants.failed(envelope))

        XCTAssertEqual(result["code"] as? Int, 500)
        XCTAssertEqual(result["status"] as? String, "INTERNAL_SERVER_ERROR")
        XCTAssertTrue(result["data"] is NSNull)
        XCTAssertEqual(result["errorCode"] as? String, "SYSTEM_ERROR")
    }

    func testFailedLeavesAnUnrecognisedBodyAlone() {
        let result = json(CapturedVariants.failed(Data(#"[1,2,3]"#.utf8)))
        XCTAssertEqual(result["error"] as? String, "internal server error")
    }

    // MARK: - The set

    func testStandardSetCoversTheStatesWorthTesting() {
        let response = ResponseSnapshot(statusCode: 200, headers: ["Content-Type": "application/json"], body: envelope)
        let variants = CapturedVariants.standardSet(from: response)

        XCTAssertEqual(variants.map(\.name), ["loaded", "empty", "500", "slow", "timeout"])
    }

    func testLoadedIsTheCaptureVerbatim() throws {
        let response = ResponseSnapshot(statusCode: 201, headers: [:], body: envelope)
        let loaded = try XCTUnwrap(CapturedVariants.standardSet(from: response).first)

        XCTAssertEqual(loaded.steps.first?.response?.statusCode, 201)
        XCTAssertEqual(loaded.steps.first?.response?.body, envelope)
        XCTAssertEqual(loaded.steps.first?.response?.delay, 0)
    }

    func testSlowKeepsTheBodyAndAddsTheDelay() throws {
        let response = ResponseSnapshot(statusCode: 200, headers: [:], body: envelope)
        let slow = try XCTUnwrap(CapturedVariants.standardSet(from: response, slowDelay: 4).first { $0.name == "slow" })

        XCTAssertEqual(slow.steps.first?.response?.delay, 4)
        XCTAssertEqual(slow.steps.first?.response?.body, envelope)
    }

    func testTimeoutIsATransportFailureNotAStatusCode() throws {
        let response = ResponseSnapshot(statusCode: 200, headers: [:], body: envelope)
        let timeout = try XCTUnwrap(CapturedVariants.standardSet(from: response).first { $0.name == "timeout" })

        XCTAssertNil(timeout.steps.first?.response)
        XCTAssertEqual(timeout.steps.first?.failure?.errorCode, URLError.timedOut.rawValue)
    }

    /// Rules arrive off, so generating them for a screen does not change what
    /// the app is being served until someone asks for it.
    func testGeneratedRuleStartsDisabled() {
        let exchange = NetworkExchange(
            endpointKey: "GET /cart",
            request: RequestSnapshot(method: "GET", url: URL(fileURLWithPath: "/cart")),
            response: ResponseSnapshot(statusCode: 200, headers: [:], body: envelope)
        )

        let rule = CapturedVariants.rule(for: exchange)

        XCTAssertFalse(rule.isEnabled)
        XCTAssertEqual(rule.endpointKey, "GET /cart")
        XCTAssertEqual(rule.variants.count, 5)
    }
}
