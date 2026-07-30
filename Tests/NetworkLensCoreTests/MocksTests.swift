//
//  MocksTests.swift
//  NetworkLensCoreTests
//
//  Created by Rohit Sahay on 30/07/26.
//

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

    // MARK: - Query-aware matching

    private func pagedRequest(_ page: Int) -> URLRequest {
        URLRequest(url: URL(string: "https://api.test/items?page=\(page)&sort=desc")!)
    }

    /// The case `endpointKey` alone cannot express: page 1 full, page 2 empty.
    /// Every end-of-pagination bug lives here.
    func testRulesForTheSameEndpointCanDifferByQuery() {
        let mocks = Mocks()
        mocks.set(
            MockRule(
                endpointKey: "GET /items", response: .json(#"{"items":[1,2]}"#),
                name: "page 1", match: MockMatch(query: ["page": "1"])
            )
        )
        mocks.set(
            MockRule(
                endpointKey: "GET /items", response: .json(#"{"items":[]}"#),
                name: "page 2", match: MockMatch(query: ["page": "2"])
            )
        )

        XCTAssertEqual(mocks.all.count, 2, "differing conditions must coexist, not overwrite")
        XCTAssertEqual(mocks.resolve(pagedRequest(1))?.name, "page 1")
        XCTAssertEqual(mocks.resolve(pagedRequest(2))?.name, "page 2")
    }

    /// Order of arming must not decide the answer.
    func testNarrowestRuleWinsRegardlessOfInsertionOrder() {
        for reversed in [false, true] {
            let mocks = Mocks()
            let catchAll = MockRule(
                endpointKey: "GET /items", response: .status(200), name: "any"
            )
            let specific = MockRule(
                endpointKey: "GET /items", response: .status(204), name: "page 2",
                match: MockMatch(query: ["page": "2"])
            )

            for rule in reversed ? [specific, catchAll] : [catchAll, specific] {
                mocks.set(rule)
            }

            XCTAssertEqual(mocks.resolve(pagedRequest(2))?.name, "page 2")
            XCTAssertEqual(mocks.resolve(pagedRequest(9))?.name, "any", "unmatched falls back")
        }
    }

    func testSavingTheSameConditionsReplacesRatherThanAccumulates() {
        let mocks = Mocks()
        let match = MockMatch(query: ["page": "2"])
        mocks.set(
            MockRule(endpointKey: "GET /items", response: .status(200), name: "a", match: match)
        )
        mocks.set(
            MockRule(endpointKey: "GET /items", response: .status(500), name: "b", match: match)
        )

        XCTAssertEqual(mocks.all.count, 1)
        XCTAssertEqual(mocks.resolve(pagedRequest(2))?.outcome.response?.statusCode, 500)
    }

    func testUnmatchedQueryWithNoCatchAllIsNotClaimed() {
        let mocks = Mocks()
        mocks.set(
            MockRule(
                endpointKey: "GET /items", response: .status(200),
                match: MockMatch(query: ["page": "2"])
            )
        )

        XCTAssertNil(mocks.resolve(pagedRequest(1)))
        XCTAssertEqual(mocks.hitCount(forEndpointKey: "GET /items"), 0)
    }

    func testAnyValueMatchesAnyQueryValueButRequiresPresence() {
        let match = MockMatch(query: ["cursor": MockMatch.anyValue])

        XCTAssertTrue(
            match.matches(URLRequest(url: URL(string: "https://api.test/items?cursor=abc")!))
        )
        XCTAssertFalse(
            match.matches(URLRequest(url: URL(string: "https://api.test/items?page=1")!))
        )
    }

    func testHeaderMatchingIsCaseInsensitiveOnTheName() {
        var request = URLRequest(url: URL(string: "https://api.test/items")!)
        request.setValue("v2", forHTTPHeaderField: "X-API-Version")

        XCTAssertTrue(MockMatch(headers: ["x-api-version": "v2"]).matches(request))
        XCTAssertFalse(MockMatch(headers: ["x-api-version": "v3"]).matches(request))
    }

    /// Two GraphQL operations share one path; the body is what separates them.
    func testBodyContainsSeparatesTwoPostsToTheSamePath() {
        var request = URLRequest(url: URL(string: "https://api.test/graphql")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"operationName":"Cart"}"#.utf8)

        XCTAssertTrue(MockMatch(bodyContains: "\"Cart\"").matches(request))
        XCTAssertFalse(MockMatch(bodyContains: "\"Checkout\"").matches(request))
    }

    func testMatchingQueryCapturesTheRequestsOwnQuery() {
        let snapshot = RequestSnapshot(
            method: "GET", url: URL(string: "https://api.test/items?page=2&sort=desc")!
        )
        let match = MockMatch.matchingQuery(of: snapshot)

        XCTAssertEqual(match.query, ["page": "2", "sort": "desc"])
        XCTAssertTrue(match.matches(pagedRequest(2)))
        XCTAssertFalse(match.matches(pagedRequest(1)))
        XCTAssertEqual(match.summary, "page=2, sort=desc")
    }

    /// Rules saved before conditions existed decode as catch-alls.
    func testRuleWithoutAMatchFieldDecodesAsCatchAll() throws {
        let legacy = Data("""
        {"id":"\(UUID().uuidString)","endpointKey":"GET /items","isEnabled":true,
         "steps":[{"respond":{"_0":{"statusCode":200,"headers":{},"body":"","delay":0}}}],
         "exhaustion":"repeatLast"}
        """.utf8)

        let decoded = try JSONDecoder().decode(MockRule.self, from: legacy)
        XCTAssertTrue(decoded.match.isCatchAll)
    }

    // MARK: - Variants

    private func variantRule() -> MockRule {
        MockRule(
            endpointKey: "GET /cart",
            variants: [
                MockVariant(name: "loaded", steps: [.respond(.json(#"{"items":[1,2]}"#))]),
                MockVariant(name: "empty", steps: [.respond(.json(#"{"items":[]}"#))]),
                MockVariant(name: "500", steps: [.respond(.status(500))]),
            ]
        )
    }

    func testActivatingAVariantChangesWhatIsServed() {
        let mocks = Mocks()
        let rule = variantRule()
        mocks.set(rule)

        XCTAssertEqual(mocks.resolve(makeRequest("/cart"))?.outcome.response?.statusCode, 200)
        XCTAssertEqual(mocks.rule(forEndpointKey: "GET /cart")?.name, "loaded")

        mocks.activateVariant(rule.variants[2].id, forRuleID: rule.id)

        XCTAssertEqual(mocks.resolve(makeRequest("/cart"))?.outcome.response?.statusCode, 500)
        XCTAssertEqual(mocks.rule(forEndpointKey: "GET /cart")?.name, "500")
    }

    /// Switching answers rewinds the script, or a multi-step variant picked
    /// mid-session starts partway through and looks broken.
    func testActivatingAVariantRewindsTheScript() {
        let mocks = Mocks()
        var rule = MockRule(
            endpointKey: "GET /cart",
            variants: [MockVariant(name: "a", steps: [.respond(.status(200))])]
        )
        let scripted = MockVariant(
            name: "flaky",
            steps: [.fail(.offline()), .respond(.status(200))]
        )
        rule.addVariant(scripted, activate: false)
        mocks.set(rule)

        _ = mocks.resolve(makeRequest("/cart"))
        _ = mocks.resolve(makeRequest("/cart"))
        XCTAssertEqual(mocks.hitCount(forRuleID: rule.id), 2)

        mocks.activateVariant(scripted.id, forRuleID: rule.id)

        XCTAssertEqual(mocks.hitCount(forRuleID: rule.id), 0)
        XCTAssertNotNil(
            mocks.resolve(makeRequest("/cart"))?.outcome.failure,
            "the newly selected script must start at its first step"
        )
    }

    func testUnknownVariantIDLeavesTheActiveOneAlone() {
        let mocks = Mocks()
        let rule = variantRule()
        mocks.set(rule)

        mocks.activateVariant(UUID(), forRuleID: rule.id)

        XCTAssertEqual(mocks.rule(forEndpointKey: "GET /cart")?.name, "loaded")
    }

    /// A rule with no answers would claim requests and serve nothing.
    func testTheLastVariantCannotBeRemoved() {
        var rule = variantRule()
        rule.removeVariant(id: rule.variants[1].id)
        rule.removeVariant(id: rule.variants[1].id)
        XCTAssertEqual(rule.variants.count, 1)

        rule.removeVariant(id: rule.variants[0].id)
        XCTAssertEqual(rule.variants.count, 1, "the last one has to stay")
    }

    func testRemovingTheActiveVariantFallsBackRatherThanServingNothing() {
        var rule = variantRule()
        rule.activate(variantID: rule.variants[2].id)
        rule.removeVariant(id: rule.variants[2].id)

        XCTAssertNotNil(rule.outcome(forHit: 1))
        XCTAssertEqual(rule.activeVariantID, rule.variants[0].id)
    }

    /// A tester's saved rules must survive the upgrade that introduced
    /// variants, or the feature costs them their library.
    func testRuleSavedBeforeVariantsExistedStillDecodes() throws {
        let legacy = Data("""
        {"id":"\(UUID().uuidString)","endpointKey":"GET /legacy","isEnabled":true,
         "steps":[{"respond":{"_0":{"statusCode":418,"headers":{},"body":"","delay":0}}}],
         "exhaustion":"repeatLast","name":"teapot"}
        """.utf8)

        let decoded = try JSONDecoder().decode(MockRule.self, from: legacy)

        XCTAssertEqual(decoded.variants.count, 1)
        XCTAssertEqual(decoded.name, "teapot")
        XCTAssertEqual(decoded.outcome(forHit: 1)?.response?.statusCode, 418)
        XCTAssertEqual(decoded.activeVariantID, decoded.variants[0].id)
    }

    func testVariantsSurviveARoundTripWithTheirSelection() throws {
        var rule = variantRule()
        rule.activate(variantID: rule.variants[1].id)

        let decoded = try JSONDecoder().decode(
            MockRule.self, from: JSONEncoder().encode(rule)
        )

        XCTAssertEqual(decoded.variants.map(\.name), ["loaded", "empty", "500"])
        XCTAssertEqual(decoded.name, "empty")
    }

    // MARK: - Throttling

    func testSettingDelayAppliesToRespondAndFailAlike() {
        let responded = MockOutcome.respond(.json("{}")).settingDelay(1)
        XCTAssertEqual(responded.delay, 1)
        XCTAssertEqual(responded.response?.statusCode, 200, "only the latency changes")

        let failed = MockOutcome.fail(.offline()).settingDelay(2.5)
        XCTAssertEqual(failed.delay, 2.5)
        XCTAssertEqual(failed.failure?.urlError.code, .notConnectedToInternet)
    }

    /// A hang is already unbounded waiting; a delay on top of it is meaningless.
    func testSettingDelayOnAHangIsANoOp() {
        let hung = MockOutcome.hang.settingDelay(5)
        XCTAssertTrue(hung.isHang)
        XCTAssertEqual(hung.delay, 0)
    }

    func testNegativeDelayIsClampedToZero() {
        XCTAssertEqual(MockOutcome.respond(.json("{}")).settingDelay(-3).delay, 0)
    }

    /// Throttling has to survive a relaunch with the rule it belongs to.
    func testDelaySurvivesACodableRoundTrip() throws {
        let rule = MockRule(
            endpointKey: "GET /users/{id}",
            steps: [MockOutcome.respond(.json("{}")).settingDelay(1.5)]
        )
        let decoded = try JSONDecoder().decode(
            MockRule.self, from: JSONEncoder().encode(rule)
        )
        XCTAssertEqual(decoded.steps.first?.delay, 1.5)
    }

    // MARK: - Is anything fake right now

    /// Neither half answers "am I looking at real data" alone.
    func testIsServingNeedsBothTheSwitchAndAnArmedRule() {
        let mocks = Mocks()
        XCTAssertFalse(mocks.isServing, "switch on, no rules — nothing is faked")

        mocks.set(makeRule(isEnabled: false))
        XCTAssertFalse(mocks.isServing, "a disarmed rule serves nothing")

        mocks.set(makeRule(isEnabled: true))
        XCTAssertTrue(mocks.isServing)

        mocks.setMockingEnabled(false)
        XCTAssertFalse(mocks.isServing, "the master switch suspends armed rules")
    }

    func testIsServingIsPerEndpoint() {
        let mocks = Mocks()
        mocks.set(makeRule("GET /users/{id}"))
        mocks.set(makeRule("POST /orders", isEnabled: false))

        XCTAssertTrue(mocks.isServing(endpointKey: "GET /users/{id}"))
        XCTAssertFalse(mocks.isServing(endpointKey: "POST /orders"))
        XCTAssertFalse(mocks.isServing(endpointKey: "GET /unmocked"))

        mocks.setMockingEnabled(false)
        XCTAssertFalse(
            mocks.isServing(endpointKey: "GET /users/{id}"),
            "the master switch has to win over a per-endpoint rule"
        )
    }

    // MARK: - Request sample

    /// Kept with the rule so a POST mock still says what it answers, and
    /// deliberately absent from what the rule serves.
    func testRequestSampleRoundTripsAndIsNotServed() throws {
        let sample = Data(#"{"sku":"A-1","qty":2}"#.utf8)
        let rule = MockRule(
            endpointKey: "POST /orders",
            response: .json(#"{"id":9}"#),
            name: "one item",
            requestSample: sample
        )

        let decoded = try JSONDecoder().decode(
            MockRule.self, from: JSONEncoder().encode(rule)
        )
        XCTAssertEqual(decoded.requestSample, sample)

        let served = decoded.outcome(forHit: 1)?.response
        XCTAssertEqual(served?.body, Data(#"{"id":9}"#.utf8))
        XCTAssertFalse(
            served.map { String(decoding: $0.body, as: UTF8.self).contains("sku") } ?? true,
            "the sample must never appear in what the app receives"
        )
    }

    /// Rules written before the field existed still decode.
    func testRuleWithoutRequestSampleDecodes() throws {
        let json = Data("""
        {"id":"\(UUID().uuidString)","endpointKey":"GET /x","isEnabled":true,
         "steps":[{"respond":{"statusCode":200,"headers":{},"body":"","delay":0}}],
         "exhaustion":"repeatLast"}
        """.utf8)

        let decoded = try? JSONDecoder().decode(MockRule.self, from: json)
        XCTAssertNil(decoded?.requestSample)
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
