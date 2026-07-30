import Foundation
import Combine
import NetworkLensCore

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

    /// Set when an auto-resume fired, so the UI can toast it. Cleared on read.
    @Published public var autoResumeNotice: String?

    private var storeToken: ExchangeStore.ObservationToken?
    private var breakpointToken: Breakpoints.ObservationToken?
    private var mocksToken: Mocks.ObservationToken?

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
        Task { await self.attachToCoordinator() }
    }

    private func attachToCoordinator() async {
        await BreakpointCoordinator.shared.setStateObserver { [weak self] state in
            Task { @MainActor [weak self] in
                self?.presentation = BreakpointPresentation(state: state)
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
    }

    public init(
        id: UUID?, endpointKey: String, stage: EditRecord.Stage,
        payload: BreakpointPayload?, autoResumeAt: Date?, pausedAt: Date?,
        position: Int, total: Int
    ) {
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
