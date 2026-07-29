import XCTest
@testable import NetworkLensCore

final class BreakpointCoordinatorTests: XCTestCase {

    private func makeRequest(_ path: String = "/x") -> URLRequest {
        URLRequest(url: URL(string: "https://api.test\(path)")!)
    }

    /// Waits for the coordinator to hold `count` items without sleeping a
    /// fixed interval, which would make the test slow or flaky.
    private func waitForPending(
        _ coordinator: BreakpointCoordinator,
        count: Int,
        timeout: TimeInterval = 5
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while await coordinator.pendingCount != count {
            if Date() > deadline {
                let actual = await coordinator.pendingCount
                XCTFail("expected \(count) pending, still \(actual)")
                return
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    // MARK: - Queueing

    func testFourConcurrentPausesQueueAndPresentOneAtATime() async throws {
        let coordinator = BreakpointCoordinator()

        let holds = (0..<4).map { index in
            Task {
                await coordinator.pause(
                    .request(self.makeRequest("/\(index)")),
                    owner: UUID(),
                    endpointKey: "GET /\(index)",
                    timeout: 600
                )
            }
        }
        try await waitForPending(coordinator, count: 4)

        // Only one is presented; the other three wait their turn.
        let presented = await coordinator.presented
        XCTAssertNotNil(presented)
        let actual1 = await coordinator.pendingCount
        XCTAssertEqual(actual1, 4)

        await coordinator.resumeAll()
        for hold in holds {
            guard case .proceed = await hold.value else {
                return XCTFail("expected proceed")
            }
        }
        let actual2 = await coordinator.pendingCount
        XCTAssertEqual(actual2, 0)
    }

    func testFIFOOrder() async throws {
        let coordinator = BreakpointCoordinator()

        for index in 0..<3 {
            Task {
                await coordinator.pause(
                    .request(self.makeRequest()),
                    owner: UUID(),
                    endpointKey: "GET /\(index)",
                    timeout: 600
                )
            }
            // Sequential starts so the ordering under test is deterministic.
            try await waitForPending(coordinator, count: index + 1)
        }

        let actual3 = await coordinator.presented?.endpointKey
        XCTAssertEqual(actual3, "GET /0")
        await coordinator.resumeAll()
    }

    func testResolvingPresentedPromotesTheNext() async throws {
        let coordinator = BreakpointCoordinator()

        for index in 0..<2 {
            Task {
                await coordinator.pause(
                    .request(self.makeRequest()),
                    owner: UUID(),
                    endpointKey: "GET /\(index)",
                    timeout: 600
                )
            }
            try await waitForPending(coordinator, count: index + 1)
        }

        let first = await coordinator.presented
        await coordinator.resolve(id: first!.id, with: .proceed(.request(makeRequest())))

        let actual4 = await coordinator.pendingCount
        XCTAssertEqual(actual4, 1)
        let actual5 = await coordinator.presented?.endpointKey
        XCTAssertEqual(actual5, "GET /1")
        await coordinator.resumeAll()
    }

    // MARK: - Outcomes

    func testProceedDeliversEditedPayload() async throws {
        let coordinator = BreakpointCoordinator()
        let hold = Task {
            await coordinator.pause(
                .request(self.makeRequest("/original")),
                owner: UUID(), endpointKey: "GET /x", timeout: 600
            )
        }
        try await waitForPending(coordinator, count: 1)

        let id = await coordinator.presented!.id
        await coordinator.resolve(id: id, with: .proceed(.request(makeRequest("/edited"))))

        guard case .proceed(.request(let delivered)) = await hold.value else {
            return XCTFail("expected an edited request")
        }
        XCTAssertEqual(delivered.url?.path, "/edited")
    }

    func testAbortDeliversError() async throws {
        let coordinator = BreakpointCoordinator()
        let hold = Task {
            await coordinator.pause(
                .request(self.makeRequest()),
                owner: UUID(), endpointKey: "GET /x", timeout: 600
            )
        }
        try await waitForPending(coordinator, count: 1)

        let id = await coordinator.presented!.id
        await coordinator.resolve(id: id, with: .abort(URLError(.notConnectedToInternet)))

        guard case .abort(let error) = await hold.value else {
            return XCTFail("expected abort")
        }
        XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
    }

    // MARK: - Cancellation

    func testDismissPendingReleasesQueuedNotYetPresentedBreakpoint() async throws {
        let coordinator = BreakpointCoordinator()
        let firstOwner = UUID()
        let secondOwner = UUID()

        let first = Task {
            await coordinator.pause(
                .request(self.makeRequest()),
                owner: firstOwner, endpointKey: "GET /first", timeout: 600
            )
        }
        try await waitForPending(coordinator, count: 1)

        let second = Task {
            await coordinator.pause(
                .request(self.makeRequest()),
                owner: secondOwner, endpointKey: "GET /second", timeout: 600
            )
        }
        try await waitForPending(coordinator, count: 2)

        // The second one is queued but never presented — the easy case to miss,
        // because it is holding a continuation just like the presented one.
        coordinator.dismissPending(for: secondOwner)
        try await waitForPending(coordinator, count: 1)

        guard case .proceed = await second.value else {
            return XCTFail("queued breakpoint should have been released")
        }
        let actual6 = await coordinator.presented?.endpointKey
        XCTAssertEqual(actual6, "GET /first")

        coordinator.dismissPending(for: firstOwner)
        _ = await first.value
        let actual7 = await coordinator.pendingCount
        XCTAssertEqual(actual7, 0)
    }

    func testDismissPendingForUnknownOwnerIsHarmless() async throws {
        let coordinator = BreakpointCoordinator()
        let hold = Task {
            await coordinator.pause(
                .request(self.makeRequest()),
                owner: UUID(), endpointKey: "GET /x", timeout: 600
            )
        }
        try await waitForPending(coordinator, count: 1)

        coordinator.dismissPending(for: UUID())
        try await Task.sleep(nanoseconds: 20_000_000)
        let actual8 = await coordinator.pendingCount
        XCTAssertEqual(actual8, 1)

        await coordinator.resumeAll()
        _ = await hold.value
    }

    // MARK: - Auto-resume

    func testAutoResumeIntervalIsEightyPercentOfTimeout() {
        XCTAssertEqual(BreakpointCoordinator.autoResumeInterval(for: 30), 24, accuracy: 0.001)
        XCTAssertEqual(BreakpointCoordinator.autoResumeInterval(for: 60), 48, accuracy: 0.001)
    }

    func testAutoResumeIntervalIsFlooredAndCapped() {
        // A 1-second timeout would leave 0.8s to edit — floor it so the sheet
        // is at least usable, even though the request may then time out.
        XCTAssertEqual(BreakpointCoordinator.autoResumeInterval(for: 1), 2, accuracy: 0.001)
        // An effectively infinite timeout must not hold forever.
        XCTAssertEqual(BreakpointCoordinator.autoResumeInterval(for: 100_000), 300, accuracy: 0.001)
        XCTAssertEqual(BreakpointCoordinator.autoResumeInterval(for: 0), 60, accuracy: 0.001)
    }

    /// The acceptance criterion: the client gets a response, not a timeout.
    func testAutoResumeFiresBeforeTimeoutAndKeepsStagedEdits() async throws {
        let coordinator = BreakpointCoordinator()
        // 2.5s timeout → auto-resume at 2s.
        let hold = Task {
            await coordinator.pause(
                .request(self.makeRequest("/original")),
                owner: UUID(), endpointKey: "GET /x", timeout: 2.5
            )
        }
        try await waitForPending(coordinator, count: 1)

        let id = await coordinator.presented!.id
        // Tester edited but never tapped Continue.
        await coordinator.stageEdit(.request(makeRequest("/edited")), for: id)

        let started = Date()
        let outcome = await hold.value
        let elapsed = Date().timeIntervalSince(started)

        guard case .proceed(.request(let delivered)) = outcome else {
            return XCTFail("expected proceed with staged edits")
        }
        XCTAssertEqual(delivered.url?.path, "/edited", "staged edits must not be discarded")
        XCTAssertLessThan(elapsed, 2.5, "auto-resume must beat the app's own timeout")
        let actual9 = await coordinator.lastResumeReason
        XCTAssertEqual(actual9, .timedOut)
    }

    // MARK: - Resume all

    func testResumeAllAndDisableTurnsRulesOff() async throws {
        let breakpoints = Breakpoints.shared
        breakpoints.removeAll()
        breakpoints.set(Breakpoint(endpointKey: "GET /x", stage: .response))

        let coordinator = BreakpointCoordinator()
        let hold = Task {
            await coordinator.pause(
                .request(self.makeRequest()),
                owner: UUID(), endpointKey: "GET /x", timeout: 600
            )
        }
        try await waitForPending(coordinator, count: 1)

        await coordinator.resumeAllAndDisableBreakpoints()
        _ = await hold.value

        XCTAssertNil(breakpoints.breakpoint(forEndpointKey: "GET /x"))
        XCTAssertEqual(breakpoints.all.first?.isEnabled, false, "rule should be kept but disabled")
        breakpoints.removeAll()
    }
}
