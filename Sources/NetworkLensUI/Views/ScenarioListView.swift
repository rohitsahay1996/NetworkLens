//
//  ScenarioListView.swift
//  NetworkLensUI
//
//  Created by Rohit Sahay on 30/07/26.
//

#if canImport(UIKit)
import SwiftUI
import NetworkLensCore

/// Saved setups across endpoints, and the one in force.
struct ScenarioListView: View {

    @EnvironmentObject private var lens: LensObservable
    @State private var isNaming = false
    @State private var newName = ""
    @State private var scopeScreen: String?
    @State private var notice: String?

    var body: some View {
        List {
            Section {
                Button {
                    scopeScreen = nil
                    newName = ""
                    isNaming = true
                } label: {
                    Label("Save the current setup…", systemImage: "square.and.arrow.down")
                }
                .disabled(lens.mocks.isEmpty)

                // Scoped to a screen, because that is the unit: the four calls
                // one screen makes, not every rule in the session.
                ForEach(screensWithMocks, id: \.self) { screen in
                    Button {
                        scopeScreen = screen
                        newName = screen
                        isNaming = true
                    } label: {
                        Label("Save just \(screen)…", systemImage: "rectangle.3.group")
                    }
                }
            } footer: {
                Text("A scenario is the combination — cart empty while promos are down — named and switched back to in one tap.")
            }

            Section("Scenarios") {
                ForEach(lens.scenarios) { scenario in
                    Button {
                        let outcome = lens.applyScenario(scenario)
                        notice = outcome.isComplete
                            ? "Applied \(scenario.name)"
                            : "Applied \(outcome.applied), \(outcome.missing.count) missing"
                    } label: {
                        ScenarioRow(
                            scenario: scenario,
                            isApplied: lens.appliedScenario?.id == scenario.id
                        )
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    for index in offsets { lens.removeScenario(lens.scenarios[index]) }
                }
            }
        }
        .overlay {
            if lens.scenarios.isEmpty {
                EmptyStateView(
                    title: "No scenarios",
                    message: "Set a screen's endpoints to the states you want, then save the combination.",
                    systemImage: "square.stack.3d.down.right"
                )
            }
        }
        .overlay(alignment: .bottom) {
            if let notice {
                Text(notice)
                    .font(.footnote)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.thinMaterial))
                    .padding(.bottom, 16)
                    .task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        withAnimation { self.notice = nil }
                    }
            }
        }
        .alert("Name this setup", isPresented: $isNaming) {
            TextField("“checkout, promos down”", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                let scenario = lens.saveScenario(named: trimmed, forScreen: scopeScreen)
                notice = "Saved \(scenario.entries.count) endpoints"
            }
        } message: {
            Text("Records which variant each mocked endpoint is on right now.")
        }
        .navigationTitle("Scenarios")
    }

    /// Screens that actually have something mocked — offering to save a screen
    /// with no rules would produce an empty scenario.
    private var screensWithMocks: [String] {
        let mockedKeys = Set(lens.mocks.map(\.endpointKey))
        var seen: [String] = []
        for exchange in lens.exchanges {
            let screen = exchange.screen ?? "Unattributed"
            guard mockedKeys.contains(exchange.endpointKey), !seen.contains(screen) else {
                continue
            }
            seen.append(screen)
        }
        return seen
    }
}

struct ScenarioRow: View {

    let scenario: Scenario
    let isApplied: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isApplied ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isApplied ? Color.accentColor : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(scenario.name).font(.subheadline.weight(.medium))
                Text(scenario.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
#endif
