//
//  LensObservable.swift
//  NetworkLensUI
//
//  Created by Rohit Sahay on 30/07/26.
//

import Foundation
import Combine
import NetworkLensCore
#if canImport(UIKit)
import UIKit
#endif

/// Bridges Core's lock-based stores to SwiftUI.
///
/// Core deliberately has no Combine and no `@Observable` — it must stay
/// Foundation-only so milestone 4 can drive it headlessly. So the observation
/// adapter lives here, on the UI side of the boundary, and hops each change
/// notification onto the main actor.
@MainActor
public final class LensObservable: ObservableObject {

    public static let shared = LensObservable()

    /// Bumped on every store change. Views read through the computed
    /// properties below, which touch this so SwiftUI tracks them.
    @Published private var revision = 0

    /// The breakpoint currently held, if any, and its queue position.
    @Published public private(set) var presentation = BreakpointPresentation.empty

    /// One line the UI is expected to surface and then clear — an auto-resume
    /// that fired, a replay that could not be sent. Anything the tool decided
    /// on its own goes here rather than being dropped, because a tap that
    /// silently does nothing reads as a broken tool.
    @Published public var notice: String?

    private var storeToken: ExchangeStore.ObservationToken?
    private var breakpointToken: Breakpoints.ObservationToken?
    private var mocksToken: Mocks.ObservationToken?
    private var hangToken: HangingRequests.ObservationToken?
    private var scenariosToken: Scenarios.ObservationToken?

    public init() {
        storeToken = NetworkLens.store.addObserver { [weak self] in
            Task { @MainActor [weak self] in self?.revision &+= 1 }
        }
        breakpointToken = Breakpoints.shared.addObserver { [weak self] in
            Task { @MainActor [weak self] in self?.revision &+= 1 }
        }
        mocksToken = Mocks.shared.addObserver { [weak self] in
            Task { @MainActor [weak self] in self?.revision &+= 1 }
        }
        hangToken = HangingRequests.shared.addObserver { [weak self] in
            Task { @MainActor [weak self] in self?.revision &+= 1 }
        }
        scenariosToken = Scenarios.shared.addObserver { [weak self] in
            Task { @MainActor [weak self] in self?.revision &+= 1 }
        }
        Task { await self.attachToCoordinator() }
        surfaceLaunchScenario()
    }

    /// Says out loud what a launch argument did, when it did not work.
    ///
    /// A success stays quiet — the tester asked for that state and is looking
    /// at it. A miss cannot: the app then behaves exactly as if the tool were
    /// not installed, and the one person who could fix the typo is the one
    /// person not being told.
    private func surfaceLaunchScenario() {
        guard let activation = NetworkLens.launchScenarioActivation,
              !activation.isApplied else { return }
        notice = activation.summary
    }

    private func attachToCoordinator() async {
        await BreakpointCoordinator.shared.setStateObserver { [weak self] state in
            Task { @MainActor [weak self] in
                self?.presentation = BreakpointPresentation(state: state)
                self?.heldByExchangeID = state.heldByExchangeID
            }
        }
    }

    // MARK: - Reads

    /// Newest first, which is the only order a debug list should ever be in.
    public var exchanges: [NetworkExchange] {
        _ = revision
        return NetworkLens.store.exchanges.reversed()
    }

    public var stats: SessionStats {
        _ = revision
        return NetworkLens.stats()
    }

    public var breakpoints: [Breakpoint] {
        _ = revision
        return Breakpoints.shared.all
    }

    public var perturbations: [Perturbation] {
        _ = revision
        return Breakpoints.shared.perturbations
    }

    public var isRequestEditingEnabled: Bool {
        _ = revision
        return Breakpoints.shared.isRequestEditingEnabled
    }

    public var mocks: [MockRule] {
        _ = revision
        return Mocks.shared.all
    }

    public var isMockingEnabled: Bool {
        _ = revision
        return Mocks.shared.isMockingEnabled
    }

    /// Something is actually being served, as opposed to armed-but-suspended.
    public var isServingMocks: Bool {
        _ = revision
        return Mocks.shared.isServing
    }

    public func isServingMock(for exchange: NetworkExchange) -> Bool {
        _ = revision
        return Mocks.shared.isServing(endpointKey: exchange.endpointKey)
    }

