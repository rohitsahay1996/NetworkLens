#if canImport(UIKit)
import SwiftUI
import NetworkLensCore

/// Session totals, the endpoints doing the most work, and where failures land.
struct SessionStatsView: View {

    @EnvironmentObject private var lens: LensObservable

    var body: some View {
        List {
            Section("Session") {
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
                    title: "Nothing to report",
                    message: "Stats fill in as the app makes requests.",
                    systemImage: "chart.bar"
                )
            }
        }
        .navigationTitle("Stats")
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
