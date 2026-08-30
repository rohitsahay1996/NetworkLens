//
//  ScenarioGroupSection.swift
//  NetworkLensUI
//
//  Created by Rohit Sahay on 28/08/26.
//

#if canImport(UIKit)
import SwiftUI
import NetworkLensCore

/// One pack, collapsed by default, with the actions that apply to all of it.
///
/// A tester is handed several features at once. Thirty scenarios in one flat
/// list is unreadable, and worse than unreadable: three packs each contain an
/// "everything empty", and picking the wrong one silently tests the wrong
/// screen. Grouping by pack is what makes the list safe to hand over.
///
/// Collapsed by default with the expanded set remembered, because the pack
/// someone is working on today is the only one they want open, and reopening
/// the sheet should not undo that.
struct ScenarioGroupSection: View {

    let group: String
    let scenarios: [Scenario]

    @EnvironmentObject private var lens: LensObservable
    @ObservedObject var runner: ScenarioRunner
    @ObservedObject private var expansion = ScenarioGroupExpansion.shared

    let onApply: (Scenario) -> Void
    let onExport: ([Scenario], String) -> Void

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: expansion.binding(for: group)) {
                ForEach(scenarios) { scenario in
                    Button {
                        onApply(scenario)
                    } label: {
                        ScenarioRow(
                            scenario: scenario,
                            isApplied: lens.appliedScenario?.id == scenario.id
                        )
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    for index in offsets {
                        guard let scenario = scenarios[safe: index] else { continue }
                        Scenarios.shared.remove(id: scenario.id)
                    }
                }

                HStack(spacing: 20) {
                    Button("Run this pack") {
                        runner.start(scenarios, packName: group)
                    }
                    .disabled(runner.isRunning)

                    Button("Export") { onExport(scenarios, group) }

                    Spacer(minLength: 0)
                }
                .font(.footnote)
                .buttonStyle(.borderless)
            } label: {
                header
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(group)
                .font(.subheadline.weight(.semibold))

            if appliedCount > 0 {
                // Says which pack is in force while it is collapsed, which is
                // the whole risk of collapsing it.
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
            }

            Spacer(minLength: 4)

            Text("\(scenarios.count)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var appliedCount: Int {
        guard let applied = lens.appliedScenario else { return 0 }
        return scenarios.contains { $0.id == applied.id } ? 1 : 0
    }
}

/// Which groups are open, remembered across sheet presentations.
///
/// Not persisted to disk: a collapsed section hides nothing that matters and
/// carrying the state across launches is the kind of stale UI nobody asks for.
@MainActor
final class ScenarioGroupExpansion: ObservableObject {

    static let shared = ScenarioGroupExpansion()

    @Published private var expanded: Set<String> = []

    private init() {}

    func binding(for group: String) -> Binding<Bool> {
        Binding(
            get: { self.expanded.contains(group) },
            set: { isOpen in
                if isOpen {
                    self.expanded.insert(group)
                } else {
                    self.expanded.remove(group)
                }
            }
        )
    }
}

private extension Array {

    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
#endif
