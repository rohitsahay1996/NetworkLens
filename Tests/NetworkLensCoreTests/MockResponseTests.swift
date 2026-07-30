import XCTest
@testable import NetworkLensCore

final class MockResponseTests: XCTestCase {

    private let url = URL(string: "https://api.test/users/1")!

    // MARK: - Builders

    func testJSONStringBuilderSetsContentType() {
        let mock = MockResponse.json(#"{"id":1}"#)

        XCTAssertEqual(mock.statusCode, 200)
        XCTAssertEqual(mock.headers["Content-Type"], "application/json")
        XCTAssertEqual(String(data: mock.body, encoding: .utf8), #"{"id":1}"#)
    }

    func testJSONBuilderDoesNotOverrideAnExplicitContentTypeInAnyCase() {
        let mock = MockResponse.json(
            "{}", headers: ["content-type": "application/vnd.api+json"]
        )

        XCTAssertEqual(mock.headers["content-type"], "application/vnd.api+json")
        XCTAssertNil(mock.headers["Content-Type"])
    }

    func testJSONNodeBuilderPreservesKeyOrderAndNumberLiterals() throws {
        let node = try JSONNodeParser.parse(Data(#"{"z":1,"a":1.50}"#.utf8))
        let mock = MockResponse.json(node)

        XCTAssertEqual(String(data: mock.body, encoding: .utf8), #"{"z":1,"a":1.50}"#)
    }

    func testStatusBuilderHasEmptyBody() {
        let mock = MockResponse.status(204)

        XCTAssertEqual(mock.statusCode, 204)
        XCTAssertTrue(mock.body.isEmpty)
    }

    // MARK: - Payload

    func testPayloadCarriesStatusHeadersAndBody() {
        let mock = MockResponse(
            statusCode: 503,
            headers: ["Retry-After": "30"],
            body: Data("busy".utf8)
        )

        let payload = mock.payload(for: url)

        XCTAssertEqual(payload.response.statusCode, 503)
        XCTAssertEqual(payload.response.value(forHTTPHeaderField: "Retry-After"), "30")
        XCTAssertEqual(payload.response.url, url)
        XCTAssertEqual(payload.body, Data("busy".utf8))
        XCTAssertFalse(payload.bodyTruncated)
    }

    func testPayloadRecomputesContentLength() {
        let mock = MockResponse(
            headers: ["Content-Length": "99999"],
            body: Data("1234".utf8)
        )

        let payload = mock.payload(for: url)

        XCTAssertEqual(payload.response.value(forHTTPHeaderField: "Content-Length"), "4")
    }

    /// A hand-written `content-length` in the other case would otherwise survive
    /// alongside the recomputed one and be the value URLSession honours.
    func testPayloadRecomputesLowercaseContentLength() {
        let mock = MockResponse(
            headers: ["content-length": "99999"],
            body: Data("1234".utf8)
        )

        let payload = mock.payload(for: url)

        XCTAssertEqual(payload.response.value(forHTTPHeaderField: "Content-Length"), "4")
        XCTAssertEqual(payload.response.expectedContentLength, 4)
    }

    func testPayloadTimingReportsMeasuredElapsedOverDeclaredDelay() {
        let mock = MockResponse(delay: 5)

        XCTAssertEqual(mock.payload(for: url, elapsed: 0.25).timing?.total, 0.25)
        XCTAssertEqual(mock.payload(for: url).timing?.total, 5)
    }

    func testPayloadTimingLeavesTransportPhasesNil() {
        let timing = MockResponse.status(200).payload(for: url).timing

        XCTAssertEqual(timing?.total, 0)
        XCTAssertNil(timing?.domainLookup)
        XCTAssertNil(timing?.connect)
        XCTAssertNil(timing?.tls)
        XCTAssertEqual(timing?.fromCache, false)
    }

    // MARK: - Codable

    func testRuleRoundTripsThroughCodable() throws {
        let rule = MockRule(
            endpointKey: "GET /users/{id}",
            response: .json(#"{"id":1}"#, statusCode: 201, delay: 1.5),
            isEnabled: false,
            name: "created"
        )

        let data = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(MockRule.self, from: data)

        XCTAssertEqual(decoded, rule)
    }
}