    /// Flips one endpoint between its mock and the real server, from wherever
    /// the tester is looking at the response.
    public func setMockServing(_ serving: Bool, for exchange: NetworkExchange) {
        guard var rule = Mocks.shared.rule(forEndpointKey: exchange.endpointKey) else { return }
        rule.isEnabled = serving
        Mocks.shared.set(rule)
        // A per-endpoint switch that silently does nothing because the master
        // switch is off is worse than no switch. Turning one on turns mocking
        // on; turning one off leaves every other rule alone.
        if serving, !Mocks.shared.isMockingEnabled {
            Mocks.shared.setMockingEnabled(true)
        }
    }

    // MARK: - Replay

    public func canReplay(_ exchange: NetworkExchange) -> Bool {
        _ = revision
        return NetworkLens.canReplay(exchange)
    }

    /// Fires a captured request again. Fire-and-forget: the new exchange
    /// arrives through the store like any other.
    public func replay(_ exchange: NetworkExchange) {
        Task { [weak self] in
            do {
                _ = try await NetworkLens.replay(exchange)
            } catch {
                self?.notice = Self.replayFailureMessage(for: exchange, error: error)
            }
        }
    }

    /// Re-fires every replayable request a screen made, in the order it made
    /// them.
    ///
    /// The unit that matters on a screen with four calls: replaying them one at
    /// a time never reproduces the interleaving, and the interleaving is where
    /// the races live.
    public func replayScreen(_ screen: String) {
        replay(Array(exchanges.filter { ($0.screen ?? "Unattributed") == screen }.reversed()))
    }

    /// Re-fires a given set of requests, oldest first, in the order given.
    ///
    /// Takes the exchanges rather than a screen name so a caller showing a
    /// filtered group can replay *that* group. A "Replay all" button under a
    /// filtered header that quietly also fires the hidden hosts is a worse bug
    /// than no button.
    public func replay(_ group: [NetworkExchange]) {
        let group = group.filter { NetworkLens.canReplay($0) }

        Task { [weak self] in
            var failures: [NetworkExchange] = []
            for exchange in group {
                do {
                    _ = try await NetworkLens.replay(exchange)
                } catch {
                    // One unavailable request does not stop the rest: the
                    // interleaving is the reason for replaying a whole screen,
                    // and losing the oldest call is no reason to lose it.
                    failures.append(exchange)
                }
            }
            guard let first = failures.first else { return }
            self?.notice = failures.count == 1
                ? Self.replayFailureMessage(
                    for: first, error: NetworkLens.ReplayError.originalRequestUnavailable
                )
                : "\(failures.count) of \(group.count) requests could not be replayed — "
                    + "their originals have been evicted from the replay buffer."
        }
    }

    private static func replayFailureMessage(
        for exchange: NetworkExchange, error: Error
    ) -> String {
        guard case NetworkLens.ReplayError.originalRequestUnavailable = error else {
            return "\(exchange.endpointKey) could not be replayed: "
                + error.localizedDescription
        }
        // The one error `replay` throws, and the one worth explaining: the
        // unredacted request is kept in memory only and is evicted by newer
        // traffic, so the button was live a moment ago and is not now.
        return "\(exchange.endpointKey) can no longer be replayed — the original "
            + "request has been evicted by newer traffic."
    }

    // MARK: - Export

    /// Puts a `curl` command on the pasteboard.
    ///
    /// Redacted unless asked otherwise: a copied command is on its way into a
    /// ticket or a chat, which is where a token must not go.
    public func copyCurl(
        for exchange: NetworkExchange, secrets: CurlExport.Secrets = .redacted
    ) {
        copyToPasteboard(CurlExport.command(for: exchange, secrets: secrets))
    }

    /// Every request a screen made, oldest first, as one block.
    public func copyCurl(forScreen screen: String) {
        copyCurl(for: Array(exchanges.filter { ($0.screen ?? "Unattributed") == screen }.reversed()))
    }

    /// A given set of requests as one block, in the order given. The
    /// exchange-taking counterpart to `copyCurl(forScreen:)`, for the same
    /// reason as `replay(_:)`.
    public func copyCurl(for group: [NetworkExchange]) {
        copyToPasteboard(CurlExport.command(for: group))
    }

