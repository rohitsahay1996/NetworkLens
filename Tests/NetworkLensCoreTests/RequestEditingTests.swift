//
//  RequestEditingTests.swift
//  NetworkLensCoreTests
//
//  Created by Rohit Sahay on 30/07/26.
//

import XCTest
@testable import NetworkLensCore

final class RequestEditingTests: XCTestCase {

    private func request(body: String? = nil, contentType: String? = nil) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.test/pay?page=2")!)
        request.httpMethod = "POST"
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if let body {
            let data = Data(body.utf8)
            request.httpBody = data
            request.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
        }
        return request
    }

    // MARK: - Content-Length

    func testEditingJSONBodyRecomputesContentLength() throws {
        let original = request(body: #"{"stock":12}"#, contentType: "application/json")
        XCTAssertEqual(original.value(forHTTPHeaderField: "Content-Length"), "12")

        let tree = try JSONNodeParser.parse(original.httpBody!)
        let edited = try tree.applying(PatchOp(kind: .replace, path: "/stock", value: .number("0")))
        let result = original.replacingJSONBody(edited)

        XCTAssertEqual(String(data: result.httpBody!, encoding: .utf8), #"{"stock":0}"#)
        XCTAssertEqual(result.value(forHTTPHeaderField: "Content-Length"), "11")
    }

    func testGrowingBodyRecomputesContentLength() throws {
        let original = request(body: #"{"a":1}"#, contentType: "application/json")
        let tree = try JSONNodeParser.parse(original.httpBody!)
        let edited = try tree.applying(
            PatchOp(kind: .add, path: "/note", value: .string("a much longer value"))
        )
        let result = original.replacingJSONBody(edited)

        XCTAssertEqual(
            result.value(forHTTPHeaderField: "Content-Length"),
            "\(result.httpBody!.count)"
        )
        XCTAssertGreaterThan(result.httpBody!.count, original.httpBody!.count)
    }

    func testClearingBodyClearsContentLength() {
        let result = request(body: #"{"a":1}"#).replacingBody(nil)
        XCTAssertNil(result.httpBody)
        XCTAssertNil(result.value(forHTTPHeaderField: "Content-Length"))
    }

    func testEditingClearsStreamBody() {
        var original = request()
        original.httpBodyStream = InputStream(data: Data("multipart".utf8))
        let result = original.replacingBody(Data("edited".utf8))

        // A consumed stream cannot be re-sent, and a stream body cannot coexist
        // with a data body.
        XCTAssertNil(result.httpBodyStream)
        XCTAssertEqual(String(data: result.httpBody!, encoding: .utf8), "edited")
        XCTAssertEqual(result.value(forHTTPHeaderField: "Content-Length"), "6")
    }

    func testEditPreservesUnrelatedNodesExactly() throws {
        let json = #"{"z":1.0,"stock":12,"big":9007199254740993,"m":1e-7}"#
        let original = request(body: json, contentType: "application/json")
        let tree = try JSONNodeParser.parse(original.httpBody!)
        let edited = try tree.applying(PatchOp(kind: .replace, path: "/stock", value: .number("0")))

        XCTAssertEqual(
            String(data: original.replacingJSONBody(edited).httpBody!, encoding: .utf8),
            #"{"z":1.0,"stock":0,"big":9007199254740993,"m":1e-7}"#
        )
    }

    // MARK: - Query and headers

    func testReplacingQueryItem() {
        let result = request().replacingQueryItem(name: "page", value: "7")
        XCTAssertEqual(result.url?.query, "page=7")
    }

    func testAddingQueryItem() {
        let result = request().replacingQueryItem(name: "debug", value: "1")
        XCTAssertEqual(result.queryItems.map(\.name).sorted(), ["debug", "page"])
    }

    func testRemovingOnlyQueryItemClearsQueryString() {
        let result = request().replacingQueryItem(name: "page", value: nil)
        XCTAssertNil(result.url?.query)
    }

    func testReplacingHeader() {
        let result = request().replacingHeader(name: "X-Debug", value: "yes")
        XCTAssertEqual(result.value(forHTTPHeaderField: "X-Debug"), "yes")
    }

    // MARK: - Body classification

    func testJSONBodyIsEditable() {
        XCTAssertTrue(request(body: #"{"a":1}"#, contentType: "application/json").bodyIsEditableAsJSON)
    }

    func testBinaryBodyIsNotEditableAndDoesNotCrashTheParser() {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xFF, 0x00])
        let presentation = bytes.bodyPresentation(contentType: "image/png")

        guard case .binary(let count, let preview) = presentation else {
            return XCTFail("expected binary, got \(presentation)")
        }
        XCTAssertEqual(count, 10)
        XCTAssertTrue(preview.hasPrefix("89 50 4e 47"))
        XCTAssertFalse(presentation.isEditable)
    }

    func testHTMLBodyIsTextNotJSON() {
        let presentation = Data("<html><body>hi</body></html>".utf8)
            .bodyPresentation(contentType: "text/html")
        guard case .text = presentation else {
            return XCTFail("expected text, got \(presentation)")
        }
        XCTAssertFalse(presentation.isEditable)
    }

    func testProtobufLikeBodyIsBinary() {
        let bytes = Data([0x08, 0x96, 0x01, 0x12, 0x04, 0xFE, 0xFF, 0x00, 0x01])
        guard case .binary = bytes.bodyPresentation(contentType: "application/x-protobuf") else {
            return XCTFail("expected binary")
        }
    }

    func testEmptyBodyIsEmpty() {
        XCTAssertEqual(Data().bodyPresentation(), .empty)
    }

    func testJSONWinsOverContentType() {
        // Servers mislabel JSON as text/plain constantly. Sniff, do not trust.
        XCTAssertEqual(
            Data(#"{"a":1}"#.utf8).bodyPresentation(contentType: "text/plain"),
            .json
        )
    }
}

final class ProductionHostTests: XCTestCase {

    private let configuration = LensConfiguration(
        productionHostPatterns: ["api.acme.com", "*.payments.acme.com", "acme.io"]
    )

    func testExactHostMatches() {
        XCTAssertTrue(configuration.isProductionHost("api.acme.com"))
        XCTAssertTrue(configuration.isProductionHost("acme.io"))
    }

    func testSubdomainMatches() {
        XCTAssertTrue(configuration.isProductionHost("eu.api.acme.com"))
        XCTAssertTrue(configuration.isProductionHost("live.payments.acme.com"))
        XCTAssertTrue(configuration.isProductionHost("a.b.acme.io"))
    }

    func testLeadingWildcardIsAccepted() {
        XCTAssertTrue(configuration.isProductionHost("payments.acme.com"))
    }

    func testCaseInsensitive() {
        XCTAssertTrue(configuration.isProductionHost("API.Acme.COM"))
    }

    func testNonProductionHostsAreAllowed() {
        XCTAssertFalse(configuration.isProductionHost("staging.acme.com"))
        XCTAssertFalse(configuration.isProductionHost("localhost"))
        XCTAssertFalse(configuration.isProductionHost("api.acme.com.evil.test"))
        XCTAssertFalse(configuration.isProductionHost("notacme.io"))
    }

    func testNilAndEmptyHostAreNotProduction() {
        XCTAssertFalse(configuration.isProductionHost(nil))
        XCTAssertFalse(configuration.isProductionHost(""))
    }

    func testEmptyPatternListBlocksNothing() {
        XCTAssertFalse(LensConfiguration().isProductionHost("api.acme.com"))
    }

    /// The hard requirement: a request breakpoint must refuse to arm against a
    /// production host, while a response breakpoint still works.
    func testRequestBreakpointRefusesToArmOnProductionHost() {
        NetworkLens.start(configuration: configuration)
        let breakpoints = Breakpoints.shared
        breakpoints.removeAll()
        breakpoints.setRequestEditingEnabled(true)

        var production = URLRequest(url: URL(string: "https://api.acme.com/users/1")!)
        production.httpMethod = "GET"
        var staging = URLRequest(url: URL(string: "https://staging.acme.com/users/1")!)
        staging.httpMethod = "GET"

        breakpoints.set(Breakpoint(endpointKey: "GET /users/{id}", stage: .both))

        XCTAssertFalse(breakpoints.shouldPauseRequest(for: production))
        XCTAssertTrue(breakpoints.shouldPauseResponse(for: production),
                      "response breakpoints never reach the backend, so they stay available")
        XCTAssertTrue(breakpoints.shouldPauseRequest(for: staging))

        breakpoints.removeAll()
        breakpoints.setRequestEditingEnabled(false)
    }

    func testRequestBreakpointRefusesWhenRequestEditingIsOff() {
        NetworkLens.start(configuration: LensConfiguration())
        let breakpoints = Breakpoints.shared
        breakpoints.removeAll()
        breakpoints.setRequestEditingEnabled(false)
        breakpoints.set(Breakpoint(endpointKey: "GET /users/{id}", stage: .both))

        var request = URLRequest(url: URL(string: "https://staging.acme.com/users/1")!)
        request.httpMethod = "GET"

        XCTAssertFalse(breakpoints.shouldPauseRequest(for: request), "off by default")
        XCTAssertTrue(breakpoints.shouldPauseResponse(for: request))

        breakpoints.removeAll()
    }

    func testSkipForSessionSuppressesBothStages() {
        NetworkLens.start(configuration: LensConfiguration())
        let breakpoints = Breakpoints.shared
        breakpoints.removeAll()
        breakpoints.set(Breakpoint(endpointKey: "GET /users/{id}", stage: .both))

        var request = URLRequest(url: URL(string: "https://staging.acme.com/users/1")!)
        request.httpMethod = "GET"
        XCTAssertTrue(breakpoints.shouldPauseResponse(for: request))

        breakpoints.skipForSession(endpointKey: "GET /users/{id}")
        XCTAssertFalse(breakpoints.shouldPauseResponse(for: request))
        XCTAssertFalse(breakpoints.shouldPauseRequest(for: request))

        breakpoints.removeAll()
    }

    func testOneShotDisablesAfterHit() {
        let breakpoints = Breakpoints.shared
        breakpoints.removeAll()
        breakpoints.set(Breakpoint(endpointKey: "GET /x", stage: .response, oneShot: true))

        XCTAssertNotNil(breakpoints.breakpoint(forEndpointKey: "GET /x"))
        breakpoints.didHit(endpointKey: "GET /x")
        XCTAssertNil(breakpoints.breakpoint(forEndpointKey: "GET /x"))

        breakpoints.removeAll()
    }
}
