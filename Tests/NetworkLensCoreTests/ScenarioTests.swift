//
//  ScenarioTests.swift
//  NetworkLensCoreTests
//
//  Created by Rohit Sahay on 30/07/26.
//

import XCTest
@testable import NetworkLensCore

/// A screen's worth of endpoints, switched together.
final class ScenarioTests: XCTestCase {

    private func screenRules() -> (Mocks, MockRule, MockRule, MockRule) {
        let mocks = Mocks()

        let cart = MockRule(
            endpointKey: "GET /cart",
            variants: [
                MockVariant(name: "loaded", steps: [.respond(.json(#"{"items":[1]}"#))]),
                MockVariant(name: "empty", steps: [.respond(.json(#"{"items":[]}"#))]),
            ]
        )
        let promos = MockRule(
            endpointKey: "GET /promos",
            variants: [
                MockVariant(name: "loaded", steps: [.respond(.status(200))]),
                MockVariant(name: "down", steps: [.respond(.status(500))]),
            ]
        )
        let profile = MockRule(
            endpointKey: "GET /profile",
            variants: [MockVariant(name: "loaded", steps: [.respond(.status(200))])]
        )

        for rule in [cart, promos, profile] { mocks.set(rule) }
        return (mocks, cart, promos, profile)
    }

    // MARK: - Capture and apply

    /// The combination is the unit: cart empty *while* promos are down.
    func testApplyingASetupSwitchesEveryEndpointAtOnce() {
        let (mocks, cart, promos, _) = screenRules()

        mocks.activateVariant(cart.variants[1].id, forRuleID: cart.id)
        mocks.activateVariant(promos.variants[1].id, forRuleID: promos.id)
        let saved = Scenario.capturing("checkout, promos down", from: mocks.all)

        // Back to the default setup by hand.
        mocks.activateVariant(cart.variants[0].id, forRuleID: cart.id)
        mocks.activateVariant(promos.variants[0].id, forRuleID: promos.id)
        XCTAssertEqual(mocks.rule(forEndpointKey: "GET /cart")?.name, "loaded")

        let scenarios = Scenarios()
        let outcome = scenarios.apply(saved, to: mocks)

        XCTAssertTrue(outcome.isComplete)
        XCTAssertEqual(outcome.applied, 3)
        XCTAssertEqual(mocks.rule(forEndpointKey: "GET /cart")?.name, "empty")
        XCTAssertEqual(mocks.rule(forEndpointKey: "GET /promos")?.name, "down")
        XCTAssertEqual(mocks.rule(forEndpointKey: "GET /profile")?.name, "loaded")
    }

    /// "Everything mocked except search" needs a scenario to be able to turn a
    /// rule off, not only to pick a variant.
    func testScenarioCarriesTheEnabledStateOfEachRule() {
        let (mocks, cart, _, _) = screenRules()
        var disabled = try! XCTUnwrap(mocks.rule(forEndpointKey: "GET /cart"))
        disabled.isEnabled = false
        mocks.set(disabled)

        let saved = Scenario.capturing("cart live", from: mocks.all)

        var reenabled = try! XCTUnwrap(mocks.rule(forEndpointKey: "GET /cart"))
        reenabled.isEnabled = true
        mocks.set(reenabled)

        Scenarios().apply(saved, to: mocks)

        XCTAssertEqual(mocks.rule(forEndpointKey: "GET /cart")?.isEnabled, false)
        XCTAssertEqual(cart.endpointKey, "GET /cart")
    }

    /// Only the endpoints a screen actually hit.
    func testCapturingCanBeLimitedToOneScreensEndpoints() {
        let (mocks, _, _, _) = screenRules()

        let saved = Scenario.capturing(
            "cart only", from: mocks.all, limitedTo: ["GET /cart", "GET /promos"]
        )

        XCTAssertEqual(saved.entries.count, 2)
        XCTAssertEqual(Set(saved.entries.map(\.endpointKey)), ["GET /cart", "GET /promos"])
    }

    // MARK: - Honest reporting

    /// Rules get deleted. A scenario that quietly applies half of itself is
    /// indistinguishable from a broken one.
    func testMissingEndpointsAreReportedRatherThanSwallowed() {
        let (mocks, cart, _, _) = screenRules()
        mocks.activateVariant(cart.variants[1].id, forRuleID: cart.id)
        let saved = Scenario.capturing("checkout", from: mocks.all)

        mocks.remove(id: cart.id)
        let outcome = Scenarios().apply(saved, to: mocks)

        XCTAssertFalse(outcome.isComplete)
        XCTAssertEqual(outcome.applied, 2)
        XCTAssertEqual(outcome.missing.map(\.endpointKey), ["GET /cart"])
    }

    /// Ids do not survive a rule being rebuilt; the names a tester chose do.
    func testVariantIsFoundByNameWhenItsIDHasChanged() {
        let (mocks, cart, _, _) = screenRules()
        mocks.activateVariant(cart.variants[1].id, forRuleID: cart.id)
        let saved = Scenario.capturing("checkout", from: mocks.all)

        // Same endpoint and names, all-new ids — a re-imported rule.
        mocks.remove(id: cart.id)
        mocks.set(
            MockRule(
                endpointKey: "GET /cart",
                variants: [
                    MockVariant(name: "loaded", steps: [.respond(.status(200))]),
                    MockVariant(name: "empty", steps: [.respond(.status(204))]),
                ]
            )
        )

        let outcome = Scenarios().apply(saved, to: mocks)

        XCTAssertTrue(outcome.isComplete)
        XCTAssertEqual(mocks.rule(forEndpointKey: "GET /cart")?.name, "empty")
    }

    // MARK: - The applied label

    func testAppliedIsReportedWhileTheRulesStillMatch() {
        let (mocks, cart, _, _) = screenRules()
        mocks.activateVariant(cart.variants[1].id, forRuleID: cart.id)
        let saved = Scenario.capturing("checkout", from: mocks.all)

        let scenarios = Scenarios()
        scenarios.save(saved)
        scenarios.apply(saved, to: mocks)

        XCTAssertEqual(scenarios.applied(in: mocks)?.name, "checkout")
    }

    /// The label must not outlive the setup it names.
    func testSwitchingOneEndpointByHandClearsTheAppliedLabel() {
        let (mocks, cart, _, _) = screenRules()
        mocks.activateVariant(cart.variants[1].id, forRuleID: cart.id)
        let saved = Scenario.capturing("checkout", from: mocks.all)

        let scenarios = Scenarios()
        scenarios.save(saved)
        scenarios.apply(saved, to: mocks)

        mocks.activateVariant(cart.variants[0].id, forRuleID: cart.id)

        XCTAssertNil(
            scenarios.applied(in: mocks),
            "a label claiming a setup that is no longer in force misdescribes the app"
        )
    }

    // MARK: - Storage

    func testSavingTheSameNameUpdatesRatherThanDuplicating() {
        let scenarios = Scenarios()
        scenarios.save(Scenario(name: "checkout", entries: []))
        scenarios.save(
            Scenario(
                name: "checkout",
                entries: [
                    .init(endpointKey: "GET /cart", variantID: UUID(), variantName: "empty")
                ]
            )
        )

        XCTAssertEqual(scenarios.all.count, 1)
        XCTAssertEqual(scenarios.all.first?.entries.count, 1)
    }

    /// Scenarios are the work and are kept; having one silently back in force
    /// at launch is the forgotten-breakpoint trap again.
    func testNothingIsAppliedAfterARelaunch() {
        let (mocks, cart, _, _) = screenRules()
        mocks.activateVariant(cart.variants[1].id, forRuleID: cart.id)
        let saved = Scenario.capturing("checkout", from: mocks.all)

        let scenarios = Scenarios()
        scenarios.save(saved)
        scenarios.apply(saved, to: mocks)
        scenarios.clearAppliedForRelaunch()

        XCTAssertNil(scenarios.applied(in: mocks))
        XCTAssertEqual(scenarios.all.count, 1, "the scenario itself survives")
    }

    func testScenariosRoundTripThroughASnapshot() throws {
        let scenario = Scenario(
            name: "checkout",
            entries: [
                .init(
                    endpointKey: "GET /cart",
                    match: MockMatch(query: ["page": "2"]),
                    variantID: UUID(),
                    variantName: "empty",
                    isEnabled: true
                )
            ]
        )

        let decoded = try JSONDecoder().decode(
            LensSnapshot.self,
            from: JSONEncoder().encode(LensSnapshot(scenarios: [scenario]))
        )

        XCTAssertEqual(decoded.scenarios.first?.name, "checkout")
        XCTAssertEqual(decoded.scenarios.first?.entries.first?.match.query, ["page": "2"])
    }

    /// A snapshot written before scenarios existed still restores.
    func testSnapshotWithoutScenariosStillDecodes() throws {
        let legacy = Data(#"{"mocks":[],"breakpoints":[],"perturbations":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(LensSnapshot.self, from: legacy)

        XCTAssertTrue(decoded.scenarios.isEmpty)
        XCTAssertTrue(decoded.isMockingEnabled, "an absent flag must not read as off")
    }
}
