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

    @EnvironmentObject private var lens: LensObservable
    @State private var query = ""
    @State private var groupsByScreen = false

    var body: some View {
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
                            Button {
                                lens.replayScreen(group.screen)
                            } label: {
                                Label("Replay all", systemImage: "arrow.clockwise")
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
        .overlay {
            if results.isEmpty {
                EmptyStateView(
                    title: query.isEmpty ? "No traffic yet" : "No matches",
                    message: query.isEmpty
                        ? "Requests appear here as the app makes them."
                        : "Nothing captured matches “\(query)”.",
                    systemImage: "antenna.radiowaves.left.and.right"
                )
            }
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
    }

    private var results: [NetworkExchange] {
        let all = lens.exchanges
        guard !query.isEmpty else { return all }
        let needle = query.lowercased()
        return all.filter {
            $0.endpointKey.lowercased().contains(needle)
                || $0.request.url.absoluteString.lowercased().contains(needle)
                || ($0.screen?.lowercased().contains(needle) ?? false)
        }
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
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
                Text(exchange.endpointKey)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
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
        .padding(.vertical, 2)
    }
}
#endif
