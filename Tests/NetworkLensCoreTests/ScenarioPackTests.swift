//
//  ScenarioPackTests.swift
//  NetworkLensCoreTests
//
//  Created by Rohit Sahay on 28/08/26.
//

import XCTest
@testable import NetworkLensCore

/// A pack's job is to survive leaving the device. The failures worth catching
/// are the quiet ones: a pack that carries scenarios without their rules, an
/// import that duplicates every rule because ids differ across devices, and a
/// pack that takes a real token to a repository.
final class ScenarioPackTests: XCTestCase {

    private func screen() -> (Mocks, MockRule, MockRule) {
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
        for rule in [cart, promos] { mocks.set(rule) }
        return (mocks, cart, promos)
    }

    private func packForCartEmpty() -> (ScenarioPack, Scenario) {
        let (mocks, cart, promos) = screen()
        mocks.activateVariant(cart.variants[1].id, forRuleID: cart.id)
        mocks.activateVariant(promos.variants[1].id, forRuleID: promos.id)
        let scenario = Scenario.capturing("checkout, promos down", from: mocks.all)
        let pack = ScenarioPack.exporting(
            [scenario],
            from: mocks.all,
            named: "Checkout states",
            redactedBy: nil
        )
        return (pack, scenario)
    }

    // MARK: - Export

    /// The whole reason a pack is not just the scenario file.
    func testExportCarriesTheRulesTheScenarioReferences() {
        let (pack, _) = packForCartEmpty()
        XCTAssertEqual(pack.mocks.count, 2)
        XCTAssertTrue(pack.isComplete)
        XCTAssertTrue(pack.unresolved.isEmpty)
    }

    /// A pack is read in a diff, so it carries the endpoints that matter and
    /// not the device's whole rule set.
    func testExportLeavesOutUnreferencedRules() {
        let (mocks, cart, _) = screen()
        let unrelated = MockRule(
            endpointKey: "GET /search",
            variants: [MockVariant(name: "loaded", steps: [.respond(.status(200))])]
        )
        mocks.set(unrelated)

        let cartOnly = Scenario(
            name: "cart empty",
            entries: [
                Scenario.Entry(
                    endpointKey: "GET /cart",
                    variantID: cart.variants[1].id,
                    variantName: "empty"
                )
            ]
        )
        let pack = ScenarioPack.exporting([cartOnly], from: mocks.all, named: "Cart", redactedBy: nil)

        XCTAssertEqual(pack.mocks.map(\.endpointKey), ["GET /cart"])
    }

    /// A scenario whose rule was deleted before export would apply on the other
    /// device, report success and serve live traffic. Named before the file is
    /// written, not after it is opened.
    func testUnresolvedNamesEntriesWithNoRuleInThePack() {
        let orphan = Scenario(
            name: "gone",
            entries: [
                Scenario.Entry(
                    endpointKey: "GET /deleted",
                    variantID: UUID(),
                    variantName: "empty"
                )
            ]
        )
        let pack = ScenarioPack.exporting([orphan], from: [], named: "Broken", redactedBy: nil)

        XCTAssertFalse(pack.isComplete)
        XCTAssertEqual(pack.unresolved.map(\.endpointKey), ["GET /deleted"])
    }

    // MARK: - Round trip

    func testPackSurvivesEncodingAndDecoding() throws {
        let (pack, _) = packForCartEmpty()
        let decoded = try ScenarioPack.decoding(try pack.encoded())

        XCTAssertEqual(decoded.name, pack.name)
        XCTAssertEqual(decoded.scenarios, pack.scenarios)
        XCTAssertEqual(decoded.mocks.map(\.endpointKey).sorted(), pack.mocks.map(\.endpointKey).sorted())
    }

