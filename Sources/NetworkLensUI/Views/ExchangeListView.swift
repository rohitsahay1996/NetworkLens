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
                    Section(group.screen) {
                        ForEach(group.exchanges) { row($0) }
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
            ExchangeRow(exchange: exchange)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                StatusPill(exchange: exchange)
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
                if exchange.source.isSynthetic {
                    SourceBadge(source: exchange.source)
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
