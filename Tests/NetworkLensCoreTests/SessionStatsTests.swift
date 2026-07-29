import XCTest
@testable import NetworkLensCore

final class SessionStatsTests: XCTestCase {

    private func exchange(
        _ key: String,
        status: Int? = nil,
        failure: FailureInfo? = nil,
        duration: TimeInterval? = nil,
        source: Source = .live
    ) -> NetworkExchange {
        let base = NetworkExchange(
            endpointKey: key,
            request: RequestSnapshot(method: "GET", url: URL(string: "https://api.test/x")!),
            source: source
        )
        if let failure { return base.failed(failure, timing: duration.map { Timing(total: $0) }) }
        guard let status else { return base }
        return base.completed(
            response: ResponseSnapshot(statusCode: status),
            timing: duration.map { Timing(total: $0) }
        )
    }

    func testBucketsFailuresByKind() {
        let stats = SessionStats(exchanges: [
            exchange("GET /a", status: 200),
            exchange("GET /a", status: 404),
            exchange("GET /b", status: 500),
            exchange("GET /b", failure: FailureInfo(kind: .transport, message: "offline")),
            exchange("GET /c", failure: FailureInfo(kind: .decode, message: "bad json")),
        ])

        XCTAssertEqual(stats.totalRequests, 5)
        XCTAssertEqual(stats.failuresByKind[.clientError], 1)
        XCTAssertEqual(stats.failuresByKind[.serverError], 1)
        XCTAssertEqual(stats.failuresByKind[.transport], 1)
        XCTAssertEqual(stats.failuresByKind[.decode], 1)
        XCTAssertEqual(stats.totalFailures, 4)
    }

    func testSuccessAndRedirectProduceNoFailure() {
        let stats = SessionStats(exchanges: [
            exchange("GET /a", status: 204),
            exchange("GET /a", status: 302),
        ])
        XCTAssertEqual(stats.totalFailures, 0)
    }

    func testCountsPerEndpointSortedByFrequency() {
        let stats = SessionStats(exchanges: [
            exchange("GET /a", status: 200),
            exchange("GET /b", status: 200),
            exchange("GET /b", status: 200),
            exchange("GET /b", status: 500),
        ])

        XCTAssertEqual(stats.endpoints.map(\.endpointKey), ["GET /b", "GET /a"])
        XCTAssertEqual(stats.endpoints[0].count, 3)
        XCTAssertEqual(stats.endpoints[0].failureCount, 1)
    }

    func testAverageDurationIgnoresExchangesWithoutTiming() {
        let stats = SessionStats(exchanges: [
            exchange("GET /a", status: 200, duration: 0.2),
            exchange("GET /a", status: 200, duration: 0.4),
            exchange("GET /a", status: 200),
        ])
        XCTAssertEqual(stats.endpoints[0].averageDuration ?? 0, 0.3, accuracy: 0.0001)
    }

    func testInFlightAndSourceCounts() {
        let stats = SessionStats(exchanges: [
            exchange("GET /a"),
            exchange("GET /a", status: 200),
            exchange("GET /b", status: 200, source: .mocked),
        ])
        XCTAssertEqual(stats.inFlightCount, 1)
        XCTAssertEqual(stats.countsBySource[.live], 2)
        XCTAssertEqual(stats.countsBySource[.mocked], 1)
    }

    func testEmptySession() {
        let stats = SessionStats(exchanges: [])
        XCTAssertEqual(stats.totalRequests, 0)
        XCTAssertTrue(stats.endpoints.isEmpty)
        XCTAssertEqual(stats.totalFailures, 0)
    }
}