    func testPackFromANewerFormatIsRefusedRatherThanHalfRead() throws {
        var (pack, _) = packForCartEmpty()
        pack.formatVersion = ScenarioPack.currentFormatVersion + 1
        let data = try pack.encoded()

        XCTAssertThrowsError(try ScenarioPack.decoding(data)) { error in
            XCTAssertEqual(
                error as? ScenarioPack.PackError,
                .unsupportedFormat(
                    found: ScenarioPack.currentFormatVersion + 1,
                    supported: ScenarioPack.currentFormatVersion
                )
            )
        }
    }

    // MARK: - Import

    /// The receiving device is empty — the QA case.
    func testImportIntoAnEmptyDeviceAppliesTheScenario() throws {
        let (pack, scenario) = packForCartEmpty()
        let mocks = Mocks()
        let scenarios = Scenarios()

        let outcome = pack.import(into: mocks, scenarios: scenarios)

        XCTAssertEqual(outcome.addedRules, 2)
        XCTAssertEqual(outcome.replacedRules, 0)
        XCTAssertEqual(outcome.addedScenarios, 1)
        XCTAssertTrue(outcome.isComplete)

        let applied = scenarios.apply(scenario, to: mocks)
        XCTAssertTrue(applied.isComplete)
        XCTAssertEqual(mocks.rule(forEndpointKey: "GET /cart")?.name, "empty")
        XCTAssertEqual(mocks.rule(forEndpointKey: "GET /promos")?.name, "down")
    }

    /// Rule identity across devices is endpoint key plus match, never the id.
    /// Matching on ids would duplicate every rule on every import.
    func testImportReplacesByEndpointRatherThanById() {
        let (pack, _) = packForCartEmpty()
        let mocks = Mocks()
        mocks.set(
            MockRule(
                endpointKey: "GET /cart",
                variants: [MockVariant(name: "local", steps: [.respond(.status(204))])]
            )
        )

        let outcome = pack.import(into: mocks, scenarios: Scenarios())

        XCTAssertEqual(mocks.all.filter { $0.endpointKey == "GET /cart" }.count, 1)
        XCTAssertEqual(outcome.replacedRules, 1)
        XCTAssertEqual(outcome.addedRules, 1)
    }

    /// Overwriting is the right default — a known state is being reproduced —
    /// but it must never be silent.
    func testImportReportsWhatItOverwrote() {
        let (pack, _) = packForCartEmpty()
        let mocks = Mocks()
        let scenarios = Scenarios()
        pack.import(into: mocks, scenarios: scenarios)

        let second = pack.import(into: mocks, scenarios: scenarios)

        XCTAssertEqual(second.addedRules, 0)
        XCTAssertEqual(second.replacedRules, 2)
        XCTAssertEqual(second.replacedScenarios, 1)
    }

    func testImportedScenarioResolvesByIdNotOnlyByName() {
        let (pack, scenario) = packForCartEmpty()
        let mocks = Mocks()
        let scenarios = Scenarios()
        pack.import(into: mocks, scenarios: scenarios)

        // Rebuilt with the same variant ids under different names, which is
        // what an edit on the receiving device looks like. Only the ids are
        // left to match on.
        for rule in mocks.all {
            let renamed = rule.variants.map { variant in
                MockVariant(id: variant.id, name: "renamed-\(variant.name)", steps: variant.steps)
            }
            mocks.set(
                MockRule(
                    id: rule.id,
                    endpointKey: rule.endpointKey,
                    variants: renamed,
                    activeVariantID: rule.activeVariantID,
                    isEnabled: rule.isEnabled,
                    match: rule.match
                )
            )
        }

        XCTAssertTrue(scenarios.apply(scenario, to: mocks).isComplete)
    }

    // MARK: - Grouping

    /// A tester gets several packs at once, and three of them each contain an
    /// "everything empty". Without the group the list is unreadable and picking
    /// the wrong row silently tests the wrong screen.
    func testImportStampsThePackNameOnEveryScenario() {
        let (pack, _) = packForCartEmpty()
        let scenarios = Scenarios()

        pack.import(into: Mocks(), scenarios: scenarios)

        XCTAssertEqual(scenarios.all.map(\.group), ["Checkout states"])
    }

