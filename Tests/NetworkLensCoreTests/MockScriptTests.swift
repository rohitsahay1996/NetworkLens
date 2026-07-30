import XCTest
@testable import NetworkLensCore

/// Per-hit scripts and the exhaustion policies that govern their tail.
final class MockScriptTests: XCTestCase {

    private func makeRequest(_ path: String = "/users/1") -> URLRequest {
        URLRequest(url: URL(string: "https://api.test\(path)")!)
    }

    private let script: [MockOutcome] = [
        .fail(.offline()),
        .respond(.status(500)),
        .respond(.status(200))
    ]

    // MARK: - Step selection

    func testStepsArePlayedOneHitAtATime() {
        let rule = MockRule(endpointKey: "GET /users/{id}", steps: script)

        XCTAssertEqual(rule.outcome(forHit: 1)?.failure?.errorCode, URLError.notConnectedToInternet.rawValue)
        XCTAssertEqual(rule.outcome(forHit: 2)?.response?.statusCode, 500)
        XCTAssertEqual(rule.outcome(forHit: 3)?.response?.statusCode, 200)
    }

    func testRepeatLastServesTheFinalStepForever() {
        let rule = MockRule(endpointKey: "GET /x", steps: script, exhaustion: .repeatLast)

        XCTAssertEqual(rule.outcome(forHit: 4)?.response?.statusCode, 200)
        XCTAssertEqual(rule.outcome(forHit: 400)?.response?.statusCode, 200)
    }

    func testLoopStartsTheScriptOver() {
        let rule = MockRule(endpointKey: "GET /x", steps: script, exhaustion: .loop)

        XCTAssertNotNil(rule.outcome(forHit: 4)?.failure)
        XCTAssertEqual(rule.outcome(forHit: 5)?.response?.statusCode, 500)
        XCTAssertEqual(rule.outcome(forHit: 6)?.response?.statusCode, 200)
        XCTAssertNotNil(rule.outcome(forHit: 7)?.failure)
    }

    func testPassThroughStandsDownOnceTheScriptIsSpent() {
        let rule = MockRule(endpointKey: "GET /x", steps: script, exhaustion: .passThrough)

        XCTAssertNotNil(rule.outcome(forHit: 3))
        XCTAssertNil(rule.outcome(forHit: 4))
    }

    /// A rule with no steps would answer nothing on every hit, which presents
    /// as a broken tool rather than as an empty script.
    func testEmptyScriptIsBackfilledWithADefaultResponse() {
        let rule = MockRule(endpointKey: "GET /x", steps: [])

        XCTAssertEqual(rule.steps.count, 1)
        XCTAssertEqual(rule.outcome(forHit: 1)?.response?.statusCode, 200)
    }

    func testSingleStepRuleIsNotReportedAsScripted() {
        XCTAssertFalse(MockRule(endpointKey: "GET /x", response: .status(200)).isScripted)
        XCTAssertTrue(MockRule(endpointKey: "GET /x", steps: script).isScripted)
    }

    // MARK: - Resolution

    func testResolveWalksTheScriptInOrder() {
        let mocks = Mocks()
        mocks.set(MockRule(endpointKey: "GET /users/{id}", steps: script))

        XCTAssertNotNil(mocks.resolve(makeRequest())?.failure)
        XCTAssertEqual(mocks.resolve(makeRequest())?.response?.statusCode, 500)
        XCTAssertEqual(mocks.resolve(makeRequest())?.response?.statusCode, 200)
        XCTAssertEqual(mocks.resolve(makeRequest())?.response?.statusCode, 200)
    }

    func testResolveReturnsNilOnceAPassThroughScriptIsSpent() {
        let mocks = Mocks()
        let rule = MockRule(
            endpointKey: "GET /users/{id}",
            steps: [.fail(.offline()), .fail(.offline())],
            exhaustion: .passThrough
        )
        mocks.set(rule)

        XCTAssertNotNil(mocks.resolve(makeRequest()))
        XCTAssertNotNil(mocks.resolve(makeRequest()))
        XCTAssertNil(mocks.resolve(makeRequest()))
        XCTAssertNil(mocks.resolve(makeRequest()))
    }

    /// The count has to park at the end of the script. If a passed-through
    /// request kept incrementing, nothing would break today — but the count is
    /// what the rule list reports as "times served", and it would be lying.
    func testPassedThroughRequestsAreNotCounted() {
        let mocks = Mocks()
        let rule = MockRule(
            endpointKey: "GET /users/{id}",
            steps: [.respond(.status(200))],
            exhaustion: .passThrough
        )
        mocks.set(rule)

        _ = mocks.resolve(makeRequest())
        _ = mocks.resolve(makeRequest())
        _ = mocks.resolve(makeRequest())

        XCTAssertEqual(mocks.hitCount(forRuleID: rule.id), 1)
    }

    func testResetHitCountsRewindsTheScript() {
        let mocks = Mocks()
        mocks.set(MockRule(endpointKey: "GET /users/{id}", steps: script))

        _ = mocks.resolve(makeRequest())
        _ = mocks.resolve(makeRequest())
        mocks.resetHitCounts()

        XCTAssertNotNil(mocks.resolve(makeRequest())?.failure, "reset should replay from step 1")
    }

    // MARK: - Failures

    func testPresetsCarryTheURLErrorTheAppWouldSee() {
        XCTAssertEqual(MockFailure.offline().urlError.code, .notConnectedToInternet)
        XCTAssertEqual(MockFailure.timedOut().urlError.code, .timedOut)
        XCTAssertEqual(MockFailure.connectionLost().urlError.code, .networkConnectionLost)
        XCTAssertEqual(MockFailure.cannotFindHost().urlError.code, .cannotFindHost)
        XCTAssertEqual(MockFailure.secureConnectionFailed().urlError.code, .secureConnectionFailed)
    }

    func testOutcomeDelayReadsFromWhicheverKindItIs() {
        XCTAssertEqual(MockOutcome.respond(.status(200, delay: 1.5)).delay, 1.5)
        XCTAssertEqual(MockOutcome.fail(.offline(delay: 2.5)).delay, 2.5)
    }

    // MARK: - Codable

    func testRuleSurvivesARoundTripThroughJSON() throws {
        let rule = MockRule(
            endpointKey: "GET /users/{id}",
            steps: script,
            exhaustion: .loop,
            name: "flaky user"
        )

        let data = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(MockRule.self, from: data)

        XCTAssertEqual(decoded, rule)
        XCTAssertEqual(decoded.outcome(forHit: 2)?.response?.statusCode, 500)
    }
}
