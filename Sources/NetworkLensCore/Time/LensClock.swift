//
//  LensClock.swift
//  NetworkLensCore
//
//  Created by Rohit Sahay on 30/07/26.
//

import Foundation

/// The passage of time, as the lens sees it.
///
/// Everything here that waits — a mock's latency, a breakpoint's auto-resume
/// deadline, a parked request's poll — went through `Date()` and `Task.sleep`
/// directly, which made every test of that behaviour a real sleep. A suite that
/// waits 2.6 seconds to prove a deadline did *not* fire is both slow and
/// flaky: it passes on a fast machine and fails on a loaded CI box, and the
/// failure says nothing about the code.
///
/// Deliberately not Swift's `Clock`: this package supports iOS 15, and
/// `Clock`/`InstantProtocol` are iOS 16.
public protocol LensClock: Sendable {

    var now: Date { get }

    /// Suspends for `interval`. Throws `CancellationError` if the task is
    /// cancelled while waiting.
    func sleep(for interval: TimeInterval) async throws
}

/// Real time. The default everywhere.
public struct SystemClock: LensClock {

    public init() {}

    public var now: Date { Date() }

    public func sleep(for interval: TimeInterval) async throws {
        guard interval > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }
}

/// Virtual time, advanced by hand.
///
/// Lives in the shipping target rather than the test target so host apps can
/// drive the lens deterministically in their own UI tests — the same reason the
/// mock engine is usable from a test harness.
public final class TestClock: LensClock, @unchecked Sendable {

    private let lock = NSLock()
    private var current: Date
    private var sleepers: [Sleeper] = []

    private struct Sleeper {
        let id: UUID
        let deadline: Date
        let continuation: CheckedContinuation<Void, Error>
    }

    public init(now: Date = Date(timeIntervalSince1970: 0)) {
        self.current = now
    }

    public var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// Number of tasks currently waiting.
    ///
    /// Tests need this to know a sleep has actually been entered before
    /// advancing — otherwise `advance` runs first and the sleeper waits for a
    /// deadline that is already in the past, which is the classic way a virtual
    /// clock hangs.
    public var sleeperCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sleepers.count
    }

    public func sleep(for interval: TimeInterval) async throws {
        guard interval > 0 else { return }
        let id = UUID()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                let deadline = current.addingTimeInterval(interval)
                guard current < deadline else {
                    lock.unlock()
                    return continuation.resume()
                }
                sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                lock.unlock()
            }
        } onCancel: {
            cancel(id)
        }
    }

    /// Moves time forward, waking everything whose deadline has passed.
    public func advance(by interval: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(interval)
        let due = sleepers.filter { $0.deadline <= current }
        sleepers.removeAll { $0.deadline <= current }
        lock.unlock()

        // Resumed outside the lock: a continuation can run its task
        // synchronously and re-enter `sleep`, which would deadlock on a
        // non-recursive lock.
        for sleeper in due { sleeper.continuation.resume() }
    }

    /// Waits — in real time — for `count` sleepers to register, then advances.
    ///
    /// The whole point of a test clock is losing real sleeps, so this is the
    /// one place a short poll is justified: it bounds the race between "task
    /// started" and "task entered sleep", which is otherwise untestable.
    public func advance(by interval: TimeInterval, afterSleepers count: Int) async throws {
        let deadline = Date().addingTimeInterval(5)
        while sleeperCount < count, Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        advance(by: interval)
    }

    private func cancel(_ id: UUID) {
        lock.lock()
        guard let index = sleepers.firstIndex(where: { $0.id == id }) else {
            return lock.unlock()
        }
        let sleeper = sleepers.remove(at: index)
        lock.unlock()
        sleeper.continuation.resume(throwing: CancellationError())
    }
}
