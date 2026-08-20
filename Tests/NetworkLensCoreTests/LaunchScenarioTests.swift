//
//  LaunchScenarioTests.swift
//  NetworkLensCoreTests
//
//  Created by Rohit Sahay on 20/08/26.
//

import XCTest
@testable import NetworkLensCore

/// The bridge out of the app. Everything else in the package assumes a human is
/// holding the device; a UI test has nobody, so the setup has to arrive from
/// outside the process.
final class LaunchOptionParsingTests: XCTestCase {

    func testReadsTheSeparatedForm() {
        XCTAssertEqual(
            LensLaunchOptions.scenarioName(
                arguments: ["App", "-NetworkLensScenario", "cart empty"], environment: [:]
            ),
            "cart empty"
        )
    }

    /// Xcode's "Arguments Passed On Launch" is one argument per row; a person
    /// typing into a terminal reaches for the joined form. Supporting one and
    /// not the other is a silent no-op.
    func testReadsTheJoinedForm() {
        XCTAssertEqual(
            LensLaunchOptions.scenarioName(
                arguments: ["App", "-NetworkLensScenario=cart empty"], environment: [:]
            ),
            "cart empty"
        )
    }

    func testReadsTheEnvironment() {
        XCTAssertEqual(
            LensLaunchOptions.scenarioName(
                arguments: ["App"], environment: ["NETWORKLENS_SCENARIO": "checkout"]
            ),
            "checkout"
        )
    }

    /// The environment is set once for the scheme; an argument is what a single
    /// run overrides it with.
    func testAnArgumentBeatsTheEnvironment() {
        XCTAssertEqual(
            LensLaunchOptions.scenarioName(
                arguments: ["App", "-NetworkLensScenario", "cart empty"],
                environment: ["NETWORKLENS_SCENARIO": "checkout"]
            ),
            "cart empty"
        )
    }

    /// `-NetworkLensScenario -SomeOtherFlag` names nothing. Swallowing the next
    /// flag as a value would apply a scenario nobody asked for.
    func testAFlagIsNotTakenAsAValue() {
        XCTAssertNil(
            LensLaunchOptions.scenarioName(
                arguments: ["App", "-NetworkLensScenario", "-OtherFlag"], environment: [:]
            )
        )
    }

    func testATrailingFlagWithNoValueNamesNothing() {
        XCTAssertNil(
            LensLaunchOptions.scenarioName(
                arguments: ["App", "-NetworkLensScenario"], environment: [:]
            )
        )
    }

    func testBlankAndWhitespaceNamesAreNotNames() {
        XCTAssertNil(
            LensLaunchOptions.scenarioName(
                arguments: ["App", "-NetworkLensScenario", "   "], environment: [:]
            )
        )
        XCTAssertNil(
            LensLaunchOptions.scenarioName(arguments: ["App"], environment: [:])
        )
    }

    func testNoOptionIsNoOpinion() {
        XCTAssertNil(LensLaunchOptions.scenarioName(arguments: ["App"], environment: [:]))
    }
}

final class ApplyScenarioByNameTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Mocks.shared.removeAll()
        Mocks.shared.setMockingEnabled(true)
        Scenarios.shared.replaceAll([])
    }

    override func tearDown() {
        Mocks.shared.removeAll()
        Mocks.shared.setMockingEnabled(true)
        Scenarios.shared.replaceAll([])
        super.tearDown()
    }

    /// Two variants on one endpoint, with the *second* saved into the scenario,
    /// so applying it has something to actually change.
    private func armEndpointWithTwoVariants() -> (rule: MockRule, empty: MockVariant) {
        let loaded = MockVariant(name: "loaded", steps: [.respond(.json(#"{"items":[1,2]}"#))])
        let empty = MockVariant(name: "empty", steps: [.respond(.json(#"{"items":[]}"#))])
        let rule = MockRule(
            endpointKey: "GET /cart",
            variants: [loaded, empty],
            activeVariantID: loaded.id
        )
        Mocks.shared.set(rule)
        return (rule, empty)
    }

    func testAppliesASavedScenarioByName() throws {
        let (rule, empty) = armEndpointWithTwoVariants()
        Mocks.shared.activateVariant(empty.id, forRuleID: rule.id)
        Scenarios.shared.save(Scenario.capturing("cart empty", from: Mocks.shared.all))

        // Put it back on the other variant so applying has work to do.
        let loadedID = try XCTUnwrap(rule.variants.first?.id)
        Mocks.shared.activateVariant(loadedID, forRuleID: rule.id)

        let activation = NetworkLens.applyScenario(named: "cart empty")

        XCTAssertTrue(activation.isApplied)
        XCTAssertEqual(
            Mocks.shared.rule(forEndpointKey: "GET /cart")?.activeVariantID,
            empty.id
        )
    }

    /// A name arriving from a scheme carries whatever casing and whitespace the
    /// person typed. A lookup that misses for either reason reads as the
    /// scenario having been lost.
    func testNameMatchingIgnoresCaseAndSurroundingSpace() {
        _ = armEndpointWithTwoVariants()
        Scenarios.shared.save(Scenario.capturing("Cart Empty", from: Mocks.shared.all))

        XCTAssertTrue(NetworkLens.applyScenario(named: "  cart empty  ").isApplied)
    }

    /// The case that matters most. A test that asks for a scenario, silently
    /// gets live traffic and passes anyway reports green about a state it never
    /// entered.
    func testAMissingNameReportsTheNamesThatExist() {
        _ = armEndpointWithTwoVariants()
        Scenarios.shared.save(Scenario.capturing("checkout", from: Mocks.shared.all))

        let activation = NetworkLens.applyScenario(named: "cart empty")

        XCTAssertFalse(activation.isApplied)
        XCTAssertEqual(
            activation,
            .noSuchScenario(name: "cart empty", available: ["checkout"])
        )
        XCTAssertTrue(activation.summary.contains("checkout"))
    }

    /// The likeliest real failure: persistence is off, so nothing was restored
    /// and there is nothing to name. Says that, rather than listing nothing.
    func testAnEmptyStoreSaysPersistenceIsWhyNothingMatched() {
        let activation = NetworkLens.applyScenario(named: "cart empty")

        XCTAssertFalse(activation.isApplied)
        XCTAssertTrue(
            activation.summary.lowercased().contains("persistence"),
            "an empty store is nearly always persistence being off — say so"
        )
    }
}
