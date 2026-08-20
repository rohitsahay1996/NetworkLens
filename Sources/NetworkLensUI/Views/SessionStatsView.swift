//
//  SessionStatsView.swift
//  NetworkLensUI
//
//  Created by Rohit Sahay on 30/07/26.
//

#if canImport(UIKit)
import SwiftUI
import NetworkLensCore

/// What this session talked to, how much, and where it went wrong.
///
/// The host filter leads because it is the only thing on this screen that is a
/// control rather than a reading, and because it is what someone opens this tab
/// to *do*. The totals below it are unfiltered on purpose: hiding a host is a
/// statement about the traffic list, not a claim that the requests never
/// happened.
struct SessionStatsView: View {

    @EnvironmentObject private var lens: LensObservable
    @ObservedObject private var filter = HostFilter.shared

    var body: some View {
        List {
            HostFilterSection(filter: filter)

            Section("Totals") {
                LabelledRow(label: "Requests", value: "\(stats.totalRequests)")
                LabelledRow(label: "In flight", value: "\(stats.inFlightCount)")
                LabelledRow(label: "Failures", value: "\(stats.totalFailures)")
            }

            if !stats.countsBySource.isEmpty {
                Section("Provenance") {
                    ForEach(sortedSources, id: \.0) { source, count in
                        HStack {
                            SourceBadge(source: source)
                            Spacer()
                            Text("\(count)").font(.subheadline)
                        }
                    }
                }
            }

            if !stats.failuresByKind.isEmpty {
                Section("Failures") {
                    ForEach(FailureInfo.Kind.allCases, id: \.self) { kind in
                        if let count = stats.failuresByKind[kind], count > 0 {
                            LabelledRow(label: kind.rawValue, value: "\(count)")
                        }
                    }
                }
            }

            Section("Endpoints") {
                ForEach(stats.endpoints) { stat in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(stat.endpointKey)
                            .font(.system(.footnote, design: .monospaced))
                            .lineLimit(1)
                        HStack(spacing: 8) {
                            Text("\(stat.count)×").font(.caption2)
                            if stat.failureCount > 0 {
                                Text("\(stat.failureCount) failed")
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                            }
                            if let average = stat.averageDuration {
                                Text("avg \(formatDuration(average))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
        }
        .overlay {
            if stats.totalRequests == 0 {
                EmptyStateView(
                    title: "Nothing yet",
                    message: "Hosts and totals fill in as the app makes requests.",
                    systemImage: "chart.bar"
                )
            }
        }
        .navigationTitle("Session")
    }

    private var stats: SessionStats { lens.stats }

    /// Sorted by count so the busiest provenance leads, with a stable label
    /// tiebreak — dictionary order would reshuffle the list on every refresh.
    private var sortedSources: [(Source, Int)] {
        stats.countsBySource
            .sorted { ($0.value, $1.key.label) > ($1.value, $0.key.label) }
            .map { ($0.key, $0.value) }
    }
}
#endif
