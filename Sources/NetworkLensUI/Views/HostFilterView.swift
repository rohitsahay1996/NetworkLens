//
//  HostFilterView.swift
//  NetworkLensUI
//
//  Created by Rohit Sahay on 20/08/26.
//

#if canImport(UIKit)
import SwiftUI
import NetworkLensCore

/// Which hosts the traffic list shows, and what the bubble's badge counts.
///
/// Stores what is *hidden* rather than what is shown. A filter that stored the
/// shown set would silently drop every domain first seen after it was set —
/// which, on a real app, is usually the third-party SDK the tester went looking
/// for in the first place.
///
/// Persisted across launches, unlike breakpoints and mocks. Narrowing to one
/// host is how the tool gets used for a whole afternoon on one endpoint, and
/// re-picking it after every relaunch made the filter not worth setting.
///
/// The objection that keeps `keepBreakpointsAcrossLaunches` off — a forgotten
/// setting reads as a broken tool — is answered rather than dismissed: nothing
/// here changes capture, and the filter announces itself in three places. The
/// Traffic header counts "N of M hosts", the empty state names the filter as
/// the reason, and the bubble carries a filter glyph while any host is hidden.
/// Sticky state is only dangerous when it is invisible.
///
/// Lives in `UserDefaults` next to the bubble's position, not in Application
/// Support: it is where the tester put the window, not data about the app.
@MainActor
final class HostFilter: ObservableObject {

    static let shared = HostFilter()

    private static let hiddenKey = "com.networklens.hostfilter.hidden"

    // A property with a wrapper cannot carry a `didSet`, so persistence is
    // called from each mutator instead. Three call sites, all in this type.
    @Published private(set) var hidden: Set<String>

    private init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.hiddenKey) ?? []
        hidden = Set(stored.filter { !$0.isEmpty })
    }

    var isActive: Bool { !hidden.isEmpty }

    func isVisible(_ host: String) -> Bool { !hidden.contains(host) }

    func setVisible(_ visible: Bool, host: String) {
        if visible {
            hidden.remove(host)
        } else {
            hidden.insert(host)
        }
        persist()
    }

    func showAll() {
        hidden = []
        persist()
    }

    /// Hides everything currently known. Takes the hosts rather than deriving
    /// them, because "all" means the hosts on screen — a host that shows up
    /// after this is new traffic and gets to appear.
    func hideAll(_ hosts: [String]) {
        hidden = Set(hosts)
        persist()
    }

    /// Written on every change rather than at teardown: a debugging tool is
    /// routinely killed from Xcode, and a filter saved only on the way out
    /// would be the one that never survives.
    private func persist() {
        let defaults = UserDefaults.standard
        guard !hidden.isEmpty else {
            defaults.removeObject(forKey: Self.hiddenKey)
            return
        }
        defaults.set(Array(hidden).sorted(), forKey: Self.hiddenKey)
    }

    /// Only the hidden hosts still present in this session. Traffic gets
    /// cleared, and a count of hidden hosts that no longer exist would keep the
    /// filter badge lit over nothing.
    func activeHidden(among hosts: [String]) -> Set<String> {
        hidden.intersection(hosts)
    }
}

extension NetworkExchange {

    /// The host, or a stand-in for the requests that have none. Named rather
    /// than dropped: a URL with no host is still traffic, and something that
    /// cannot be filtered can never be filtered *out*.
    var hostLabel: String { request.url.host ?? "no host" }
}

/// Publishes `HostLock` to SwiftUI.
///
/// The lock lives in Core, where the interception path can read it without a
/// hop to the main actor, so it is not an `ObservableObject`. This is the thin
/// adapter rather than a second source of truth: every mutation goes straight
/// through to `HostLock.shared`, and `hosts` is republished from it.
@MainActor
final class HostLockState: ObservableObject {

    static let shared = HostLockState()

    @Published private(set) var hosts: Set<String>

    private init() {
        hosts = HostLock.shared.hosts
    }

    var isLocked: Bool { !hosts.isEmpty }

    func lock(to hosts: [String]) {
        HostLock.shared.lock(to: hosts)
        self.hosts = HostLock.shared.hosts
    }

    /// One host at a time, which is how the list is actually used: lock this
    /// one, then that one, without unlocking anything first.
    func toggle(_ host: String) {
        HostLock.shared.toggle(host)
        hosts = HostLock.shared.hosts
    }

    func unlock() {
        HostLock.shared.unlock()
        hosts = HostLock.shared.hosts
    }

    func isPinned(_ host: String) -> Bool { hosts.contains(host.lowercased()) }
}

