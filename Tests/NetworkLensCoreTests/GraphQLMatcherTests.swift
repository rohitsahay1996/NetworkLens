import XCTest
@testable import NetworkLensCore

final class GraphQLMatcherTests: XCTestCase {

    private let matcher = GraphQLMatcher()

    private func key(body: String, path: String = "/graphql", method: String = "POST") -> String? {
        var request = URLRequest(url: URL(string: "https://api.test\(path)")!)
        request.httpMethod = method
        request.httpBody = Data(body.utf8)
        return matcher.endpointKey(for: request)
    }

    func testExplicitOperationNameWins() {
        XCTAssertEqual(
            key(body: #"{"operationName":"GetUserProfile","query":"query Other { x }"}"#),
            "GRAPHQL GetUserProfile"
        )
    }

    func testFallsBackToQueryDocumentName() {
        XCTAssertEqual(
            key(body: #"{"query":"query GetCart($id: ID!) { cart(id: $id) { total } }"}"#),
            "GRAPHQL GetCart"
        )
    }

    func testMutationDocumentName() {
        XCTAssertEqual(
            key(body: #"{"query":"mutation PayOrder { pay { ok } }"}"#),
            "GRAPHQL PayOrder"
        )
    }

    func testAnonymousDocumentDeclines() {
        XCTAssertNil(key(body: #"{"query":"{ me { id } }"}"#))
    }

    func testBatchedOperations() {
        let body = #"[{"operationName":"A","query":""},{"operationName":"B","query":""}]"#
        XCTAssertEqual(key(body: body), "GRAPHQL [A, B]")
    }

    func testDeclinesNonGraphQLPath() {
        XCTAssertNil(key(body: #"{"operationName":"GetUser"}"#, path: "/rest/users"))
    }

    func testDeclinesEmptyBody() {
        XCTAssertNil(key(body: ""))
    }

    func testDeclinesNonJSONBody() {
        XCTAssertNil(key(body: "query GetUser { me }"))
    }

    func testPathComparisonIsCaseInsensitive() {
        XCTAssertEqual(
            key(body: #"{"operationName":"GetUser"}"#, path: "/GraphQL"),
            "GRAPHQL GetUser"
        )
    }

    func testDocumentNameParsingSkipsLeadingWhitespace() {
        XCTAssertEqual(
            GraphQLMatcher.parseOperationName(fromDocument: "\n  query  GetThing {"),
            "GetThing"
        )
    }
}
