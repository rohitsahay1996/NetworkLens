//
//  HangingRequests.swift
//  NetworkLensCore
//
//  Created by Rohit Sahay on 30/07/26.
//

import Foundation

/// The requests currently parked by a `.hang` outcome, and the switch that
/// lets them go.
///
/// A hang is the only mock outcome with no end of its own: a delay expires and
/// a failure fires, but a hang sits until the app's timeout kills it. That is
/// the right default for testing a stuck screen, and useless for the next
/// question a tester always asks — "fine, now let it load". Waiting out a 60s
/// timeout to see the loaded state is not testing, it is punishment.
///
/// Releasing does **not** synthesise a response. The request resumes exactly
/// where it was suspended and goes to the network, so the screen fills with
/// what the server would really have sent. A fabricated 200 here would make the
/// loaded state a fiction of the tool's making.
public final class HangingRequests: @unchecked Sendable {

    public static let shared = HangingRequests()

    private let lock = NSLock()
    /// Exchange ids currently parked, in the order they parked.
    private var parked: [UUID] = []
    /// Parked ids that have been told to proceed. The protocol clears its own
    /// entry when it notices, so this never grows past what is in flight.
    private var released: Set<UUID> = []
    private var observers: [UUID: () -> Void] = [:]

    public init() {}

    // MARK: - Registration, by the interception layer

    public func register(_ exchangeID: UUID) {
        lock.lock()
        if !parked.contains(exchangeID) { parked.append(exchangeID) }
        lock.unlock()
        notify()
    }

    /// Called when the request stops hanging, for any reason.
    public func unregister(_ exchangeID: UUID) {
        lock.lock()
        parked.removeAll { $0 == exchangeID }
        released.remove(exchangeID)
        lock.unlock()
        notify()
    }

    public func isReleased(_ exchangeID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return released.contains(exchangeID)
    }

    // MARK: - Reads and control, by the UI

    public var hanging: [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return parked
    }

    public func isHanging(_ exchangeID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return parked.contains(exchangeID)
    }

    /// Lets one parked request continue to the network.
    public func release(_ exchangeID: UUID) {
        lock.lock()
        guard parked.contains(exchangeID) else { return lock.unlock() }
        released.insert(exchangeID)
        lock.unlock()
        notify()
    }

    /// The escape hatch, for a screen whose calls are all parked at once.
    public func releaseAll() {
        lock.lock()
        released.formUnion(parked)
        lock.unlock()
        notify()
    }

    // MARK: - Observation

    public struct ObservationToken: Sendable {
        let id: UUID
        let cancel: @Sendable () -> Void
        public func invalidate() { cancel() }
    }

    public func addObserver(_ observer: @escaping () -> Void) -> ObservationToken {
        let id = UUID()
        lock.lock()
        observers[id] = observer
        lock.unlock()
        return ObservationToken(id: id) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.observers.removeValue(forKey: id)
            self.lock.unlock()
        }
    }

    private func notify() {
        lock.lock()
        let current = Array(observers.values)
        lock.unlock()
        for observer in current { observer() }
    }
}
