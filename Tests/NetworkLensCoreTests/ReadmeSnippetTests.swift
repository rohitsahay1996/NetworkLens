//
//  ReadmeSnippetTests.swift
//  NetworkLensCoreTests
//
//  Created by Rohit Sahay on 31/07/26.
//

import XCTest
@testable import NetworkLensCore

/// The README's code, compiled.
///
/// Documentation rots faster than code because nothing fails when it does — a
/// rename lands, the samples keep claiming an API that no longer exists, and
/// the person who finds out is someone integrating for the first time. These
/// are the snippets a reader will paste, so they have to build.
final class ReadmeSnippetTests: XCTestCase {

    func testConfigurationSnippetCompiles() {
        NetworkLens.start(
            configuration: LensConfiguration(
                matchers: [GraphQLMatcher(), PathMatcher()],
                redactor: DefaultRedactor(),
                maxStoredExchanges: 500,
                automaticScreenAttribution: true,
                maxCapturedRequestBodyBytes: 1_048_576,
                maxCapturedResponseBodyBytes: 1_048_576,
                productionHostPatterns: ["api.myapp.com"],
                keepBreakpointsAcrossLaunches: false,
                persistsRules: true,
                redactsPersistedRules: true
            )
        )

        XCTAssertTrue(NetworkLens.configuration.isProductionHost("api.myapp.com"))
        NetworkLens.start(configuration: LensConfiguration(maxStoredExchanges: 50))
    }

    /// The trace snippet from "Reading the trace from an agent". The MCP server
    /// reads what this writes, so a rename here breaks a tool in another
    /// language that no Swift compile would otherwise catch.
    func testTraceSnippetCompiles() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("readme-trace-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        NetworkLens.start(
            configuration: LensConfiguration(
                trace: TraceOptions(url: directory.appendingPathComponent("trace.ndjson"))
            )
        )

        XCTAssertNotNil(NetworkLens.traceURL)
        NetworkLens.flushTrace()

        // Back to a configuration that writes nothing, so this test does not
        // leave a writer attached to the shared store for whatever runs next.
        NetworkLens.start(configuration: LensConfiguration())
    }

    /// The README once told readers to write `URLSessionConfiguration()`, which
    /// has no usable initialiser and traps at runtime. Compiling — and running —
    /// the samples is what caught it.
    func testCustomConfigurationSnippetCompiles() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.httpAdditionalHeaders = ["User-Agent": "MyApp/1.0"]

        XCTAssertTrue(NetworkLens.install(into: configuration))
        _ = URLSession(configuration: configuration)
    }

    func testEscapeHatchSnippetCompiles() {
        NetworkLens.store.removeAll()
        let url = URL(string: "https://sdk.test/upload")!

        NetworkLens.record(
            NetworkExchange(
                endpointKey: "POST /sdk/upload",
                request: RequestSnapshot(method: "POST", url: url),
                response: ResponseSnapshot(statusCode: 200, headers: [:], body: Data())
            )
        )

        XCTAssertEqual(NetworkLens.store.exchanges.count, 1)
        NetworkLens.store.removeAll()
    }

    func testAttributionSnippetsCompile() {
        var request = URLRequest(url: URL(string: "https://api.test/cart")!)
        request.setValue("Checkout", forHTTPHeaderField: LensHeaders.screen)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-NetworkLens-Screen"), "Checkout")

        let tagged = NetworkLens.tagged(request, screen: "Checkout")
        XCTAssertNotNil(tagged.url)

        let token = ScreenContext.shared.push("Checkout")
        XCTAssertEqual(ScreenContext.shared.current, "Checkout")
        ScreenContext.shared.pop(token)
    }

    func testProgrammaticRuleSnippetsCompile() {
        let mocks = Mocks()
        mocks.set(
            MockRule(
                endpointKey: "GET /cart",
                response: .json(#"{"items":[]}"#),
                name: "empty"
            )
        )
        mocks.set(
            MockRule(endpointKey: "GET /cart", steps: [.hang], name: "stuck loading")
        )

        XCTAssertEqual(mocks.all.count, 1, "same key and conditions replaces")
    }

    func testExportSnippetCompiles() {
        let exchange = NetworkExchange(
            endpointKey: "GET /cart",
            request: RequestSnapshot(method: "GET", url: URL(string: "https://api.test/cart")!)
        )

        XCTAssertTrue(
            CurlExport.command(for: exchange, secrets: .redacted).contains("curl")
        )
    }
}
