//
//  RunListSection.swift
//  NetworkLensUI
//
//  Created by Rohit Sahay on 28/08/26.
//

#if canImport(UIKit)
import SwiftUI
import NetworkLensCore

/// Finished passes, and the way they leave the device.
///
/// The run is the deliverable, not the screenshots: a folder of untitled images
/// is what QA already produces today, and nobody can tell from it which state
/// was being tested. `run.json` carries the scenario names, the endpoints each
/// one pinned, the verdicts and the notes, so the images have something to be
/// read against.
struct RunListSection: View {

    @ObservedObject var runner: ScenarioRunner
    @Binding var shared: [URL]?

    @State private var runs: [ScenarioRun] = []

    var body: some View {
        Section {
            Button {
                runner.start(Scenarios.shared.all, packName: "Scenarios")
            } label: {
                Label("Run every scenario as a pass…", systemImage: "play.circle")
            }
            .disabled(Scenarios.shared.all.isEmpty || runner.isRunning)

            ForEach(runs) { run in
                Button {
                    shared = files(for: run)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(run.packName).font(.subheadline.weight(.medium))
                        Text("\(run.summary) · \(run.startedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .onDelete { offsets in
                for index in offsets { RunStore.shared.delete(runs[index]) }
                runs = RunStore.shared.runs()
            }
        } header: {
            Text("Runs")
        } footer: {
            Text("A run walks every scenario in turn. The bar rides with the bubble: refresh the screen, tap Capture, mark it pass or fail, then Next. Tap a finished run to share its manifest and screenshots.")
        }
        .onAppear { runs = RunStore.shared.runs() }
        .onChange(of: runner.isRunning) { _ in runs = RunStore.shared.runs() }
    }

    /// The manifest first, so whatever receives the share leads with the thing
    /// that explains the rest.
    private func files(for run: ScenarioRun) -> [URL] {
        let directory = RunStore.shared.directory(for: run)
        let manifest = directory.appendingPathComponent("run.json")
        let images = run.captures.compactMap(\.imageFileName).map(directory.appendingPathComponent)
        return [manifest] + images
    }
}
#endif
