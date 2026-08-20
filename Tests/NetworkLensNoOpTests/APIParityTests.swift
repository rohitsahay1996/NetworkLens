//
//  APIParityTests.swift
//  NetworkLensNoOpTests
//
//  Created by Rohit Sahay on 30/07/26.
//

import XCTest
import NetworkLensNoOp

#if canImport(UIKit)
import UIKit
import SwiftUI
#endif

/// Host-shaped call sites, compiled against the inert mirror.
///
/// Most of the value here is that it compiles at all: `NetworkLensNoOp`
/// redeclares Core's public surface by hand, and nothing but a call site
/// notices when Core moves and the mirror does not. The assertions are the
/// smaller half — they pin the one behaviour the mirror does promise, which is
/// that it does nothing.
final class APIParityTests: XCTestCase {

    func testStartAndConfigurationSurfaceCompiles() {
        NetworkLens.start(
            configuration: LensConfiguration(
                matchers: [GraphQLMatcher(), PathMatcher()],
                redactor: DefaultRedactor(),
                maxStoredExchanges: 500,
                productionHostPatterns: ["api.acme.com"],
                keepBreakpointsAcrossLaunches: true,
                persistsRules: true
            )
        )

        XCTAssertFalse(NetworkLens.isActive)
        XCTAssertFalse(NetworkLens.configuration.isProductionHost("api.acme.com"))
        XCTAssertTrue(NetworkLens.store.exchanges.isEmpty)
        XCTAssertEqual(NetworkLens.endpointKey(for: URLRequest(url: URL(string: "https://x.test")!)), "")
    }

