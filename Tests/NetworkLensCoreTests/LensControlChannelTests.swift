//
//  LensControlChannelTests.swift
//  NetworkLensCoreTests
//
//  Created by Rohit Sahay on 30/08/26.
//

import XCTest
@testable import NetworkLensCore

final class LensControlChannelTests: XCTestCase {

    private let endpointKey = "GET /cart"
    private var channel = LensControlChannel()

    /// `Mocks` is a process-wide singleton and its master switch defaults to on.
    /// A suite that leaves it off silently stops every other suite's mocks from serving.
    private var wasMockingEnabled = true

    override func setUp() {
        super.setUp()
        channel = LensControlChannel()
        wasMockingEnabled = Mocks.shared.isMockingEnabled
        Mocks.shared.removeAll()
        Mocks.shared.setMockingEnabled(false)
        Scenarios.shared.removeAll()
    }

    override func tearDown() {
        channel.stop()
        Mocks.shared.removeAll()
        Mocks.shared.setMockingEnabled(wasMockingEnabled)
        Scenarios.shared.removeAll()
        super.tearDown()
    }

    private func command(
        _ kind: String,
        endpointKey: String? = nil,
        variantName: String? = nil,
        body: String? = nil
    ) -> ControlCommand {
        var command = ControlCommand(id: 1, kind: kind)
        command.endpointKey = endpointKey
        command.variantName = variantName
        command.body = body
        return command
    }

    // MARK: - Wire shape

    /// The sidecar's queue is written by the browser lens's own MCP server, so a
    /// command carrying fields iOS has no use for must still decode.
    func testDecodesTheBrowserLensWireShape() throws {
        let json = """
        {"id":7,"kind":"arm","endpointKey":"GET /cart","variantName":"empty","status":200,"body":"{}","delay":0.5}
        """
        let decoded = try JSONDecoder().decode(ControlCommand.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.id, 7)
        XCTAssertEqual(decoded.kind, "arm")
        XCTAssertEqual(decoded.endpointKey, "GET /cart")
        XCTAssertEqual(decoded.variantName, "empty")
        XCTAssertEqual(decoded.delay, 0.5)
    }

    // MARK: - Verbs

    func testArmCreatesARuleAndTurnsMockingOn() throws {
        let outcome = try channel.apply(command("arm", endpointKey: endpointKey, variantName: "empty", body: "{}"))
        XCTAssertEqual(outcome.rules?.count, 1)
        XCTAssertEqual(outcome.isMockingEnabled, true)
        XCTAssertTrue(Mocks.shared.isMockingEnabled)
        let rule = try XCTUnwrap(Mocks.shared.rule(forEndpointKey: endpointKey))
        XCTAssertEqual(rule.activeVariant.name, "empty")
    }

    /// An existing rule is someone's work, so a second arm adds a variant rather
    /// than replacing what is already there.
    func testArmingTwiceKeepsBothVariants() throws {
        _ = try channel.apply(command("arm", endpointKey: endpointKey, variantName: "empty", body: "{}"))
        _ = try channel.apply(command("arm", endpointKey: endpointKey, variantName: "500", body: "{}"))
        let rule = try XCTUnwrap(Mocks.shared.rule(forEndpointKey: endpointKey))
        XCTAssertEqual(rule.variants.count, 2)
        XCTAssertEqual(rule.activeVariant.name, "500")
    }

    func testArmWithoutAnEndpointKeyReports() {
        XCTAssertThrowsError(try channel.apply(command("arm")))
    }

    func testVariantActivatesByName() throws {
        _ = try channel.apply(command("arm", endpointKey: endpointKey, variantName: "empty", body: "{}"))
        _ = try channel.apply(command("arm", endpointKey: endpointKey, variantName: "500", body: "{}"))
        _ = try channel.apply(command("variant", endpointKey: endpointKey, variantName: "empty"))
        let rule = try XCTUnwrap(Mocks.shared.rule(forEndpointKey: endpointKey))
        XCTAssertEqual(rule.activeVariant.name, "empty")
    }

