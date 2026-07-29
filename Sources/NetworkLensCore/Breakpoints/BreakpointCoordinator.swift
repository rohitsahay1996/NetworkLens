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
        public let endpointKey: String
        public let payload: BreakpointPayload
        /// Wall-clock deadline at which we auto-resume with current edits.
        public let autoResumeAt: Date
        public let pausedAt: Date

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

        public static let empty = PresentationState(
            presented: nil, queuedCount: 0, position: 0, total: 0
        )
    }

    public init() {}

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
            total: queue.count
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
        endpointKey: String,
        timeout: TimeInterval
    ) async -> BreakpointOutcome {
        let id = UUID()
        let budget = Self.autoResumeInterval(for: timeout)
        let pending = Pending(
            id: id,
            owner: owner,
            endpointKey: endpointKey,
            payload: payload,
            autoResumeAt: Date().addingTimeInterval(budget),
            pausedAt: Date()
        )

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.append(pending)
                continuations[id] = continuation
                stagedEdits[id] = payload
                scheduleAutoResume(for: id, after: budget)
                Breakpoints.shared.didHit(endpointKey: endpointKey)
                publish()
            }
        } onCancel: {
            Task { await self.resolve(id: id, with: .proceed(payload), reason: .cancelled) }
        }
    }

    /// 80% of the app's timeout, floored so a very short timeout still leaves a
    /// usable window, and capped so an infinite timeout does not hold forever.
    static func autoResumeInterval(for timeout: TimeInterval) -> TimeInterval {
        guard timeout > 0, timeout.isFinite else { return 60 }
        return min(max(timeout * 0.8, 2), 300)
    }

    private func scheduleAutoResume(for id: UUID, after interval: TimeInterval) {
        autoResumeTasks[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            await self.autoResume(id: id)
        }
    }

    private func autoResume(id: UUID) {
        guard let staged = stagedEdits[id] else { return }
        resolve(id: id, with: .proceed(staged), reason: .timedOut)
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
