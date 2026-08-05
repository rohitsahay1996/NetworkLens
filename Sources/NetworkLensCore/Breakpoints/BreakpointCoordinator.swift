//
//  BreakpointCoordinator.swift
//  NetworkLensCore
//
//  Created by Rohit Sahay on 29/07/26.
//

import Foundation

/// What is being held.
public enum BreakpointPayload: @unchecked Sendable {
    case request(URLRequest)
    case response(ResponsePayload)

    public var stage: EditRecord.Stage {
        switch self {
        case .request: return .request
        case .response: return .response
        }
    }
}

/// How a held breakpoint was released.
public enum BreakpointOutcome: @unchecked Sendable {
    /// Continue with this payload, edited or not.
    case proceed(BreakpointPayload)
    /// Fail the request with a chosen `URLError`.
    case abort(Error)
}

/// Serialises breakpoint presentation.
///
/// Several breakpointed requests fire together on a screen load, and stacking
/// modals on top of each other is unusable. One is presented at a time; the
/// rest queue in FIFO order and the UI shows the position.
///
/// This is an actor, and the UI it drives is main-actor. The isolation boundary
/// is crossed exactly twice per pause — once to publish the presented item, once
/// to deliver the outcome — so nothing hops threads inside the hold itself.
public actor BreakpointCoordinator {

    public static let shared = BreakpointCoordinator()

    /// One paused request, from the UI's point of view.
    public struct Pending: Identifiable, @unchecked Sendable {
        public let id: UUID
        /// The `LensURLProtocol` instance that owns this. Used by
        /// `dismissPending(for:)` when the app cancels the task.
        public let owner: UUID
        /// The recorded `NetworkExchange` this hold belongs to, so a traffic row
        /// can tell it is the one stopped and offer to release it. Matching on
        /// `endpointKey` instead would pick the wrong request the moment two
        /// calls to the same endpoint are in flight.
        public let exchangeID: UUID
        public let endpointKey: String
        public let payload: BreakpointPayload
        /// Wall-clock deadline at which we auto-resume with current edits.
        public let autoResumeAt: Date
        public let pausedAt: Date
        /// Whether that deadline is armed. Turning it off holds the request
        /// indefinitely from the tool's point of view — see
        /// `setAutoResumeEnabled(_:for:)` for what the app still does.
        public var isAutoResumeEnabled: Bool = true

        public var stage: EditRecord.Stage { payload.stage }
    }

    private var queue: [Pending] = []
    private var continuations: [UUID: CheckedContinuation<BreakpointOutcome, Never>] = [:]
    private var autoResumeTasks: [UUID: Task<Void, Never>] = [:]

    /// Set by the UI so it can render the queue without polling the actor.
    private var stateObserver: (@Sendable (PresentationState) -> Void)?

    /// Latest edits the UI has staged for the presented item, so an auto-resume
    /// proceeds with the tester's work rather than discarding it.
    private var stagedEdits: [UUID: BreakpointPayload] = [:]

    /// What the UI needs to draw, in one value.
    public struct PresentationState: @unchecked Sendable {
        public var presented: Pending?
        public var queuedCount: Int
        /// 1-based position of the presented item, for "2 of 4".
        public var position: Int
        public var total: Int
        /// Every held request keyed by its exchange id, presented and queued
        /// alike. The traffic list needs the queued ones too: they are stopped
        /// just as hard as the presented one, and they are the rows that read
        /// as hung because nothing is on screen for them.
        public var heldByExchangeID: [UUID: UUID]

        public static let empty = PresentationState(
            presented: nil, queuedCount: 0, position: 0, total: 0,
            heldByExchangeID: [:]
        )
    }

    /// Injected so auto-resume can be tested without waiting out a real
    /// deadline. Defaults to whatever the lens is configured with.
    private let clock: LensClock

    public init(clock: LensClock? = nil) {
        self.clock = clock ?? NetworkLens.clock
    }

    // MARK: - Observation

    public func setStateObserver(_ observer: @escaping @Sendable (PresentationState) -> Void) {
        stateObserver = observer
        publish()
    }

    private func publish() {
        let state = PresentationState(
            presented: queue.first,
            queuedCount: max(0, queue.count - 1),
            position: queue.isEmpty ? 0 : 1,
            total: queue.count,
            heldByExchangeID: Dictionary(
                queue.map { ($0.exchangeID, $0.id) }, uniquingKeysWith: { first, _ in first }
            )
        )
        stateObserver?(state)
    }

    // MARK: - Pausing

    /// Holds a payload until the UI releases it. Never blocks a thread.
    ///
    /// `timeout` is the app's own `timeoutIntervalForRequest`, which keeps
    /// running while we hold. Auto-resume fires at 80% of it so the tester's
    /// edits actually reach the app instead of being wasted on a timeout. The
    /// timeout is deliberately *not* extended — that would change the app's
    /// behaviour under test.
    public func pause(
        _ payload: BreakpointPayload,
        owner: UUID,
        exchangeID: UUID,
        endpointKey: String,
        timeout: TimeInterval
    ) async -> BreakpointOutcome {
        let id = UUID()
        let budget = Self.autoResumeInterval(for: timeout)
        let pending = Pending(
            id: id,
            owner: owner,
            exchangeID: exchangeID,
            endpointKey: endpointKey,
            payload: payload,
            autoResumeAt: clock.now.addingTimeInterval(budget),
            pausedAt: clock.now
        )

        // Cancellation can arrive before the continuation exists — a task
        // cancelled the instant it reaches a breakpoint runs `onCancel` first,
        // and `resolve` would then find nothing to resolve and return. The
        // continuation registered a moment later would be one nobody ever
        // resumes: the request hangs forever and the hold never leaves the
        // queue. The box carries that ordering across the two closures, and
        // dies with the call rather than accumulating on the actor.
        let box = CancellationBox()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard box.register() else {
                    continuation.resume(returning: .proceed(payload))
                    return
                }
                queue.append(pending)
                continuations[id] = continuation
                stagedEdits[id] = payload
                scheduleAutoResume(for: id, after: budget)
                Breakpoints.shared.didHit(endpointKey: endpointKey)
                publish()
            }
        } onCancel: {
            // Registered already: the continuation is on the actor and only
            // `resolve` can hand it back. Otherwise the box has recorded the
            // cancellation and the body above resumes immediately.
            if box.cancel() {
                Task { await self.resolve(id: id, with: .proceed(payload), reason: .cancelled) }
            }
        }
    }

    /// Orders registration against cancellation for one `pause`.
    ///
    /// Both directions are answered exactly once: whichever call arrives first
    /// gets `true`, the second gets `false` and does nothing.
    private final class CancellationBox: @unchecked Sendable {

        private let lock = NSLock()
        private var isCancelled = false
        private var isRegistered = false

        /// True when the continuation should be stored — i.e. cancellation has
        /// not already happened.
        func register() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !isCancelled else { return false }
            isRegistered = true
            return true
        }

        /// True when there is a stored continuation to resolve.
        func cancel() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            isCancelled = true
            return isRegistered
        }
    }

    /// 80% of the app's timeout, floored so a very short timeout still leaves a
    /// usable window, and capped so an infinite timeout does not hold forever.
    static func autoResumeInterval(for timeout: TimeInterval) -> TimeInterval {
        guard timeout > 0, timeout.isFinite else { return 60 }
        return min(max(timeout * 0.8, 2), 300)
    }

    private func scheduleAutoResume(for id: UUID, after interval: TimeInterval) {
        autoResumeTasks[id] = Task { [weak self, clock] in
            do {
                try await clock.sleep(for: interval)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard let self else { return }
            await self.autoResume(id: id)
        }
    }

    private func autoResume(id: UUID) {
        guard let staged = stagedEdits[id] else { return }
        resolve(id: id, with: .proceed(staged), reason: .timedOut)
    }

    /// Arms or disarms the auto-resume deadline for a held item.
    ///
    /// Disarming only stops *this tool* from releasing the request. The app's
    /// own `timeoutIntervalForRequest` keeps running underneath and is not
    /// extended, so a request held past it fails with `.timedOut` exactly as it
    /// would have without the tool attached. That is the point of the switch:
    /// watching the app's real timeout behaviour is a legitimate thing to test,
    /// and the default deadline exists precisely to prevent it by accident.
    ///
    /// Re-arming keeps the original deadline rather than restarting the budget
    /// — the timeout it was derived from has been running the whole time, so a
    /// fresh window would be a window the app does not have. A deadline that
    /// has already passed fires immediately.
    public func setAutoResumeEnabled(_ enabled: Bool, for id: UUID) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        guard queue[index].isAutoResumeEnabled != enabled else { return }
        queue[index].isAutoResumeEnabled = enabled

        if enabled {
            let remaining = max(0, queue[index].autoResumeAt.timeIntervalSince(clock.now))
            scheduleAutoResume(for: id, after: remaining)
        } else {
            autoResumeTasks.removeValue(forKey: id)?.cancel()
        }
        publish()
    }

    // MARK: - Staging

    /// Records the UI's in-progress edits, so an auto-resume keeps them.
    public func stageEdit(_ payload: BreakpointPayload, for id: UUID) {
        guard continuations[id] != nil else { return }
        stagedEdits[id] = payload
    }

    // MARK: - Resolution

    public enum ResumeReason: Sendable {
        case user
        case timedOut
        case cancelled
        case resumeAll
    }

    /// Called by the UI when the tester taps Continue or Abort.
    public func resolve(id: UUID, with outcome: BreakpointOutcome, reason: ResumeReason = .user) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        autoResumeTasks.removeValue(forKey: id)?.cancel()
        stagedEdits.removeValue(forKey: id)
        queue.removeAll { $0.id == id }
        continuation.resume(returning: outcome)
        lastResumeReason = reason
        publish()
    }

    /// Why the most recent release happened, so the UI can toast an auto-resume.
    public private(set) var lastResumeReason: ResumeReason?

    /// Releases one held request, presented or queued, with whatever the UI has
    /// staged for it.
    ///
    /// The play button on a traffic row: a queued hold has no payload on screen
    /// to resume *with*, so the payload has to be looked up here rather than
    /// passed in. Staged edits win over the original for the same reason
    /// auto-resume keeps them — work already typed should not be thrown away by
    /// releasing from somewhere else.
    public func resume(id: UUID) {
        guard let pending = queue.first(where: { $0.id == id }) else { return }
        resolve(id: id, with: .proceed(stagedEdits[id] ?? pending.payload))
    }

    /// Releases everything currently held, presented and queued, unedited
    /// except for whatever was already staged.
    public func resumeAll() {
        for pending in queue {
            let payload = stagedEdits[pending.id] ?? pending.payload
            guard let continuation = continuations.removeValue(forKey: pending.id) else { continue }
            autoResumeTasks.removeValue(forKey: pending.id)?.cancel()
            stagedEdits.removeValue(forKey: pending.id)
            continuation.resume(returning: .proceed(payload))
        }
        queue.removeAll()
        lastResumeReason = .resumeAll
        publish()
    }

    public func resumeAllAndDisableBreakpoints() {
        Breakpoints.shared.disableAll()
        resumeAll()
    }

    /// Removes any breakpoint belonging to a cancelled request.
    ///
    /// A user navigating away mid-pause is normal. Without this the sheet stays
    /// up bound to a dead task, and nothing the tester taps can dismiss it.
    nonisolated public func dismissPending(for owner: UUID) {
        Task { await self.dismissPendingIsolated(owner: owner) }
    }

    private func dismissPendingIsolated(owner: UUID) {
        // Includes queued-but-not-yet-presented items, which is the case that
        // is easy to miss: they are holding a continuation just as much as the
        // presented one is.
        for pending in queue where pending.owner == owner {
            guard let continuation = continuations.removeValue(forKey: pending.id) else { continue }
            autoResumeTasks.removeValue(forKey: pending.id)?.cancel()
            stagedEdits.removeValue(forKey: pending.id)
            continuation.resume(returning: .proceed(pending.payload))
        }
        queue.removeAll { $0.owner == owner }
        publish()
    }

    // MARK: - Introspection, for tests

    public var pendingCount: Int { queue.count }

    public var presented: Pending? { queue.first }
}