    func testMockingSurfaceCompilesAndServesNothing() {
        let rule = MockRule(
            endpointKey: "GET /users/{id}",
            steps: [.fail(.offline()), .respond(.json(#"{"ok":true}"#)), .respond(.status(204))],
            exhaustion: .passThrough,
            name: "flaky user"
        )
        Mocks.shared.set(rule)
        Mocks.shared.setMockingEnabled(true)

        XCTAssertTrue(Mocks.shared.all.isEmpty)
        XCTAssertNil(Mocks.shared.resolve(URLRequest(url: URL(string: "https://x.test/users/1")!)))
        XCTAssertEqual(Mocks.shared.hitCount(forRuleID: rule.id), 0)
        XCTAssertTrue(rule.isScripted)
        XCTAssertEqual(rule.steps.count, 3)
    }

    func testFailurePresetsCarryTheSameCodesAsCore() {
        XCTAssertEqual(MockFailure.offline().urlError.code, .notConnectedToInternet)
        XCTAssertEqual(MockFailure.connectionLost().urlError.code, .networkConnectionLost)
        XCTAssertEqual(MockFailure.presets.count, 5)
    }

    func testBreakpointSurfaceCompilesAndArmsNothing() {
        Breakpoints.shared.setRequestEditingEnabled(true)
        Breakpoints.shared.set(Breakpoint(endpointKey: "GET /orders", stage: .both, oneShot: true))
        Breakpoints.shared.save(
            Perturbation(name: "empty cart", endpointKey: "GET /cart", ops: [])
        )

        XCTAssertTrue(Breakpoints.shared.all.isEmpty)
        XCTAssertFalse(Breakpoints.shared.isRequestEditingEnabled)
        XCTAssertFalse(
            Breakpoints.shared.shouldPauseResponse(
                for: URLRequest(url: URL(string: "https://x.test/orders")!)
            )
        )
    }

    /// A release build must never hold a request. If this ever suspends, the
    /// mirror has stopped being inert.
    func testPauseReturnsThePayloadImmediately() async {
        let request = URLRequest(url: URL(string: "https://x.test")!)
        let outcome = await BreakpointCoordinator.shared.pause(
            .request(request), owner: UUID(), exchangeID: UUID(), endpointKey: "GET /", timeout: 60
        )

        guard case .proceed(let payload) = outcome, case .request = payload else {
            return XCTFail("expected the payload back untouched")
        }

        // Nothing is ever held here, so this has nothing to arm — it exists so
        // the UI's call site compiles against the mirror.
        await BreakpointCoordinator.shared.setAutoResumeEnabled(false, for: UUID())
    }

    /// Every field is named on purpose. The mirror once carried `PatchOp.Kind`
    /// as set/remove/insert against Core's replace/remove/add and compiled fine,
    /// because no call site here mentioned a case — so a release build using
    /// `.replace` would have been the first thing to notice.
    func testScenarioSurfaceCompilesAndAppliesNothing() {
        let entry = Scenario.Entry(
            endpointKey: "GET /cart",
            match: MockMatch(query: ["page": "2"]),
            variantID: UUID(),
            variantName: "empty",
            isEnabled: true
        )
        let scenario = Scenario(name: "checkout", entries: [entry])

        Scenarios.shared.save(scenario)
        let outcome = Scenarios.shared.apply(scenario)

        XCTAssertTrue(Scenarios.shared.all.isEmpty)
        XCTAssertNil(Scenarios.shared.applied())
        XCTAssertEqual(outcome.applied, 0)
        XCTAssertFalse(outcome.isComplete)
        XCTAssertEqual(Scenario.capturing("x", from: []).entries.count, 0)
    }

    /// The launch-argument bridge is the one surface a UI test drives directly,
    /// so a release build has to compile the same call sites — and has to fail
    /// the assertion rather than quietly report success it cannot deliver.
    func testLaunchScenarioSurfaceCompilesAndAppliesNothing() {
        XCTAssertEqual(LensLaunchOptions.scenarioFlag, "-NetworkLensScenario")
        XCTAssertEqual(LensLaunchOptions.scenarioEnvironmentKey, "NETWORKLENS_SCENARIO")
        XCTAssertNil(
            LensLaunchOptions.scenarioName(
                arguments: ["app", "-NetworkLensScenario", "cart empty"],
                environment: ["NETWORKLENS_SCENARIO": "cart empty"]
            )
        )

        let activation = NetworkLens.applyScenario(named: "cart empty")
        XCTAssertFalse(activation.isApplied)
        XCTAssertEqual(activation, .noSuchScenario(name: "cart empty", available: []))
        XCTAssertNil(NetworkLens.launchScenarioActivation)
    }

    func testCurlExportSurfaceCompilesAndRendersNothing() {
        let exchange = NetworkExchange(
            endpointKey: "GET /users/{id}",
            request: RequestSnapshot(method: "GET", url: URL(string: "https://x.test/users/1")!)
        )

        XCTAssertTrue(CurlExport.command(for: exchange).isEmpty)
        XCTAssertTrue(CurlExport.command(for: exchange, secrets: .included).isEmpty)
        XCTAssertTrue(CurlExport.command(for: [exchange], secrets: .redacted).isEmpty)
    }

    /// The integration surface a host's networking module touches. If any of
    /// this stops compiling, a release build stops compiling.
    func testIntegrationSurfaceCompiles() {
        let configuration = URLSessionConfiguration.ephemeral

        XCTAssertFalse(NetworkLens.install(into: configuration))
        XCTAssertFalse(NetworkLens.canIntercept(configuration))
        XCTAssertTrue(NetworkLens.uninterceptable.isEmpty)
        XCTAssertEqual(LensHeaders.screen, "X-NetworkLens-Screen")

        var request = URLRequest(url: URL(string: "https://x.test")!)
        request.setValue("Checkout", forHTTPHeaderField: LensHeaders.screen)
        XCTAssertEqual(request.value(forHTTPHeaderField: LensHeaders.screen), "Checkout")
    }

    /// Request mocking reaches a real server in the real build, so the mirror
    /// has to expose it and do nothing.
    func testRequestRewriteSurfaceCompilesAndRewritesNothing() {
        let rewrite = MockRequestRewrite(
            body: Data("{}".utf8),
            headers: ["X-Debug": "1"],
            removedHeaders: ["Authorization"],
            method: "PUT"
        )
        let rule = MockRule(endpointKey: "POST /orders", steps: [.rewrite(rewrite)])

        var request = URLRequest(url: URL(string: "https://x.test/orders")!)
        request.httpBody = Data(#"{"real":true}"#.utf8)

        XCTAssertEqual(rewrite.applied(to: request).httpBody, Data(#"{"real":true}"#.utf8))
        XCTAssertNotNil(rule.steps.first?.rewrite)
        XCTAssertTrue(NetworkLens.blockedRewrites.isEmpty)
    }

    func testPatchOpKindsMatchCore() {
        XCTAssertEqual(
            [PatchOp.Kind.replace, .remove, .add].map(\.rawValue),
            ["replace", "remove", "add"]
        )
    }

    func testPersistenceSurfaceCompilesAndWritesNothing() throws {
        let store = FileSnapshotStore()
        try store.save(
            LensSnapshot(mocks: [], breakpoints: [], perturbations: [], scenarios: [])
        )

        XCTAssertNil(try store.load())
        XCTAssertFalse(LensPersistence.shared.persist())

        LensPersistence.shared.restore(keepingActiveRules: true)
        LensPersistence.shared.beginAutosave()
        LensPersistence.shared.flush()
        LensPersistence.shared.endAutosave()
    }

    func testExchangeAndEditSurfaceCompiles() {
        let exchange = NetworkExchange(
            endpointKey: "GET /users/{id}",
            request: RequestSnapshot(method: "GET", url: URL(string: "https://x.test/users/1")!),
            source: .perturbed(name: "empty cart")
        )

        XCTAssertEqual(exchange.source.label, "empty cart")
        XCTAssertTrue(exchange.source.isSynthetic)
        XCTAssertTrue(exchange.edits.isEmpty)
        XCTAssertEqual(
            exchange.loggingEdit(
                EditRecord(stage: .response, originalHash: "", ops: [])
            ).edits.count,
            0
        )
        XCTAssertEqual(exchange.withSource(.live).source.label, "empty cart")
    }

    func testRequestEditingSurfaceCompiles() {
        let request = URLRequest(url: URL(string: "https://x.test/users?page=1")!)

        XCTAssertNil(request.jsonBody)
        XCTAssertFalse(request.bodyIsEditableAsJSON)
        XCTAssertTrue(request.queryItems.isEmpty)
        XCTAssertTrue(request.replacingHeader(name: "X", value: "1").queryItems.isEmpty)
        XCTAssertEqual(Data("{}".utf8).bodyPresentation(contentType: "application/json"), .empty)
    }

    /// The capture cap is now a real truncation rather than a flag, so the
    /// mirror has to carry the same shape — a host that reads a captured body
    /// must compile in a release build too.
    func testResponseCaptureSurfaceCompiles() throws {
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: URL(string: "https://x.test/big")!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: [:]
            )
        )
        let payload = ResponsePayload(response: response, body: Data(repeating: 0, count: 4_096))
        let snapshot = payload.snapshot(cap: 64)

        XCTAssertEqual(snapshot.statusCode, 200)
        XCTAssertNil(snapshot.body, "the mirror captures nothing")
        XCTAssertNil(
            ResponseSnapshot(
                response: response, body: Data(), bodyTruncated: true, originalBodyByteCount: 4_096
            ).body
        )
    }

    func testScreenAttributionSurfaceCompiles() {
        let token = ScreenContext.shared.push("Cart")
        defer { ScreenContext.shared.pop(token) }

        XCTAssertNil(ScreenContext.shared.current)
        XCTAssertTrue(ScreenContext.shared.trail.isEmpty)
    }

    // MARK: - Overlay
    //
    // These only compile on a UIKit run. The mirror shipped without
    // `attachOverlayToActiveScene()` and `networkLensOverlay()` for a while and
    // nothing caught it, because the macOS test run — the one CI does — cannot
    // see either. Run the package against an iOS simulator destination to get
    // any value out of this section.

    #if canImport(UIKit)
    /// The three overlay entry points a host can write, compiled inert.
    ///
    /// `attachOverlay(to:)` needs a real `UIWindowScene`, which a test has no
    /// way to conjure, so it is referenced as a function value rather than
    /// called. That still fails the build if the signature drifts, which is the
    /// whole point.
    @MainActor
    func testOverlaySurfaceCompiles() {
        let attach: (UIWindowScene) -> Void = NetworkLens.attachOverlay(to:)
        let detach: (UIWindowScene) -> Void = NetworkLens.detachOverlay(from:)
        XCTAssertNotNil(attach)
        XCTAssertNotNil(detach)

        XCTAssertFalse(
            NetworkLens.attachOverlayToActiveScene(),
            "the mirror never attaches, so host code must not retry until true"
        )
    }

    /// The SwiftUI call site, which is the one a release build most often
    /// breaks on: it sits in the app's scene body, so it fails the whole app
    /// target rather than one file.
    @MainActor
    func testSwiftUIOverlayModifierCompiles() {
        _ = Text("host content").networkLensOverlay()
    }
    #endif
}
