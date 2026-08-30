//
//  ScenarioListView.swift
//  NetworkLensUI
//
//  Created by Rohit Sahay on 30/07/26.
//

#if canImport(UIKit)
import SwiftUI
import UniformTypeIdentifiers
import NetworkLensCore

/// Saved setups across endpoints, and the one in force.
struct ScenarioListView: View {

    @EnvironmentObject private var lens: LensObservable
    @State private var isNaming = false
    @State private var newName = ""
    @State private var scopeScreen: String?
    @State private var notice: String?

    @State private var isNamingPack = false
    @State private var packName = ""
    @State private var scenariosToExport: [Scenario] = []
    @State private var packToShare: PackFile?
    @State private var isImporting = false
    @State private var runFiles: [URL]?
    @ObservedObject private var runner = ScenarioRunner.shared

    /// Identifiable so `.sheet(item:)` rebuilds for each export rather than
    /// showing the first pack again.
    struct PackFile: Identifiable {
        let id = UUID()
        let url: URL
    }

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

            Section {
                Button {
                    scenariosToExport = lens.scenarios
                    packName = "Scenarios"
                    isNamingPack = true
                } label: {
                    Label("Export all as a pack…", systemImage: "square.and.arrow.up")
                }
                .disabled(lens.scenarios.isEmpty)

                Button {
                    isImporting = true
                } label: {
                    Label("Import a pack…", systemImage: "square.and.arrow.down.on.square")
                }
            } header: {
                Text("Packs")
            } footer: {
                Text("A pack is a scenario plus the mock rules it needs, as one file. Without the rules a scenario applies on another device, reports success and quietly serves live traffic. Bodies are redacted on the way out.")
            }

            RunListSection(runner: runner, shared: $runFiles)

            ForEach(groups, id: \.name) { group in
                ScenarioGroupSection(
                    group: group.name,
                    scenarios: group.scenarios,
                    runner: runner,
                    onApply: apply,
                    onExport: { scenarios, name in
                        scenariosToExport = scenarios
                        packName = name
                        isNamingPack = true
                    }
                )
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
        .alert("Name this pack", isPresented: $isNamingPack) {
            TextField("“Checkout states”", text: $packName)
            Button("Cancel", role: .cancel) {}
            Button("Export") { export() }
        } message: {
            Text("The file carries \(scenariosToExport.count) "
                 + (scenariosToExport.count == 1 ? "scenario" : "scenarios")
                 + " and the rules they reference.")
        }
        .sheet(item: $packToShare) { file in
            PackShareSheet(url: file.url)
        }
        .sheet(isPresented: Binding(get: { runFiles != nil }, set: { if !$0 { runFiles = nil } })) {
            PackShareSheet(urls: runFiles ?? [])
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            importPack(from: result)
        }
        .navigationTitle("Scenarios")
    }

    // MARK: - Packs

    /// Written to a temp file rather than shared as text, so it arrives named.
    private func export() {
        let trimmed = packName.trimmingCharacters(in: .whitespacesAndNewlines)
        let pack = lens.exportPack(scenariosToExport, named: trimmed.isEmpty ? "Scenarios" : trimmed)
        do {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(pack.suggestedFileName)
            try pack.encoded().write(to: url, options: .atomic)
            packToShare = PackFile(url: url)
            // Said on the way out, while it can still be fixed: a pack missing
            // a rule is the failure this format exists to prevent, and the
            // other device cannot tell it apart from a working one.
            notice = pack.isComplete
                ? "\(pack.scenarios.count) scenarios · \(pack.mocks.count) rules"
                : "Exported, but \(pack.unresolved.count) entries have no rule"
        } catch {
            notice = "Could not write the pack: \(error.localizedDescription)"
        }
    }

    private func importPack(from result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            // A file picked outside the app's container is security-scoped;
            // reading it without this fails with a permissions error that
            // looks nothing like one.
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

            let outcome = try lens.importPack(from: try Data(contentsOf: url))
            var summary = "\(outcome.addedScenarios + outcome.replacedScenarios) scenarios, "
                + "\(outcome.addedRules + outcome.replacedRules) rules"
            if outcome.replacedRules > 0 || outcome.replacedScenarios > 0 {
                summary += " · \(outcome.replacedRules + outcome.replacedScenarios) replaced"
            }
            if !outcome.isComplete {
                summary += " · \(outcome.unresolved.count) unresolved"
            }
            notice = summary
        } catch {
            notice = "Could not read that pack: \(error.localizedDescription)"
        }
    }

    private func apply(_ scenario: Scenario) {
        let outcome = lens.applyScenario(scenario)
        notice = outcome.isComplete
            ? "Applied \(scenario.name)"
            : "Applied \(outcome.applied), \(outcome.missing.count) missing"
    }

    /// Packs, in the order they were first imported, with device-made scenarios
    /// last. Alphabetical would shuffle the list every time a pack arrives, and
    /// the one someone just imported is the one they are looking for.
    private var groups: [(name: String, scenarios: [Scenario])] {
        var order: [String] = []
        var buckets: [String: [Scenario]] = [:]
        for scenario in lens.scenarios {
            let key = scenario.group ?? Self.ungrouped
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(scenario)
        }
        let ungroupedLast = order.sorted { lhs, rhs in
            (lhs == Self.ungrouped ? 1 : 0) < (rhs == Self.ungrouped ? 1 : 0)
        }
        return ungroupedLast.map { (name: $0, scenarios: buckets[$0] ?? []) }
    }

    private static let ungrouped = "Saved on this device"

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
