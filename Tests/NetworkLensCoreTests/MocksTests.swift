import XCTest
@testable import NetworkLensCore

final class MocksTests: XCTestCase {

    private func makeRequest(_ path: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.test\(path)")!)
        request.httpMethod = method
        return request
    }

    private func makeRule(
        _ endpointKey: String = "GET /users/{id}",
        statusCode: Int = 200,
        isEnabled: Bool = true
    ) -> MockRule {
        MockRule(
            endpointKey: endpointKey,
            response: .status(statusCode),
            isEnabled: isEnabled
        )
    }

    // MARK: - Registration

    func testSetReplacesTheRuleForTheSameEndpointKey() {
        let mocks = Mocks()
        mocks.set(makeRule(statusCode: 200))
        mocks.set(makeRule(statusCode: 500))

        XCTAssertEqual(mocks.all.count, 1)
        XCTAssertEqual(mocks.rule(forEndpointKey: "GET /users/{id}")?.outcome(forHit: 1)?.response?.statusCode, 500)
    }

    func testSetKeepsRulesForDifferentEndpointKeys() {
        let mocks = Mocks()
        mocks.set(makeRule("GET /users/{id}"))
        mocks.set(makeRule("POST /users"))

        XCTAssertEqual(mocks.all.count, 2)
    }

    func testRemoveAndRemoveAll() {
        let mocks = Mocks()
        let rule = makeRule()
        mocks.set(rule)
        mocks.set(makeRule("POST /users"))

        mocks.remove(id: rule.id)
        XCTAssertEqual(mocks.all.map(\.endpointKey), ["POST /users"])

        mocks.removeAll()
        XCTAssertTrue(mocks.all.isEmpty)
    }

    func testDisableAllKeepsRulesButStopsServingThem() {
        let mocks = Mocks()
        mocks.set(makeRule())

        mocks.disableAll()

        XCTAssertEqual(mocks.all.count, 1)
        XCTAssertNil(mocks.resolve(makeRequest("/users/1")))
    }

    // MARK: - Resolution

    func testResolveMatchesOnTemplatedEndpointKeyAcrossPathParams() {
        let mocks = Mocks()
        mocks.set(makeRule("GET /users/{id}", statusCode: 418))

        XCTAssertEqual(mocks.resolve(makeRequest("/users/1"))?.response?.statusCode, 418)
        XCTAssertEqual(mocks.resolve(makeRequest("/users/98765"))?.response?.statusCode, 418)
    }

    func testResolveIsMethodSpecific() {
        let mocks = Mocks()
        mocks.set(makeRule("GET /users"))

        XCTAssertNotNil(mocks.resolve(makeRequest("/users")))
        XCTAssertNil(mocks.resolve(makeRequest("/users", method: "POST")))
    }

    func testResolveReturnsNilForUnmatchedRequestAndForEmptyRegistry() {
        let mocks = Mocks()
        XCTAssertNil(mocks.resolve(makeRequest("/users/1")))

        mocks.set(makeRule("GET /orders"))
        XCTAssertNil(mocks.resolve(makeRequest("/users/1")))
    }

    func testDisabledRuleIsNotResolved() {
        let mocks = Mocks()
        mocks.set(makeRule(isEnabled: false))

        XCTAssertNil(mocks.resolve(makeRequest("/users/1")))
    }

    func testMasterSwitchSuspendsEveryRuleWithoutDiscardingThem() {
        let mocks = Mocks()
        mocks.set(makeRule())

        mocks.setMockingEnabled(false)
        XCTAssertFalse(mocks.isMockingEnabled)
        XCTAssertNil(mocks.resolve(makeRequest("/users/1")))

        mocks.setMockingEnabled(true)
        XCTAssertNotNil(mocks.resolve(makeRequest("/users/1")))
    }

    // MARK: - Hit accounting

    func testResolveIncrementsHitIndexPerRule() {
        let mocks = Mocks()
        let rule = makeRule()
        mocks.set(rule)

        XCTAssertEqual(mocks.resolve(makeRequest("/users/1"))?.hitIndex, 1)
        XCTAssertEqual(mocks.resolve(makeRequest("/users/2"))?.hitIndex, 2)
        XCTAssertEqual(mocks.resolve(makeRequest("/users/3"))?.hitIndex, 3)

        XCTAssertEqual(mocks.hitCount(forRuleID: rule.id), 3)
        XCTAssertEqual(mocks.hitCount(forEndpointKey: "GET /users/{id}"), 3)
    }

