//
//  ExchangeStoreTests.swift
//  NetworkLensCoreTests
//
//  Created by Rohit Sahay on 29/07/26.
//

import XCTest
@testable import NetworkLensCore

final class ExchangeStoreTests: XCTestCase {

    private func exchange(_ key: String) -> NetworkExchange {
        NetworkExchange(
            endpointKey: key,
            request: RequestSnapshot(method: "GET", url: URL(string: "https://api.test/x")!)
        )
    }

    func testEvictsOldestAtCapacity() {
        let store = ExchangeStore(capacity: 3)
        for index in 0..<5 { store.record(exchange("k\(index)")) }

        XCTAssertEqual(store.count, 3)
        XCTAssertEqual(store.exchanges.map(\.endpointKey), ["k2", "k3", "k4"])
    }

    func testDoesNotEvictBelowCapacity() {
        let store = ExchangeStore(capacity: 10)
        for index in 0..<10 { store.record(exchange("k\(index)")) }
        XCTAssertEqual(store.count, 10)
        XCTAssertEqual(store.exchanges.first?.endpointKey, "k0")
    }

    func testCapacityFloorIsOne() {
        let store = ExchangeStore(capacity: 0)
        store.record(exchange("a"))
        store.record(exchange("b"))
        XCTAssertEqual(store.exchanges.map(\.endpointKey), ["b"])
    }

    func testLoweringCapacityEvictsImmediately() {
        let store = ExchangeStore(capacity: 5)
        for index in 0..<5 { store.record(exchange("k\(index)")) }
        store.setCapacity(2)
        XCTAssertEqual(store.exchanges.map(\.endpointKey), ["k3", "k4"])
    }

    func testUpdateReplacesInPlaceKeepingOrder() {
        let store = ExchangeStore(capacity: 5)
        let target = exchange("k1")
        store.record(exchange("k0"))
        store.record(target)
        store.record(exchange("k2"))

        let updated = store.update(id: target.id) {
            $0.completed(
                response: ResponseSnapshot(statusCode: 204),
                timing: Timing(total: 0.25)
            )
        }

        XCTAssertTrue(updated)
        XCTAssertEqual(store.exchanges.map(\.endpointKey), ["k0", "k1", "k2"])
        XCTAssertEqual(store.exchanges[1].response?.statusCode, 204)
        XCTAssertEqual(store.exchanges[1].timing?.total, 0.25)
    }

    func testUpdateOnEvictedExchangeIsNoOp() {
        let store = ExchangeStore(capacity: 1)
        let evicted = exchange("gone")
        store.record(evicted)
        store.record(exchange("kept"))

        XCTAssertFalse(store.update(id: evicted.id) { $0 })
        XCTAssertEqual(store.exchanges.map(\.endpointKey), ["kept"])
    }

    func testRemoveAll() {
        let store = ExchangeStore(capacity: 5)
        store.record(exchange("a"))
        store.removeAll()
        XCTAssertEqual(store.count, 0)
    }

    func testObserverFiresOnWriteAndStopsAfterTokenIsReleased() {
        let store = ExchangeStore(capacity: 5)
        let counter = Counter()

        var token: ExchangeStore.ObservationToken? = store.addObserver { counter.increment() }
        store.record(exchange("a"))
        store.record(exchange("b"))
        XCTAssertEqual(counter.value, 2)

        token = nil
        _ = token
        store.record(exchange("c"))
        XCTAssertEqual(counter.value, 2)
    }

    func testConcurrentWritesDoNotExceedCapacity() {
        let store = ExchangeStore(capacity: 50)
        let group = DispatchGroup()

        for index in 0..<8 {
            DispatchQueue.global().async(group: group) {
                for inner in 0..<100 { store.record(self.exchange("q\(index)-\(inner)")) }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(store.count, 50)
    }
}

/// Minimal thread-safe counter, so the observer test does not race.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}