/// Every host the tool has been asked about, with what to do about each.
///
/// A `Section` rather than a screen of its own: it lives in the Session tab
/// alongside the totals, because "what did this app talk to" and "how much"
/// are the same question asked twice, and a sixth tab would have collapsed the
/// tab bar into a More list.
///
/// Two different controls, deliberately not merged. The checkmark is
/// visibility: what the Traffic list and the bubble badge show, with everything
/// still intercepted. The padlock is capture: while it is on, only the pinned
/// hosts are intercepted at all, and no host discovered afterwards joins them.
/// Merging them would mean a tester who hid a noisy CDN silently stopped being
/// able to mock it.
///
/// Rows come from `HostInventory`, not from the current buffer, so the list
/// stays complete while locked — a domain that is not being captured is still
/// listed, still named, and one tap away from being added to the lock.
struct HostFilterSection: View {

    @EnvironmentObject private var lens: LensObservable
    @ObservedObject var filter: HostFilter
    @ObservedObject private var lockState = HostLockState.shared

    var body: some View {
        Section {
            ForEach(hosts, id: \.host) { entry in
                HStack(spacing: 12) {
                    Button {
                        filter.setVisible(!filter.isVisible(entry.host), host: entry.host)
                    } label: {
                        row(for: entry)
                    }
                    // `.borderless` on both, so the row and the padlock stay two
                    // separate tap targets. A plain `List` row swallows the
                    // second button and fires whichever it feels like.
                    .buttonStyle(.borderless)

                    lockButton(for: entry.host)
                }
            }

            if !hosts.isEmpty {
                controls
            }
        } header: {
            header
        } footer: {
            Text(footerText)
        }
    }

    @ViewBuilder
    private func row(for entry: HostEntry) -> some View {
        let isPinned = lockState.isPinned(entry.host)
        // Two reasons a host reads as inactive, and they are different things:
        // unchecked means hidden from the list, unpinned-while-locked means not
        // captured at all.
        let isDimmed = lockState.isLocked ? !isPinned : !filter.isVisible(entry.host)
        HStack(spacing: 10) {
            Image(systemName: filter.isVisible(entry.host) ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(filter.isVisible(entry.host) ? Color.accentColor : Color.secondary)

            Text(entry.host)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(isDimmed ? .secondary : .primary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(lockState.isLocked && !isPinned ? "not captured" : "\(entry.count)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    /// The per-host padlock. Filled while pinned, open otherwise, and always
    /// tappable — including on a host the lock is currently excluding, which is
    /// exactly the row someone reaches for when adding a second domain.
    private func lockButton(for host: String) -> some View {
        let isPinned = lockState.isPinned(host)
        return Button {
            lockState.toggle(host)
        } label: {
            Image(systemName: isPinned ? "lock.fill" : "lock.open")
                .font(.footnote)
                .foregroundStyle(isPinned ? Color.accentColor : Color.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(isPinned ? "Stop capturing only \(host)" : "Capture only \(host)")
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 20) {
            Button("Show all") { filter.showAll() }
                .disabled(!filter.isActive)
            Button("Hide all") { filter.hideAll(hosts.map(\.host)) }
            // Locking is per row now, so the only bulk action left is the way
            // back — and it stays visible rather than replacing the others,
            // because the two controls are answering different questions.
            Button("Unlock all") { lockState.unlock() }
                .disabled(!lockState.isLocked)
            Spacer(minLength: 0)
        }
        .font(.footnote)
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private var header: some View {
        if lockState.isLocked {
            Text("Hosts · locked to \(lockState.hosts.count) "
                 + (lockState.hosts.count == 1 ? "host" : "hosts"))
        } else {
            // Busiest first: the host worth hiding is nearly always the one
            // flooding the list, and alphabetical buries it.
            Text(hosts.isEmpty
                 ? "Hosts"
                 : "Hosts · \(hosts.count) seen, busiest first")
        }
    }

    private var footerText: String {
        if lockState.isLocked {
            return "Padlocked hosts are the only ones being intercepted. Everything else — including any domain first seen from now on — is not captured, not mocked, not held, and writes no trace line. Tap another padlock to add a host to the lock; tap a closed one to drop it. Unpinned hosts stay listed so you can see what is being skipped."
        }
        return "The checkmark is visibility: it hides a host from the Traffic list and the bubble badge, and changes nothing about what is captured. The padlock is capture: lock one or more hosts and they become the only ones intercepted. Both survive relaunches."
    }

    struct HostEntry {
        let host: String
        let count: Int
    }

    /// Inventory first, so a host that is listed but not captured still has a
    /// row, then session counts layered on. Busiest first; hosts with no
    /// traffic this session sort last, alphabetically, rather than jumbling in
    /// among the zeroes.
    private var hosts: [HostEntry] {
        var counts: [String: Int] = [:]
        for host in HostInventory.shared.hosts {
            counts[host] = 0
        }
        for exchange in lens.exchanges {
            counts[exchange.hostLabel, default: 0] += 1
        }
        return counts
            .map { HostEntry(host: $0.key, count: $0.value) }
            .sorted { $0.count == $1.count ? $0.host < $1.host : $0.count > $1.count }
    }
}
#endif
