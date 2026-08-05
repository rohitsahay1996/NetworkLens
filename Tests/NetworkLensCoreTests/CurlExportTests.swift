//
//  CurlExportTests.swift
//  NetworkLensCoreTests
//
//  Created by Rohit Sahay on 30/07/26.
//

import XCTest
@testable import NetworkLensCore

final class CurlExportTests: XCTestCase {

    private func exchange(
        method: String = "GET",
        url: String = "https://api.test/users/7",
        headers: [String: String] = [:],
        body: Data? = nil,
        truncated: Bool = false
    ) -> NetworkExchange {
        var request = RequestSnapshot(method: method, url: URL(string: url)!)
        request.headers = headers
        request.body = body
        request.bodyTruncated = truncated
        return NetworkExchange(endpointKey: "\(method) /users/{id}", request: request)
    }

    // MARK: - Shape

    func testGetRendersWithoutAnExplicitMethod() {
        let command = CurlExport.command(for: exchange())

        XCTAssertFalse(command.contains("--request"), "GET is curl's default")
        XCTAssertTrue(command.contains("'https://api.test/users/7'"))
        XCTAssertTrue(command.hasPrefix("curl"))
    }

    func testPostRendersMethodHeadersAndBody() {
        let command = CurlExport.command(
            for: exchange(
                method: "POST",
                url: "https://api.test/orders",
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"sku":"A-1"}"#.utf8)
            )
        )

        XCTAssertTrue(command.contains("--request POST"))
        XCTAssertTrue(command.contains("--header 'Content-Type: application/json'"))
        XCTAssertTrue(command.contains(#"--data '{"sku":"A-1"}'"#))
    }

    /// The same request must always produce the same command, or a diff between
    /// two exports shows dictionary ordering rather than what changed.
    func testHeaderOrderIsStable() {
        let headers = ["B-Header": "2", "A-Header": "1", "C-Header": "3"]
        let first = CurlExport.command(for: exchange(headers: headers))
        let second = CurlExport.command(for: exchange(headers: headers))

        XCTAssertEqual(first, second)
        let a = try! XCTUnwrap(first.range(of: "A-Header"))
        let b = try! XCTUnwrap(first.range(of: "B-Header"))
        XCTAssertLessThan(a.lowerBound, b.lowerBound)
    }

    // MARK: - Escaping

    /// A single quote in a body would otherwise close the shell's quoting and
    /// turn the rest of the payload into commands.
    func testSingleQuotesAreEscapedForTheShell() {
        let command = CurlExport.command(
            for: exchange(
                method: "POST",
                body: Data(#"{"name":"O'Brien"}"#.utf8)
            )
        )

        XCTAssertTrue(command.contains(#"O'\''Brien"#))
        XCTAssertFalse(command.contains("O'Brien"), "the raw quote must not survive")
    }

    func testBinaryBodyIsDescribedRatherThanMangled() {
        let command = CurlExport.command(
            for: exchange(method: "POST", body: Data([0xFF, 0xFE, 0x00, 0x01]))
        )

        XCTAssertTrue(command.contains("--data-binary"))
        XCTAssertTrue(command.contains("4 bytes, not UTF-8"))
    }

    /// A command built from a clipped body would fail for a reason the reader
    /// cannot see, so it has to say so.
    func testTruncatedBodyIsFlaggedInTheCommand() {
        let command = CurlExport.command(
            for: exchange(method: "POST", body: Data("partial".utf8), truncated: true)
        )

        XCTAssertTrue(command.contains("# body truncated"))
    }

    // MARK: - Secrets

    /// Export moves traffic off the device, which is exactly where a token must
    /// not go — so the default is what was stored, and what was stored is
    /// redacted.
    func testDefaultExportUsesTheRedactedSnapshot() {
        let command = CurlExport.command(
            for: exchange(headers: ["Authorization": "***"])
        )

        XCTAssertTrue(command.contains("'Authorization: ***'"))
    }

    func testSecretsAreIncludedOnlyWhenAskedForByName() throws {
        let captured = exchange(headers: ["Authorization": "***"])

        var real = URLRequest(url: URL(string: "https://api.test/users/7")!)
        real.setValue("Bearer real-token", forHTTPHeaderField: "Authorization")
        ReplayStore.shared.record(real, for: captured.id)
        defer { ReplayStore.shared.removeAll() }

        let redacted = CurlExport.command(for: captured)
        let full = CurlExport.command(for: captured, secrets: .included)

        XCTAssertFalse(redacted.contains("real-token"))
        XCTAssertTrue(full.contains("'Authorization: Bearer real-token'"))
    }

    /// An exchange from a previous launch has no unredacted copy; falling back
    /// to the redacted one beats emitting nothing.
    func testAskingForSecretsFallsBackWhenTheOriginalIsGone() {
        let command = CurlExport.command(
            for: exchange(headers: ["Authorization": "***"]), secrets: .included
        )

        XCTAssertTrue(command.contains("'Authorization: ***'"))
    }

    // MARK: - Batches

    func testSeveralExchangesExportAsSeparateCommands() {
        let command = CurlExport.command(
            for: [exchange(url: "https://api.test/a"), exchange(url: "https://api.test/b")]
        )

        XCTAssertEqual(command.components(separatedBy: "curl").count - 1, 2)
        XCTAssertTrue(command.contains("api.test/a"))
        XCTAssertTrue(command.contains("api.test/b"))
    }
}
