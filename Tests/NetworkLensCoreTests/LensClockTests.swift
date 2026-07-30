//
//  LensClockTests.swift
//  NetworkLensCoreTests
//
//  Created by Rohit Sahay on 30/07/26.
//

import XCTest
@testable import NetworkLensCore

/// The clock is a test seam, so its own correctness has to be established
/// first — every test that trusts it inherits its bugs.
final class LensClockTests: XCTestCase {

    func testSleepResumesOnlyWhenTimeReachesTheDeadline() async throws {
        let clock = TestClock()
        let woke = Woke()

        let sleeper = Task {
            try await clock.sleep(for: 10)
            await woke.set()
        }

        try await clock.advance(by: 9, afterSleepers: 1)
        try await Task.sleep(nanoseconds: 20_000_000)
        let early = await woke.value
        XCTAssertFalse(early, "short of the deadline, nothing may wake")

        clock.advance(by: 1)
        try await sleeper.value
        let late = await woke.value
        XCTAssertTrue(late)
    }

    func testTimeDoesNotMoveOnItsOwn() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(clock.now, Date(timeIntervalSince1970: 1_000))
    }

    func testAdvancingPastSeveralDeadlinesWakesThemAll() async throws {
        let clock = TestClock()
        let counter = Counter()

        for interval in [1.0, 2.0, 3.0] {
            Task {
                try await clock.sleep(for: interval)
                await counter.increment()
            }
        }

        try await clock.advance(by: 5, afterSleepers: 3)
        try await Task.sleep(nanoseconds: 50_000_000)

        let count = await counter.value
        XCTAssertEqual(count, 3)
    }

    /// Auto-resume cancels its own timer, so a cancelled sleep must not be left
    /// waiting for a deadline that will never be reached.
    func testCancellingASleeperThrowsAndDeregisters() async throws {
        let clock = TestClock()

        let sleeper = Task { try await clock.sleep(for: 10) }
        let deadline = Date().addingTimeInterval(2)
        while clock.sleeperCount == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        sleeper.cancel()

        do {
            try await sleeper.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(clock.sleeperCount, 0)
    }

    func testZeroAndNegativeSleepsReturnImmediately() async throws {
        let clock = TestClock()
        try await clock.sleep(for: 0)
        try await clock.sleep(for: -5)
        XCTAssertEqual(clock.sleeperCount, 0)
    }

    func testSystemClockActuallyWaits() async throws {
        let clock = SystemClock()
        let started = Date()
        try await clock.sleep(for: 0.05)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.04)
    }
}

private actor Woke {
    var value = false
    func set() { value = true }
}

private actor Counter {
    var value = 0
    func increment() { value += 1 }
}
