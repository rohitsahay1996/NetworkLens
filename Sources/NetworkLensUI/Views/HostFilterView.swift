//
//  HostFilterView.swift
//  NetworkLensUI
//
//  Created by Rohit Sahay on 20/08/26.
//

#if canImport(UIKit)
import SwiftUI
import NetworkLensCore

/// Which hosts the traffic list shows.
///
/// Stores what is *hidden* rather than what is shown. A filter that stored the
/// shown set would silently drop every domain first seen after it was set —
/// which, on a real app, is usually the third-party SDK the tester went looking
/// for in the first place.
///
/// Deliberately not persisted across launches, for the same reason
/// `keepBreakpointsAcrossLaunches` defaults off: a forgotten filter that hides
/// half the traffic is indistinguishable from capture having stopped working.
@MainActor
final class HostFilter: ObservableObject {

    static let shared = HostFilter()

    @Published private(set) var hidden: Set<String> = []

    var isActive: Bool { !hidden.isEmpty }

    func isVisible(_ host: String) -> Bool { !hidden.contains(host) }

    func setVisible(_ visible: Bool, host: String) {
        if visible {
            hidden.remove(host)
        } else {
            hidden.insert(host)
        }
    }

    func showAll() { hidden = [] }

    /// Hides everything currently known. Takes the hosts rather than deriving
    /// them, because "all" means the hosts on screen — a host that shows up
    /// after this is new traffic and gets to appear.
    func hideAll(_ hosts: [String]) { hidden = Set(hosts) }

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

/// Every host this session has seen, with what to do about each.
///
/// Counts come from the whole capture, not from what is currently shown —
/// otherwise hiding a host would drop it off its own filter list and there
/// would be no way back.
struct HostFilterSheet: View {

    @EnvironmentObject private var lens: LensObservable
    @ObservedObject var filter: HostFilter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section {
                    ForEach(hosts, id: \.host) { entry in
                        Button {
                            filter.setVisible(!filter.isVisible(entry.host), host: entry.host)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: filter.isVisible(entry.host)
                                    ? "checkmark.circle.fill"
                                    : "circle")
                                    .foregroundStyle(filter.isVisible(entry.host)
                                        ? Color.accentColor
                                        : Color.secondary)

                                Text(entry.host)
                                    .font(.system(.subheadline, design: .monospaced))
                                    .foregroundStyle(filter.isVisible(entry.host)
                                        ? .primary
                                        : .secondary)
                                    .lineLimit(1)

                                Spacer(minLength: 8)

                                Text("\(entry.count)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    // Busiest first: the host worth hiding is nearly always the
                    // one flooding the list, and alphabetical buries it.
                    Text("\(hosts.count) \(hosts.count == 1 ? "host" : "hosts") · busiest first")
                } footer: {
                    Text("Hides rows from the traffic list only. Nothing here changes what is captured, mocked or held — a hidden host is still intercepted, and still counted under Stats.")
                }

                Section {
                    Button("Show all") { filter.showAll() }
                        .disabled(!filter.isActive)
                    Button("Hide all") { filter.hideAll(hosts.map(\.host)) }
                        .disabled(hosts.isEmpty)
                } footer: {
                    Text("A host first seen after this appears anyway. The filter remembers what to hide, not what to show, so new traffic is never silently dropped.")
                }
            }
            .navigationTitle("Filter by host")
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                if hosts.isEmpty {
                    EmptyStateView(
                        title: "No traffic yet",
                        message: "Hosts appear here as the app makes requests.",
                        systemImage: "globe"
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var hosts: [(host: String, count: Int)] {
        var counts: [String: Int] = [:]
        for exchange in lens.exchanges {
            counts[exchange.hostLabel, default: 0] += 1
        }
        return counts
            .map { (host: $0.key, count: $0.value) }
            .sorted { $0.count == $1.count ? $0.host < $1.host : $0.count > $1.count }
    }
}
#endif
