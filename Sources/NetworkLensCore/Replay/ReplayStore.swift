//
//  ReplayStore.swift
//  NetworkLensCore
//
//  Created by Rohit Sahay on 30/07/26.
//

import Foundation

/// The exact requests that went out this session, kept so they can be sent
/// again.
///
/// Replay cannot be built on `RequestSnapshot`: snapshots are redacted on the
/// way into the store, so replaying one would send `Authorization: ***` and get
/// a 401 that has nothing to do with what was being tested. The unredacted
/// request has to be kept separately.
///
/// Which is why this is **memory-only and never persisted**. It holds exactly
/// the material redaction exists to keep off disk, so it dies with the process
/// — a replay works for the session that captured it and not a launch later.
/// That is a deliberate limit, not an oversight.
public final class ReplayStore: @unchecked Sendable {

    public static let shared = ReplayStore()

    private let lock = NSLock()
    private var requests: [UUID: URLRequest] = [:]
    /// Insertion order, for evicting the oldest first.
    private var order: [UUID] = []

    /// Bounded for the same reason `ExchangeStore` is: a long session on a busy
    /// screen would otherwise hold every request body ever sent.
    private let limit: Int

    public init(limit: Int = 200) {
        self.limit = max(1, limit)
    }

    /// Records the request as it actually left, keyed by its exchange.
    public func record(_ request: URLRequest, for exchangeID: UUID) {
        lock.lock()
        defer { lock.unlock() }

        if requests[exchangeID] == nil { order.append(exchangeID) }
        requests[exchangeID] = request

        while order.count > limit {
            let evicted = order.removeFirst()
            requests[evicted] = nil
        }
    }

    public func request(for exchangeID: UUID) -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return requests[exchangeID]
    }

    public func canReplay(_ exchangeID: UUID) -> Bool {
        request(for: exchangeID) != nil
    }

    public func removeAll() {
        lock.lock()
        requests.removeAll()
        order.removeAll()
        lock.unlock()
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }
}
