//
//  ExchangeStore.swift
//  NetworkLensCore
//
//  Created by Rohit Sahay on 29/07/26.
//

import Foundation

/// Bounded, thread-safe store of captured exchanges.
///
/// A busy screen produces thousands of exchanges in a long session, so this is
/// a ring buffer: at capacity the oldest is evicted. Nothing here touches disk
/// — persistence is out of scope for milestone 1, and when it arrives it will
/// only ever see already-redacted exchanges.
public final class ExchangeStore: @unchecked Sendable {

    private let lock = NSLock()
    private var storage: [NetworkExchange] = []
    private var observers: [UUID: @Sendable () -> Void] = [:]
    private var exchangeObservers: [UUID: @Sendable (NetworkExchange) -> Void] = [:]

    /// Maximum retained exchanges. Setting a lower value evicts immediately.
    public private(set) var capacity: Int

    public init(capacity: Int = 500) {
        self.capacity = max(1, capacity)
        storage.reserveCapacity(min(self.capacity, 128))
    }

    // MARK: - Reads

    /// Oldest first. Views that want newest-first reverse at the call site.
    public var exchanges: [NetworkExchange] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    public func exchange(id: UUID) -> NetworkExchange? {
        lock.lock()
        defer { lock.unlock() }
        return storage.first { $0.id == id }
    }

    // MARK: - Writes

    /// Appends, evicting the oldest once capacity is exceeded.
    public func record(_ exchange: NetworkExchange) {
        lock.lock()
        storage.append(exchange)
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
        lock.unlock()
        notify(exchange)
    }

    /// Appends, or replaces in place if an exchange with this id is already
    /// held.
    ///
    /// Interception records an exchange in flight so the overlay shows the row
    /// while it is pending, then records it again on completion. Appending
    /// twice would double-count; replacing keeps the row where the user last
    /// saw it rather than jumping it to the top.
    public func upsert(_ exchange: NetworkExchange) {
        lock.lock()
        if let index = storage.firstIndex(where: { $0.id == exchange.id }) {
            storage[index] = exchange
        } else {
            storage.append(exchange)
            if storage.count > capacity {
                storage.removeFirst(storage.count - capacity)
            }
        }
        lock.unlock()
        notify(exchange)
    }

    /// Replaces an exchange in place, keeping its position in the buffer.
    ///
    /// Used when a response lands for a request recorded earlier. A no-op if
    /// the exchange has already been evicted, which is correct — a completion
    /// for something the user can no longer see should not resurrect it.
    @discardableResult
    public func update(id: UUID, transform: (NetworkExchange) -> NetworkExchange) -> Bool {
        lock.lock()
        guard let index = storage.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return false
        }
        let updated = transform(storage[index])
        storage[index] = updated
        lock.unlock()
        notify(updated)
        return true
    }

    public func removeAll() {
        lock.lock()
        storage.removeAll(keepingCapacity: true)
        lock.unlock()
        notify()
    }

    public func setCapacity(_ newCapacity: Int) {
        lock.lock()
        capacity = max(1, newCapacity)
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
        lock.unlock()
        notify()
    }

    // MARK: - Observation

    /// Change notifications for the overlay.
    ///
    /// A closure registry rather than Combine: Core stays Foundation-only and
    /// usable from a headless test process, and the UI target adapts this to
    /// whatever it needs. Callbacks fire outside the lock, on the writing
    /// thread — observers must hop to their own queue.
    public func addObserver(_ observer: @escaping @Sendable () -> Void) -> ObservationToken {
        let id = UUID()
        lock.lock()
        observers[id] = observer
        lock.unlock()
        return ObservationToken(id: id) { [weak self] id in
            self?.removeObserver(id)
        }
    }

    /// Change notifications that carry the exchange just written.
    ///
    /// The payload-free variant above forces a subscriber to re-read the whole
    /// buffer to find what moved, which is O(n) per request and races with
    /// eviction — the exchange it is looking for may already be gone. A trace
    /// sink needs the bytes that were written, not a hint that something was.
    ///
    /// Fires for every write, so an exchange recorded in flight and completed
    /// later arrives twice. Subscribers that want finished traffic only filter
    /// on `isInFlight`.
    public func addExchangeObserver(
        _ observer: @escaping @Sendable (NetworkExchange) -> Void
    ) -> ObservationToken {
        let id = UUID()
        lock.lock()
        exchangeObservers[id] = observer
        lock.unlock()
        return ObservationToken(id: id) { [weak self] id in
            self?.removeExchangeObserver(id)
        }
    }

    private func removeExchangeObserver(_ id: UUID) {
        lock.lock()
        exchangeObservers[id] = nil
        lock.unlock()
    }

    private func removeObserver(_ id: UUID) {
        lock.lock()
        observers[id] = nil
        lock.unlock()
    }

    /// `written` is the exchange this call wrote, or nil for a bulk change
    /// that names no single one (`removeAll`, `setCapacity`).
    private func notify(_ written: NetworkExchange? = nil) {
        lock.lock()
        let plain = Array(observers.values)
        let detailed = written == nil ? [] : Array(exchangeObservers.values)
        lock.unlock()
        for observer in plain { observer() }
        guard let written else { return }
        for observer in detailed { observer(written) }
    }

    /// Deregisters its observer when released.
    public final class ObservationToken: Sendable {
        private let id: UUID
        private let cancel: @Sendable (UUID) -> Void

        init(id: UUID, cancel: @escaping @Sendable (UUID) -> Void) {
            self.id = id
            self.cancel = cancel
        }

        deinit { cancel(id) }
    }
}