    /// The package also builds for macOS, where `UIPasteboard` does not exist.
    private func copyToPasteboard(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }

    /// Whether the unredacted request is still around to export.
    public func canIncludeSecrets(in exchange: NetworkExchange) -> Bool {
        _ = revision
        return NetworkLens.canReplay(exchange)
    }

    // MARK: - Scenarios

    public var scenarios: [Scenario] {
        _ = revision
        return Scenarios.shared.all
    }

    /// The setup currently in force, if the rules still say so.
    public var appliedScenario: Scenario? {
        _ = revision
        return Scenarios.shared.applied()
    }

    /// Saves the current selection across every mocked endpoint, or just the
    /// ones a screen touched.
    @discardableResult
    public func saveScenario(named name: String, forScreen screen: String? = nil) -> Scenario {
        let keys: Set<String>? = screen.map { screen in
            Set(
                exchanges
                    .filter { ($0.screen ?? "Unattributed") == screen }
                    .map(\.endpointKey)
            )
        }
        let scenario = Scenario.capturing(name, from: Mocks.shared.all, limitedTo: keys)
        Scenarios.shared.save(scenario)
        return scenario
    }

    /// Applies a saved setup, reporting what it could not reach.
    @discardableResult
    public func applyScenario(_ scenario: Scenario) -> Scenarios.Outcome {
        Scenarios.shared.apply(scenario)
    }

    public func removeScenario(_ scenario: Scenario) {
        Scenarios.shared.remove(id: scenario.id)
    }

    /// The endpoints a screen hit, for scoping a scenario to it.
    public func endpointKeys(forScreen screen: String) -> Set<String> {
        _ = revision
        return Set(
            exchanges
                .filter { ($0.screen ?? "Unattributed") == screen }
                .map(\.endpointKey)
        )
    }

    /// The rule answering this endpoint, if any.
    public func rule(for exchange: NetworkExchange) -> MockRule? {
        _ = revision
        return Mocks.shared.rule(forEndpointKey: exchange.endpointKey)
    }

    /// Switches which named answer an endpoint gives.
    public func activateVariant(_ variant: MockVariant, in rule: MockRule) {
        Mocks.shared.activateVariant(variant.id, forRuleID: rule.id)
        if !Mocks.shared.isMockingEnabled { Mocks.shared.setMockingEnabled(true) }
    }

    /// Adds a named answer to an endpoint, creating the rule if it is the
    /// first one.
    ///
    /// Named by the tester, not by the tool. A generated set of "empty / 500 /
    /// 401" reads well in a demo and badly in practice: the interesting states
    /// are the ones this particular screen gets wrong, and only the person
    /// debugging it knows what those are.
    @discardableResult
    public func addVariant(_ variant: MockVariant, for exchange: NetworkExchange) -> MockRule {
        if var existing = Mocks.shared.rule(forEndpointKey: exchange.endpointKey) {
            existing.addVariant(variant)
            Mocks.shared.set(existing)
            if !Mocks.shared.isMockingEnabled { Mocks.shared.setMockingEnabled(true) }
            return existing
        }

        let rule = MockRule(endpointKey: exchange.endpointKey, variants: [variant])
        Mocks.shared.set(rule)
        if !Mocks.shared.isMockingEnabled { Mocks.shared.setMockingEnabled(true) }
        return rule
    }

    /// Hit counts are read on demand rather than published: `Mocks.resolve`
    /// runs on the network task and deliberately does not notify, so a mocked
    /// request never schedules UI work.
    public func hitCount(for rule: MockRule) -> Int {
        _ = revision
        return Mocks.shared.hitCount(forRuleID: rule.id)
    }

    /// Turns a captured exchange into a rule that replays it.
    ///
    /// The path most rules are born on: something interesting came back from
    /// the server, and the tester wants it again on demand. Recreating that
    /// body by hand is the reason people give up on mocking.
    @discardableResult
    public func mock(_ exchange: NetworkExchange) -> MockRule? {
        guard let response = exchange.response else { return nil }
        let rule = MockRule(
            endpointKey: exchange.endpointKey,
            response: MockResponse(
                statusCode: response.statusCode,
                headers: response.headers,
                body: response.body ?? Data()
            ),
            name: "captured \(response.statusCode)"
        )
        Mocks.shared.set(rule)
        return rule
    }

