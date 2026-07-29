import XCTest
@testable import NetworkLensCore

final class DefaultRedactorTests: XCTestCase {

    private let redactor = DefaultRedactor()
    private let placeholder = DefaultRedactor.defaultPlaceholder

    private func redactBody(_ json: String) -> String {
        let snapshot = RequestSnapshot(
            method: "POST",
            url: URL(string: "https://api.test/pay")!,
            headers: ["Content-Type": "application/json"],
            body: Data(json.utf8)
        )
        let redacted = redactor.redact(snapshot)
        return String(data: redacted.body ?? Data(), encoding: .utf8) ?? ""
    }

    // MARK: - Headers

    func testStripsAuthHeadersCaseInsensitively() {
        let snapshot = RequestSnapshot(
            method: "GET",
            url: URL(string: "https://api.test/me")!,
            headers: [
                "Authorization": "Bearer abc123",
                "cookie": "session=xyz",
                "X-API-Key": "k-1",
                "Accept": "application/json",
            ]
        )
        let redacted = redactor.redact(snapshot)
        XCTAssertEqual(redacted.headers["Authorization"], placeholder)
        XCTAssertEqual(redacted.headers["cookie"], placeholder)
        XCTAssertEqual(redacted.headers["X-API-Key"], placeholder)
        XCTAssertEqual(redacted.headers["Accept"], "application/json")
    }

    func testStripsSetCookieFromResponse() {
        let snapshot = ResponseSnapshot(
            statusCode: 200,
            headers: ["Set-Cookie": "session=xyz; HttpOnly", "Content-Type": "application/json"]
        )
        let redacted = redactor.redact(snapshot)
        XCTAssertEqual(redacted.headers["Set-Cookie"], placeholder)
        XCTAssertEqual(redacted.headers["Content-Type"], "application/json")
    }

    // MARK: - Body

    func testRedactsTopLevelSensitiveKeys() {
        let output = redactBody(#"{"cardNumber":"4111111111111111","amount":100}"#)
        XCTAssertEqual(output, #"{"cardNumber":"<redacted>","amount":100}"#)
    }

    func testRedactsNestedObjects() {
        let output = redactBody(#"{"payment":{"card":{"pan":"411","cvv":"123"},"currency":"GBP"}}"#)
        XCTAssertEqual(output, #"{"payment":{"card":"<redacted>","currency":"GBP"}}"#)
    }

    func testRedactsInsideArraysOfObjects() {
        let output = redactBody(#"{"items":[{"id":1,"secretCode":"a"},{"id":2,"secretCode":"b"}]}"#)
        XCTAssertEqual(
            output,
            #"{"items":[{"id":1,"secretCode":"<redacted>"},{"id":2,"secretCode":"<redacted>"}]}"#
        )
    }

    func testRedactsArrayOfObjectsAtRoot() {
        let output = redactBody(#"[{"password":"a"},{"password":"b"}]"#)
        XCTAssertEqual(output, #"[{"password":"<redacted>"},{"password":"<redacted>"}]"#)
    }

    func testKeyMatchingIsCaseInsensitive() {
        let output = redactBody(#"{"PASSWORD":"a","Cvv":"1","Access_Token":"t"}"#)
        XCTAssertEqual(
            output,
            #"{"PASSWORD":"<redacted>","Cvv":"<redacted>","Access_Token":"<redacted>"}"#
        )
    }

    func testPreservesKeyOrderAndNumberLiterals() {
        let output = redactBody(#"{"z":1.0,"token":"t","a":9007199254740993,"m":1e-7}"#)
        XCTAssertEqual(
            output,
            #"{"z":1.0,"token":"<redacted>","a":9007199254740993,"m":1e-7}"#
        )
    }

    func testRedactsWholeSubtreeWhenKeyIsSensitive() {
        let output = redactBody(#"{"card":{"pan":"411","expiry":"12/29"}}"#)
        XCTAssertEqual(output, #"{"card":"<redacted>"}"#)
    }

    // MARK: - Key tokenisation

    func testDoesNotMatchWordsMerelyContainingATerm() {
        XCTAssertFalse(redactor.matches(key: "company"))
        XCTAssertFalse(redactor.matches(key: "japan"))
        XCTAssertFalse(redactor.matches(key: "discard_reason"))
    }

    func testMatchesCamelSnakeAndDigitBoundaries() {
        XCTAssertTrue(redactor.matches(key: "cardNumber"))
        XCTAssertTrue(redactor.matches(key: "card_holder"))
        XCTAssertTrue(redactor.matches(key: "cvv2"))
        XCTAssertTrue(redactor.matches(key: "accessToken"))
        XCTAssertTrue(redactor.matches(key: "user.password"))
        XCTAssertTrue(redactor.matches(key: "cardholder"))
    }

    // MARK: - URL and form bodies

    func testRedactsSensitiveQueryItems() {
        let snapshot = RequestSnapshot(
            method: "GET",
            url: URL(string: "https://api.test/me?access_token=abc&page=2")!
        )
        let redacted = redactor.redact(snapshot)
        XCTAssertEqual(
            redacted.url.absoluteString,
            "https://api.test/me?access_token=%3Credacted%3E&page=2"
        )
    }

    func testRedactsFormEncodedBody() {
        let snapshot = RequestSnapshot(
            method: "POST",
            url: URL(string: "https://api.test/login")!,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: Data("username=ada&password=hunter2".utf8)
        )
        let redacted = redactor.redact(snapshot)
        XCTAssertEqual(
            String(data: redacted.body!, encoding: .utf8),
            "username=ada&password=<redacted>"
        )
    }

    func testLeavesUnknownBinaryBodyAlone() {
        let bytes = Data([0x00, 0xFF, 0x10, 0x42])
        let snapshot = RequestSnapshot(
            method: "POST",
            url: URL(string: "https://api.test/upload")!,
            headers: ["Content-Type": "application/octet-stream"],
            body: bytes
        )
        XCTAssertEqual(redactor.redact(snapshot).body, bytes)
    }

    // MARK: - Store integration

    func testRedactionHappensBeforeStorage() {
        let store = ExchangeStore()
        let exchange = NetworkExchange(
            endpointKey: "POST /pay",
            request: RequestSnapshot(
                method: "POST",
                url: URL(string: "https://api.test/pay")!,
                headers: ["Authorization": "Bearer secret-token"],
                body: Data(#"{"pan":"4111111111111111"}"#.utf8)
            )
        )
        store.record(exchange.redacted(by: redactor))

        let stored = store.exchanges[0]
        XCTAssertEqual(stored.request.headers["Authorization"], placeholder)
        let body = String(data: stored.request.body!, encoding: .utf8)!
        XCTAssertFalse(body.contains("4111111111111111"))
    }
}
