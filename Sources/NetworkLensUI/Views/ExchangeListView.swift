//
//  ExchangeListView.swift
//  NetworkLensUI
//
//  Created by Rohit Sahay on 30/07/26.
//

#if canImport(UIKit)
import SwiftUI
import NetworkLensCore

/// The captured traffic, newest first.
struct ExchangeListView: View {

    /// Sends the tester to the host list, which lives in the Session tab.
    /// Passed in rather than reached for: this view does not own the tab bar,
    /// and a filter bar that silently did nothing when hosted elsewhere would
    /// be worse than no filter bar.
    var showHosts: () -> Void = {}

    @EnvironmentObject private var lens: LensObservable
    @ObservedObject private var filter = HostFilter.shared
    @State private var query = ""
    @State private var groupsByScreen = false

    var body: some View {
        VStack(spacing: 0) {
            // Pinned above the list rather than parked in the navigation bar.
            // The bar's leading side already carries Done and the grouping
            // toggle, so a third icon there is squeezed against the title and
            // routinely missed — and a filter nobody can find is a filter that
            // gets left on. Here it also states what it is doing.
            filterBar
            Divider()
            list
        }
    }

    /// Reports what it made, since the rules land in another tab and a button
    /// that appears to do nothing gets pressed again.
    private func capture(_ group: (screen: String, exchanges: [NetworkExchange])) {
        let result = lens.captureScreen(named: group.screen, from: Array(group.exchanges.reversed()))
        if result.rules == 0 && result.scenarios == 0 {
            lens.notice = "Nothing to mock on \(group.screen) — no responses captured yet."
        } else {
            lens.notice = "\(group.screen): \(result.rules) rule(s), \(result.scenarios) scenario(s). Open Mocks to run them."
        }
    }