    /// The name it was asked for and the names that exist both reach the agent,
    /// because a bare failure sends it guessing.
    func testUnknownVariantNamesWhatIsAvailable() throws {
        _ = try channel.apply(command("arm", endpointKey: endpointKey, variantName: "empty", body: "{}"))
        XCTAssertThrowsError(try channel.apply(command("variant", endpointKey: endpointKey, variantName: "nope"))) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("nope"))
            XCTAssertTrue(message.contains("empty"))
        }
    }

    func testVariantOnAnUnarmedEndpointReports() {
        XCTAssertThrowsError(try channel.apply(command("variant", endpointKey: endpointKey, variantName: "empty")))
    }

    /// Disable rather than remove, so the variants survive for the next arm.
    func testDisarmKeepsTheRule() throws {
        _ = try channel.apply(command("arm", endpointKey: endpointKey, variantName: "empty", body: "{}"))
        _ = try channel.apply(command("disarm", endpointKey: endpointKey))
        let rule = try XCTUnwrap(Mocks.shared.rule(forEndpointKey: endpointKey))
        XCTAssertFalse(rule.isEnabled)
        XCTAssertEqual(rule.variants.count, 1)
    }

    func testDisarmWithoutAnEndpointKeyDisablesEverything() throws {
        _ = try channel.apply(command("arm", endpointKey: "GET /cart", variantName: "empty", body: "{}"))
        _ = try channel.apply(command("arm", endpointKey: "GET /orders", variantName: "empty", body: "{}"))
        _ = try channel.apply(command("disarm"))
        XCTAssertTrue(Mocks.shared.all.allSatisfy { !$0.isEnabled })
    }

    func testStateReportsWhatIsArmed() throws {
        _ = try channel.apply(command("arm", endpointKey: endpointKey, variantName: "empty", body: "{}"))
        let outcome = try channel.apply(command("state"))
        XCTAssertEqual(outcome.rules?.count, 1)
        XCTAssertEqual(outcome.isMockingEnabled, true)
        XCTAssertNotNil(outcome.breakpoints)
    }

    func testExportCarriesTheArmedRules() throws {
        _ = try channel.apply(command("arm", endpointKey: endpointKey, variantName: "empty", body: "{}"))
        let outcome = try channel.apply(command("export"))
        XCTAssertNotNil(outcome.pack)
    }

    func testUnknownCommandReportsItsName() {
        XCTAssertThrowsError(try channel.apply(command("teleport"))) { error in
            XCTAssertTrue("\(error)".contains("teleport"))
        }
    }

    // MARK: - Edit

    private func rule(_ endpointKey: String, variants: [String]) -> MockRule {
        let built = variants.map { MockVariant(name: $0, steps: [.respond(MockResponse())]) }
        return MockRule(endpointKey: endpointKey, variants: built)
    }

    private func editCommand(
        rules: [MockRule]? = nil,
        removeEndpointKeys: [String]? = nil,
        isMockingEnabled: Bool? = nil
    ) -> ControlCommand {
        var command = ControlCommand(id: 1, kind: "edit")
        command.rules = rules
        command.removeEndpointKeys = removeEndpointKeys
        command.isMockingEnabled = isMockingEnabled
        return command
    }

    /// The MCP server reads the trace and builds the whole variant set, so the
    /// wire has to carry a finished rule rather than one field at a time.
    func testEditInstallsAWholeRule() throws {
        let built = rule(endpointKey, variants: ["loaded", "empty", "500", "slow"])
        let outcome = try channel.apply(editCommand(rules: [built], isMockingEnabled: true))
        XCTAssertEqual(outcome.upsertedCount, 1)
        let stored = try XCTUnwrap(Mocks.shared.rule(forEndpointKey: endpointKey))
        XCTAssertEqual(stored.variants.map { $0.name }, ["loaded", "empty", "500", "slow"])
        XCTAssertTrue(Mocks.shared.isMockingEnabled)
    }

    /// Matched loosely because the caller's picture of what is armed can be older than the app's.
    func testEditRemovesBySubstring() throws {
        _ = try channel.apply(editCommand(rules: [rule("GET /flashsale/v2/products", variants: ["loaded"])]))
        let outcome = try channel.apply(editCommand(removeEndpointKeys: ["flashsale"]))
        XCTAssertEqual(outcome.removedCount, 1)
        XCTAssertTrue(Mocks.shared.all.isEmpty)
    }

    /// A caller replacing a rule sends both halves; removing second would delete what it just wrote.
    func testEditRemovesBeforeItWrites() throws {
        _ = try channel.apply(editCommand(rules: [rule(endpointKey, variants: ["old"])]))
        let replacement = rule(endpointKey, variants: ["new"])
        _ = try channel.apply(editCommand(rules: [replacement], removeEndpointKeys: [endpointKey]))
        let stored = try XCTUnwrap(Mocks.shared.rule(forEndpointKey: endpointKey))
        XCTAssertEqual(stored.variants.map { $0.name }, ["new"])
    }

    func testEditCanTurnMockingOff() throws {
        _ = try channel.apply(editCommand(rules: [rule(endpointKey, variants: ["loaded"])], isMockingEnabled: true))
        _ = try channel.apply(editCommand(isMockingEnabled: false))
        XCTAssertFalse(Mocks.shared.isMockingEnabled)
        XCTAssertEqual(Mocks.shared.all.count, 1)
    }

    /// An edit carrying nothing is a bug in the caller, not a no-op worth hiding.
    func testEmptyEditReports() {
        XCTAssertThrowsError(try channel.apply(editCommand()))
    }

    // MARK: - Wire compatibility

    /// Captured off the sidecar from a real `lens_mock_endpoint` payload rather
    /// than written by hand: the MCP server and this decoder are the seam that
    /// breaks silently, and an approximation of the bytes cannot catch that.
    func testDecodesAndAppliesTheMCPServersOwnBytes() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/mcp-edit-command", withExtension: "json"))
        let decoded = try JSONDecoder().decode(ControlCommand.self, from: Data(contentsOf: url))
        let outcome = try channel.apply(decoded)

        XCTAssertEqual(outcome.upsertedCount, 1)
        let stored = try XCTUnwrap(Mocks.shared.rule(forEndpointKey: "GET /flashsale/v2/products"))
        XCTAssertTrue(stored.isEnabled)
        XCTAssertEqual(stored.variants.map { $0.name }, ["loaded", "empty", "500", "slow", "timeout"])
        XCTAssertTrue(Mocks.shared.isMockingEnabled)
    }

    // MARK: - Lifecycle

    func testStartIsIdempotent() {
        let options = ControlOptions(pollInterval: 60)
        channel.start(options)
        channel.start(options)
        XCTAssertTrue(channel.isRunning)
        channel.stop()
        XCTAssertFalse(channel.isRunning)
    }
}
