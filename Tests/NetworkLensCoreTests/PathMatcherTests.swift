//
//  PathMatcherTests.swift
//  NetworkLensCoreTests
//
//  Created by Rohit Sahay on 29/07/26.
//

import XCTest
@testable import NetworkLensCore

final class PathMatcherTests: XCTestCase {

    private let matcher = PathMatcher()

    private func key(_ method: String, _ urlString: String) -> String? {
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = method
        return matcher.endpointKey(for: request)
    }

    func testNumericIdIsTemplated() {
        XCTAssertEqual(key("GET", "https://api.test/users/123"), "GET /users/{id}")
    }

    func testMultipleNumericIdsAreTemplatedIndependently() {
        XCTAssertEqual(
            key("GET", "https://api.test/users/123/orders/456"),
            "GET /users/{id}/orders/{id}"
        )
    }

    func testUUIDIsTemplated() {
        XCTAssertEqual(
            key("GET", "https://api.test/carts/3F2504E0-4F89-11D3-9A0C-0305E82C3301"),
            "GET /carts/{id}"
        )
    }

    func testLowercaseUUIDIsTemplated() {
        XCTAssertEqual(
            key("DELETE", "https://api.test/carts/3f2504e0-4f89-11d3-9a0c-0305e82c3301"),
            "DELETE /carts/{id}"
        )
    }

    func testLongHexIdIsTemplated() {
        XCTAssertEqual(
            key("GET", "https://api.test/docs/507f1f77bcf86cd799439011"),
            "GET /docs/{id}"
        )
    }

    func testShortHexLikeWordsAreNotTemplated() {
        XCTAssertEqual(key("GET", "https://api.test/cafe/feed"), "GET /cafe/feed")
    }

    func testTrailingSlashIsNormalised() {
        XCTAssertEqual(key("GET", "https://api.test/users/123/"), "GET /users/{id}")
        XCTAssertEqual(key("GET", "https://api.test/users/"), "GET /users")
    }

    func testDuplicateSlashesCollapse() {
        XCTAssertEqual(key("GET", "https://api.test/users//123"), "GET /users/{id}")
    }

    func testQueryStringIsExcludedFromKey() {
        XCTAssertEqual(
            key("GET", "https://api.test/users/123?expand=orders&page=2"),
            "GET /users/{id}"
        )
    }

    func testNumericQueryValueDoesNotLeakIntoKey() {
        XCTAssertEqual(key("GET", "https://api.test/search?id=99"), "GET /search")
    }

    func testRootPath() {
        XCTAssertEqual(key("GET", "https://api.test/"), "GET /")
        XCTAssertEqual(key("GET", "https://api.test"), "GET /")
    }

    func testMethodIsUppercased() {
        XCTAssertEqual(key("post", "https://api.test/users"), "POST /users")
    }

    func testMissingMethodDefaultsToGET() {
        let request = URLRequest(url: URL(string: "https://api.test/users")!)
        XCTAssertEqual(matcher.endpointKey(for: request), "GET /users")
    }

    func testCustomPlaceholder() {
        let matcher = PathMatcher(placeholder: ":id")
        var request = URLRequest(url: URL(string: "https://api.test/users/7")!)
        request.httpMethod = "GET"
        XCTAssertEqual(matcher.endpointKey(for: request), "GET /users/:id")
    }

    func testHostFilterDeclinesOtherHosts() {
        let matcher = PathMatcher(hosts: ["api.test"])
        var request = URLRequest(url: URL(string: "https://cdn.other/users/1")!)
        request.httpMethod = "GET"
        XCTAssertNil(matcher.endpointKey(for: request))
    }

    func testChainFallsBackToRawPathWhenNoMatcherClaims() {
        let chain = MatcherChain([PathMatcher(hosts: ["api.test"])])
        var request = URLRequest(url: URL(string: "https://cdn.other/assets/logo.png")!)
        request.httpMethod = "GET"
        XCTAssertEqual(chain.endpointKey(for: request), "GET /assets/logo.png")
    }

    func testChainPrefersFirstClaimingMatcher() {
        let chain = MatcherChain([GraphQLMatcher(), PathMatcher()])
        var request = URLRequest(url: URL(string: "https://api.test/graphql")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"operationName":"GetUser","query":"query GetUser { me }"}"#.utf8)
        XCTAssertEqual(chain.endpointKey(for: request), "GRAPHQL GetUser")
    }
}