    private var list: some View {
        List {
            if groupsByScreen {
                ForEach(groupedResults, id: \.screen) { group in
                    Section {
                        ForEach(group.exchanges) { row($0) }
                    } header: {
                        HStack {
                            Text(group.screen)
                            Spacer()
                            // Re-fires the screen's calls together, which is
                            // the only way to reproduce their interleaving.
                            // Fired from the group as shown, so a host hidden
                            // by the filter is not silently replayed with it.
                            Button {
                                lens.replay(Array(group.exchanges.reversed()))
                            } label: {
                                Label("Replay all", systemImage: "arrow.clockwise")
                                    .font(.caption2)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)

                            // A screen's traffic as one block, which is the
                            // unit a bug report is usually about.
                            Button {
                                lens.copyCurl(for: Array(group.exchanges.reversed()))
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                                    .font(.caption2)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)

                            // One tap for the whole authoring step: every
                            // endpoint on this screen gets a rule carrying its
                            // captured response plus the standard variants, and
                            // the screen gets a scenario per state. Typing that
                            // by hand is the reason most people never mock at
                            // all.
                            Button {
                                capture(group)
                            } label: {
                                Label("Mock screen", systemImage: "wand.and.stars")
                                    .font(.caption2)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            } else {
                ForEach(results) { row($0) }
            }
        }
        .listStyle(.plain)
        .searchable(text: $query, prompt: "Endpoint, URL or screen")
        // Whatever the tool decided on its own — a replay it could not send, an
        // auto-resume it fired. Silence here is what makes a tester conclude the
        // button is broken.
        .alert(
            Text(lens.notice ?? ""),
            isPresented: Binding(
                get: { lens.notice != nil },
                set: { if !$0 { lens.notice = nil } }
            )
        ) {
            Button("OK", role: .cancel) { lens.notice = nil }
        }
        .overlay {
            if results.isEmpty { emptyState }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    groupsByScreen.toggle()
                } label: {
                    Image(systemName: groupsByScreen
                        ? "rectangle.3.group.fill"
                        : "rectangle.3.group")
                }
                .accessibilityLabel("Group by screen")
            }
            // A screen's calls park together, so releasing them one at a time
            // means the screen never reaches its loaded state all at once.
            //
            // The condition lives inside the item rather than around it:
            // `if` between toolbar items is iOS 16, and this package supports 15.
            ToolbarItem(placement: .navigationBarTrailing) {
                if lens.hasHangingRequests {
                    Button {
                        lens.releaseAllHangs()
                    } label: {
                        Label("Load all", systemImage: "play.circle.fill")
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Clear") { lens.clear() }
                    .disabled(lens.exchanges.isEmpty)
            }
        }
        .navigationTitle("Traffic")
    }

    private func row(_ exchange: NetworkExchange) -> some View {
        NavigationLink {
            ExchangeDetailView(exchange: exchange)
                .environmentObject(lens)
        } label: {
            ExchangeRow(
                exchange: exchange,
                isHeld: lens.isHeld(exchange),
                isHanging: lens.isHanging(exchange),
                // Only while mocks are serving. With nothing armed, every row is
                // live and a LIVE badge on all of them is noise; once something
                // is faked, the distinction is the most important thing on screen.
                showsLiveBadge: lens.isServingMocks
            )
        }
        // Releasing a hold has to be reachable from the list, not only from the
        // breakpoint sheet. Queued holds never get a sheet at all, and a row
        // stopped with no way to start it reads as the tool having hung the app.
        .swipeActions(edge: .leading) {
            if lens.isHeld(exchange) {
                Button {
                    lens.resume(exchange)
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .tint(.green)
            }
            if lens.isHanging(exchange) {
                Button {
                    lens.releaseHang(exchange)
                } label: {
                    Label("Load", systemImage: "play.circle.fill")
                }
                .tint(.green)
            }
            if lens.canReplay(exchange) {
                Button {
                    lens.replay(exchange)
                } label: {
                    Label("Replay", systemImage: "arrow.clockwise")
                }
                .tint(.blue)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                lens.copyCurl(for: exchange)
            } label: {
                Label("cURL", systemImage: "doc.on.doc")
            }
            .tint(.gray)
        }
    }

    /// Always-visible entry to the host filter, reading as its own state.
    ///
    /// Says how many hosts are showing rather than only that a filter exists:
    /// traffic missing from the list is otherwise indistinguishable from
    /// capture having stopped working, which is the single worst thing a
    /// debugging tool can be ambiguous about.
    private var filterBar: some View {
        HStack(spacing: 8) {
            Button {
                showHosts()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: hiddenHostCount > 0
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle")
                    Text(filterLabel)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(hiddenHostCount > 0 ? Color.accentColor : Color.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            // One tap back to everything, without opening the sheet to find it.
            if hiddenHostCount > 0 {
                Button("Show all") { filter.showAll() }
                    .font(.footnote)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }

    private var filterLabel: String {
        let total = hostCount
        guard hiddenHostCount > 0 else {
            return total == 0 ? "All hosts" : "All \(total) hosts"
        }
        return "\(total - hiddenHostCount) of \(total) hosts"
    }

    private var hostCount: Int {
        Set(lens.exchanges.map(\.hostLabel)).count
    }

    private var results: [NetworkExchange] {
        let visible = lens.exchanges.filter { filter.isVisible($0.hostLabel) }
        guard !query.isEmpty else { return visible }
        let needle = query.lowercased()
        return visible.filter {
            $0.endpointKey.lowercased().contains(needle)
                || $0.request.url.absoluteString.lowercased().contains(needle)
                || ($0.screen?.lowercased().contains(needle) ?? false)
        }
    }

    /// Counted against what is actually in the buffer. A host hidden before
    /// `Clear` would otherwise keep the filter badge lit over nothing.
    private var hiddenHostCount: Int {
        filter.activeHidden(among: lens.exchanges.map(\.hostLabel)).count
    }

    /// Says which of the three reasons the list is empty for. "No traffic yet"
    /// in front of a tester who has just hidden every host is the tool lying
    /// about its own state.
    @ViewBuilder
    private var emptyState: some View {
        if lens.exchanges.isEmpty {
            EmptyStateView(
                title: "No traffic yet",
                message: "Requests appear here as the app makes them.",
                systemImage: "antenna.radiowaves.left.and.right"
            )
        } else if filteredOutEverything {
            EmptyStateView(
                title: "Every host is hidden",
                message: "\(hiddenHostCount) \(hiddenHostCount == 1 ? "host is" : "hosts are") "
                    + "filtered out. Tap Show all, or pick hosts in the Session tab.",
                systemImage: "line.3.horizontal.decrease.circle.fill"
            )
        } else {
            EmptyStateView(
                title: "No matches",
                message: "Nothing captured matches “\(query)”.",
                systemImage: "antenna.radiowaves.left.and.right"
            )
        }
    }

    /// True when the filter, rather than the search field, is what emptied the
    /// list.
    private var filteredOutEverything: Bool {
        !lens.exchanges.isEmpty && !lens.exchanges.contains { filter.isVisible($0.hostLabel) }
    }

    private var groupedResults: [(screen: String, exchanges: [NetworkExchange])] {
        var order: [String] = []
        var buckets: [String: [NetworkExchange]] = [:]
        for exchange in results {
            let screen = exchange.screen ?? "Unattributed"
            if buckets[screen] == nil { order.append(screen) }
            buckets[screen, default: []].append(exchange)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }
}

struct ExchangeRow: View {

    let exchange: NetworkExchange
    /// Stopped at a breakpoint rather than merely slow. Without this the two
    /// look identical — a spinner — and the held one never ends.
    var isHeld = false
    /// Parked by a hang mock. Distinct from held: nobody is editing it, it is
    /// deliberately sitting in the loading state until someone lets it go.
    var isHanging = false
    /// Badge live rows too, so "no badge" stops meaning "probably real".
    var showsLiveBadge = false

    var body: some View {
        // Status over method in their own leading column, so the paths start at
        // the same x down the whole list — the thing the eye actually scans.
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                state
                MethodBadge(method: exchange.request.method)
            }
            .frame(minWidth: 52, alignment: .leading)

            detail
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var state: some View {
        if isHeld {
            Label("HELD", systemImage: "pause.fill")
                .font(.caption2.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.orange.opacity(0.18)))
                .foregroundStyle(Color.orange)
        } else if isHanging {
            Label("LOADING", systemImage: "hourglass")
                .font(.caption2.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.purple.opacity(0.18)))
                .foregroundStyle(Color.purple)
        } else {
            StatusPill(exchange: exchange)
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(exchange.endpointPath)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 4)
                if let total = exchange.timing?.total {
                    Text(formatDuration(total))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 6) {
                if exchange.source.isSynthetic || showsLiveBadge {
                    SourceBadge(source: exchange.source)
                }
                // Says the tool fired it, not the app — worth knowing on a
                // screen where some rows are real traffic and some are repeats.
                if exchange.isReplay {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
                if let screen = exchange.screen {
                    Text(screen)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(exchange.request.url.host ?? "")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }
}
#endif
