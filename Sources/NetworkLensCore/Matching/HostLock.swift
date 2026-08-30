//
//  HostLock.swift
//  NetworkLensCore
//
//  Created by Rohit Sahay on 28/08/26.
//

import Foundation

/// A capture allowlist the tester can pin at runtime, overriding
/// `capturedHostPatterns` for as long as it is locked.
///
/// `capturedHostPatterns` is decided at `start()`, by the app, in code. That is
/// the wrong place for the thing this solves: someone narrows the lens to one
/// backend on one screen, navigates, and the next screen's SDKs and CDNs pour
/// into the ring buffer and evict what they were reading. The host filter in the
/// UI could not help — it hides rows, it does not stop interception.
///
/// So this is deliberately capture, not visibility: a host outside a live lock
/// is not intercepted, takes no buffer slot, writes no trace line, and cannot be
/// mocked or held. Same contract as `capturedHostPatterns`, decided later and by
/// a different person.
///
/// Exact host matches only — no suffix or wildcard matching. The set comes from
/// hosts the tool itself listed, so there is nothing to pattern-match against,
/// and a lock that quietly admitted `eu.api.acme.com` because `api.acme.com` was
/// pinned would not be a lock.
///
/// Persisted, and applied before the first request of the next launch: a lock
/// that lasted only until the app was killed from Xcode would be gone by the
/// time the flow being debugged came back.
public final class HostLock: @unchecked Sendable {

    public static let shared = HostLock()

    private static let hostsKey = "com.networklens.hostlock.hosts"

    // Named `mutex` rather than `lock`: this type also has a `lock(to:)`, and
    // a bare `lock` beside it reads as a reference to that method.
    private let mutex = NSLock()
    private var _hosts: Set<String>
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.stringArray(forKey: Self.hostsKey) ?? []
        _hosts = Set(stored.map { $0.lowercased() }.filter { !$0.isEmpty })
    }

    /// The pinned hosts, or empty when nothing is locked.
    public var hosts: Set<String> {
        mutex.lock()
        defer { mutex.unlock() }
        return _hosts
    }

    public var isLocked: Bool {
        mutex.lock()
        defer { mutex.unlock() }
        return !_hosts.isEmpty
    }

    /// Pins exactly these hosts. An empty set unlocks rather than locking
    /// everything out — a lock that captures nothing is indistinguishable from
    /// the tool being broken, and is never what someone meant to ask for.
    public func lock(to hosts: some Sequence<String>) {
        let normalized = Set(hosts.map { $0.lowercased() }.filter { !$0.isEmpty })
        mutex.lock()
        _hosts = normalized
        mutex.unlock()
        persist(normalized)
    }

    /// Adds one host to the lock, starting it if nothing was locked.
    ///
    /// The per-host entry point, and the one the UI uses. Locking a second
    /// domain must not mean unlocking the first and re-picking both — that is
    /// how a lock stops being used at all.
    public func pin(_ host: String) {
        let normalized = host.lowercased()
        guard !normalized.isEmpty else { return }
        mutex.lock()
        _hosts.insert(normalized)
        let snapshot = _hosts
        mutex.unlock()
        persist(snapshot)
    }

    /// Removes one host. Removing the last one unlocks entirely rather than
    /// leaving a lock that captures nothing.
    public func unpin(_ host: String) {
        let normalized = host.lowercased()
        mutex.lock()
        _hosts.remove(normalized)
        let snapshot = _hosts
        mutex.unlock()
        persist(snapshot)
    }

    @discardableResult
    public func toggle(_ host: String) -> Bool {
        let normalized = host.lowercased()
        mutex.lock()
        let isPinned = _hosts.contains(normalized)
        if isPinned {
            _hosts.remove(normalized)
        } else if !normalized.isEmpty {
            _hosts.insert(normalized)
        }
        let snapshot = _hosts
        mutex.unlock()
        persist(snapshot)
        return !isPinned
    }

    public func isPinned(_ host: String) -> Bool {
        mutex.lock()
        defer { mutex.unlock() }
        return _hosts.contains(host.lowercased())
    }

    public func unlock() {
        mutex.lock()
        _hosts = []
        mutex.unlock()
        persist([])
    }

    /// The lock's verdict on a host, or nil when no lock is live and the
    /// configuration's own allowlist should decide.
    ///
    /// A `nil` host is refused while locked, for the reason
    /// `capturesHost` refuses it: a malformed URL cannot be shown to be one of
    /// the hosts that were pinned, and an allowlist admitting unknowns is not an
    /// allowlist.
    public func verdict(for host: String?) -> Bool? {
        mutex.lock()
        let pinned = _hosts
        mutex.unlock()
        guard !pinned.isEmpty else { return nil }
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        return pinned.contains(host)
    }

    private func persist(_ hosts: Set<String>) {
        guard !hosts.isEmpty else {
            defaults.removeObject(forKey: Self.hostsKey)
            return
        }
        defaults.set(hosts.sorted(), forKey: Self.hostsKey)
    }
}

/// Every host the lens has been asked about, whether or not it was captured.
///
/// Exists because a lock would otherwise erase its own escape route. Interception
/// is what teaches the tool a host exists, so pinning one host means the next
/// unknown domain never appears in any list — and the tester has no way to add
/// it to the lock, having never been told it was there.
///
/// Recorded from the capture gate rather than from the store, which is the one
/// place that sees a host before the decision to drop it. So the Hosts list stays
/// complete under a lock: every domain still listed, only the pinned ones
/// intercepted.
///
/// Persisted for the same reason the lock is, and capped: an app talking to a
/// per-request CDN shard would otherwise grow this without bound.
public final class HostInventory: @unchecked Sendable {

    public static let shared = HostInventory()

    private static let hostsKey = "com.networklens.hostinventory.hosts"
    private static let capacity = 200

    private let lock = NSLock()
    private var _hosts: Set<String>
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.stringArray(forKey: Self.hostsKey) ?? []
        _hosts = Set(stored.map { $0.lowercased() }.filter { !$0.isEmpty })
    }

    public var hosts: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return _hosts
    }

    /// On the request path, so the common case — a host already known — is a
    /// set lookup under a lock and nothing else. Only a genuinely new host
    /// reaches `UserDefaults`.
    public func record(_ host: String?) {
        guard let host = host?.lowercased(), !host.isEmpty else { return }
        lock.lock()
        guard !_hosts.contains(host) else {
            lock.unlock()
            return
        }
        if _hosts.count >= Self.capacity {
            lock.unlock()
            return
        }
        _hosts.insert(host)
        let snapshot = _hosts
        lock.unlock()
        defaults.set(snapshot.sorted(), forKey: Self.hostsKey)
    }

    public func clear() {
        lock.lock()
        _hosts = []
        lock.unlock()
        defaults.removeObject(forKey: Self.hostsKey)
    }
}