    func testHitCountsAreIndependentPerRule() {
        let mocks = Mocks()
        mocks.set(makeRule("GET /users/{id}"))
        mocks.set(makeRule("GET /orders"))

        _ = mocks.resolve(makeRequest("/users/1"))
        _ = mocks.resolve(makeRequest("/users/2"))
        _ = mocks.resolve(makeRequest("/orders"))

        XCTAssertEqual(mocks.hitCount(forEndpointKey: "GET /users/{id}"), 2)
        XCTAssertEqual(mocks.hitCount(forEndpointKey: "GET /orders"), 1)
    }

    func testUnmatchedAndSuspendedRequestsDoNotCount() {
        let mocks = Mocks()
        mocks.set(makeRule())

        _ = mocks.resolve(makeRequest("/orders"))
        mocks.setMockingEnabled(false)
        _ = mocks.resolve(makeRequest("/users/1"))

        XCTAssertEqual(mocks.hitCount(forEndpointKey: "GET /users/{id}"), 0)
    }

    /// Replacing a rule must not hand the new one the old one's history — the
    /// count is what a scripted per-hit sequence will key off.
    func testReplacingARuleResetsItsHitCount() {
        let mocks = Mocks()
        mocks.set(makeRule())
        _ = mocks.resolve(makeRequest("/users/1"))
        XCTAssertEqual(mocks.hitCount(forEndpointKey: "GET /users/{id}"), 1)

        mocks.set(makeRule(statusCode: 500))

        XCTAssertEqual(mocks.hitCount(forEndpointKey: "GET /users/{id}"), 0)
    }

    /// Editing a rule in place, id intact, is a mutation of the same rule and
    /// keeps counting.
    func testUpdatingARuleInPlaceKeepsItsHitCount() {
        let mocks = Mocks()
        var rule = makeRule()
        mocks.set(rule)
        _ = mocks.resolve(makeRequest("/users/1"))

        rule.steps = [.respond(.status(500))]
        mocks.set(rule)

        XCTAssertEqual(mocks.hitCount(forRuleID: rule.id), 1)
    }

    func testResetHitCountsKeepsRules() {
        let mocks = Mocks()
        mocks.set(makeRule())
        _ = mocks.resolve(makeRequest("/users/1"))

        mocks.resetHitCounts()

        XCTAssertEqual(mocks.all.count, 1)
        XCTAssertEqual(mocks.hitCount(forEndpointKey: "GET /users/{id}"), 0)
    }

    func testClearForRelaunchDropsRulesAndCounts() {
        let mocks = Mocks()
        let rule = makeRule()
        mocks.set(rule)
        _ = mocks.resolve(makeRequest("/users/1"))

        mocks.clearForRelaunch()

        XCTAssertTrue(mocks.all.isEmpty)
        XCTAssertEqual(mocks.hitCount(forRuleID: rule.id), 0)
    }

    // MARK: - Observation

    func testObserverFiresOnMutationAndStopsAfterTokenIsReleased() {
        let mocks = Mocks()
        let counter = MockObserverCounter()

        var token: Mocks.ObservationToken? = mocks.addObserver { counter.increment() }
        mocks.set(makeRule())
        XCTAssertEqual(counter.value, 1)

        _ = mocks.resolve(makeRequest("/users/1"))
        XCTAssertEqual(counter.value, 1, "resolve runs on the hot path and must not notify")

        token = nil
        _ = token
        mocks.set(makeRule("POST /users"))
        XCTAssertEqual(counter.value, 1)
    }

    // MARK: - Concurrency

    func testConcurrentResolvesCountEveryHitExactlyOnce() async {
        let mocks = Mocks()
        let rule = makeRule()
        mocks.set(rule)
        let requests = (0..<200).map { makeRequest("/users/\($0)") }

        await withTaskGroup(of: Void.self) { group in
            for request in requests {
                group.addTask { _ = mocks.resolve(request) }
            }
        }

        XCTAssertEqual(mocks.hitCount(forRuleID: rule.id), 200)
    }
}

private final class MockObserverCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}
