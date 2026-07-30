import XCTest
import NetworkLensNoOp

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
            .request(request), owner: UUID(), endpointKey: "GET /", timeout: 60
        )

        guard case .proceed(let payload) = outcome, case .request = payload else {
            return XCTFail("expected the payload back untouched")
        }
    }

    func testPersistenceSurfaceCompilesAndWritesNothing() throws {
        let store = FileSnapshotStore()
        try store.save(LensSnapshot(mocks: [], breakpoints: [], perturbations: []))

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

    func testScreenAttributionSurfaceCompiles() {
        let token = ScreenContext.shared.push("Cart")
        defer { ScreenContext.shared.pop(token) }

        XCTAssertNil(ScreenContext.shared.current)
        XCTAssertTrue(ScreenContext.shared.trail.isEmpty)
    }
}