    /// Renaming a pack on disk regroups it rather than leaving two groups that
    /// are really one, which is why the group is stamped and not stored.
    func testReimportingUnderANewNameRegroups() {
        let (mocks, cart, promos) = screen()
        mocks.activateVariant(cart.variants[1].id, forRuleID: cart.id)
        mocks.activateVariant(promos.variants[1].id, forRuleID: promos.id)
        let scenario = Scenario.capturing("checkout, promos down", from: mocks.all)
        let scenarios = Scenarios()

        ScenarioPack.exporting([scenario], from: mocks.all, named: "Old name", redactedBy: nil)
            .import(into: Mocks(), scenarios: scenarios)
        ScenarioPack.exporting([scenario], from: mocks.all, named: "New name", redactedBy: nil)
            .import(into: Mocks(), scenarios: scenarios)

        XCTAssertEqual(scenarios.all.count, 1)
        XCTAssertEqual(scenarios.all.first?.group, "New name")
    }

    /// A scenario saved before packs existed has no group and must still load.
    func testScenarioWithoutAGroupStillDecodes() throws {
        let json = #"{"id":"\#(UUID().uuidString)","name":"legacy","entries":[],"createdAt":0}"#
        let decoded = try JSONDecoder().decode(Scenario.self, from: Data(json.utf8))
        XCTAssertNil(decoded.group)
    }

    // MARK: - Redaction

    /// A pack goes to a repository, a ticket, a chat thread. The default has to
    /// be the safe one.
    func testExportRedactsByDefault() {
        let mocks = Mocks()
        mocks.set(
            MockRule(
                endpointKey: "GET /profile",
                variants: [
                    MockVariant(
                        name: "loaded",
                        steps: [.respond(.json(#"{"accessToken":"secret-value"}"#))]
                    )
                ]
            )
        )
        let scenario = Scenario.capturing("profile", from: mocks.all)

        let pack = ScenarioPack.exporting([scenario], from: mocks.all, named: "Profile")

        // Read the body back rather than grepping the file: response bodies are
        // base64 in JSON, so a substring search over the encoded pack passes
        // whether or not anything was actually redacted.
        XCTAssertFalse(Self.bodyText(of: pack).contains("secret-value"))
    }

    func testRedactionCanBeOptedOut() {
        let mocks = Mocks()
        mocks.set(
            MockRule(
                endpointKey: "GET /profile",
                variants: [
                    MockVariant(
                        name: "loaded",
                        steps: [.respond(.json(#"{"accessToken":"secret-value"}"#))]
                    )
                ]
            )
        )
        let scenario = Scenario.capturing("profile", from: mocks.all)

        let pack = ScenarioPack.exporting([scenario], from: mocks.all, named: "Profile", redactedBy: nil)

        XCTAssertTrue(Self.bodyText(of: pack).contains("secret-value"))
    }

    /// Every response body in the pack, as text.
    private static func bodyText(of pack: ScenarioPack) -> String {
        pack.mocks
            .flatMap(\.variants)
            .flatMap(\.steps)
            .compactMap { $0.response }
            .map { String(data: $0.body, encoding: .utf8) ?? "" }
            .joined(separator: "\n")
    }

    // MARK: - File name

    func testSuggestedFileNameIsSafeForAFileSystem() {
        let pack = ScenarioPack(name: "Checkout: promos/down", scenarios: [], mocks: [])
        XCTAssertEqual(pack.suggestedFileName, "Checkout promosdown.networklens-pack.json")
    }

    func testSuggestedFileNameFallsBackWhenTheNameIsUnusable() {
        let pack = ScenarioPack(name: "///", scenarios: [], mocks: [])
        XCTAssertEqual(pack.suggestedFileName, "scenarios.networklens-pack.json")
    }
}