    /// Exchanges grouped by screen, preserving newest-first order within and
    /// between groups.
    public var exchangesByScreen: [(screen: String, exchanges: [NetworkExchange])] {
        var order: [String] = []
        var buckets: [String: [NetworkExchange]] = [:]
        for exchange in exchanges {
            let screen = exchange.screen ?? "Unattributed"
            if buckets[screen] == nil { order.append(screen) }
            buckets[screen, default: []].append(exchange)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    public func clear() {
        NetworkLens.store.removeAll()
    }

    // MARK: - Holds

    /// Every request currently stopped at a breakpoint, keyed by exchange id.
    /// Includes queued holds, which have no sheet of their own and would
    /// otherwise be indistinguishable from a slow request.
    @Published public private(set) var heldByExchangeID: [UUID: UUID] = [:]

    public func isHeld(_ exchange: NetworkExchange) -> Bool {
        heldByExchangeID[exchange.id] != nil
    }

    /// Parked by a `.hang` mock, waiting to be let through.
    public func isHanging(_ exchange: NetworkExchange) -> Bool {
        _ = revision
        return HangingRequests.shared.isHanging(exchange.id)
    }

    public var hasHangingRequests: Bool {
        _ = revision
        return !HangingRequests.shared.hanging.isEmpty
    }

    /// Lets a parked request continue to the network, ending the loading state
    /// without waiting out the app's timeout.
    public func releaseHang(_ exchange: NetworkExchange) {
        HangingRequests.shared.release(exchange.id)
    }

    public func releaseAllHangs() {
        HangingRequests.shared.releaseAll()
    }

    /// Releases a held request from wherever the tester found it — the traffic
    /// row, the detail screen — carrying any edits already staged in the sheet.
    public func resume(_ exchange: NetworkExchange) {
        guard let pendingID = heldByExchangeID[exchange.id] else { return }
        Task { await BreakpointCoordinator.shared.resume(id: pendingID) }
    }
}

/// Main-actor snapshot of the coordinator's queue.
public struct BreakpointPresentation: Equatable {

    public var id: UUID?
    public var endpointKey: String
    public var stage: EditRecord.Stage
    public var payload: BreakpointPayload?
    public var autoResumeAt: Date?
    public var pausedAt: Date?
    public var position: Int
    public var total: Int
    public var isAutoResumeEnabled: Bool

    public static let empty = BreakpointPresentation(
        id: nil, endpointKey: "", stage: .response, payload: nil,
        autoResumeAt: nil, pausedAt: nil, position: 0, total: 0
    )

    init(state: BreakpointCoordinator.PresentationState) {
        guard let presented = state.presented else {
            self = .empty
            return
        }
        id = presented.id
        endpointKey = presented.endpointKey
        stage = presented.stage
        payload = presented.payload
        autoResumeAt = presented.autoResumeAt
        pausedAt = presented.pausedAt
        position = state.position
        total = state.total
        isAutoResumeEnabled = presented.isAutoResumeEnabled
    }

    public init(
        id: UUID?, endpointKey: String, stage: EditRecord.Stage,
        payload: BreakpointPayload?, autoResumeAt: Date?, pausedAt: Date?,
        position: Int, total: Int, isAutoResumeEnabled: Bool = true
    ) {
        self.isAutoResumeEnabled = isAutoResumeEnabled
        self.id = id
        self.endpointKey = endpointKey
        self.stage = stage
        self.payload = payload
        self.autoResumeAt = autoResumeAt
        self.pausedAt = pausedAt
        self.position = position
        self.total = total
    }

    public var isHolding: Bool { id != nil }

    /// Only shown once there is more than one, so a single breakpoint stays calm.
    public var queueLabel: String? {
        total > 1 ? "\(position) of \(total)" : nil
    }

    public static func == (lhs: BreakpointPresentation, rhs: BreakpointPresentation) -> Bool {
        lhs.id == rhs.id && lhs.position == rhs.position && lhs.total == rhs.total
    }
}
