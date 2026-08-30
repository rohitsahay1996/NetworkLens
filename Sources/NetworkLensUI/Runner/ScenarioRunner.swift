//
//  ScenarioRunner.swift
//  NetworkLensUI
//
//  Created by Rohit Sahay on 28/08/26.
//

#if canImport(UIKit)
import SwiftUI
import UIKit
import NetworkLensCore

/// Walks a pack one scenario at a time, collecting evidence as it goes.
///
/// Tester-paced on purpose, and not for want of trying to automate it: applying
/// a scenario is instant, but the screen only changes when the app re-fetches,
/// and nothing here can make it. A runner that advanced on a timer would
/// screenshot nine identical screens and call it a pass — the worst possible
/// outcome for a tool whose entire job is evidence.
///
/// So the loop is: apply, hand control back, wait for the tester to refresh the
/// screen and tap Capture. What the tool contributes is everything around that
/// — the state is set correctly, the screenshot is clean, the verdict and note
/// are attached to the right scenario, and the whole pass ends as one artifact
/// instead of a folder of untitled images.
@MainActor
final class ScenarioRunner: ObservableObject {

    static let shared = ScenarioRunner()

    @Published private(set) var run: ScenarioRun?
    @Published private(set) var scenarios: [Scenario] = []
    @Published private(set) var index = 0

    /// Set after a capture so the bar can offer a verdict without stealing the
    /// screen. Cleared on advance: a verdict belongs to the state it was given
    /// for, and carrying it forward would quietly mark the next one too.
    @Published var isReviewing = false

    @Published var notice: String?

    private init() {}

    var isRunning: Bool { run != nil }

    var current: Scenario? { scenarios[safeIndex: index] }

    var progress: String { "\(min(index + 1, scenarios.count))/\(scenarios.count)" }

    var isLast: Bool { index >= scenarios.count - 1 }

    /// The capture for the scenario on screen, if one has been taken.
    var currentCapture: ScenarioRun.Capture? {
        guard let name = current?.name else { return nil }
        return run?.captures.last { $0.scenarioName == name }
    }

    // MARK: - Lifecycle

    func start(_ scenarios: [Scenario], packName: String) {
        guard !scenarios.isEmpty else { return }
        self.scenarios = scenarios
        index = 0
        isReviewing = false
        run = ScenarioRun(packName: packName)
        applyCurrent()
    }

    func stop() {
        if let run { try? RunStore.shared.save(run) }
        run = nil
        scenarios = []
        index = 0
        isReviewing = false
    }

    /// Applies the scenario at `index`, and switches mocking on with it.
    ///
    /// A run whose first scenario silently did nothing because the master
    /// switch was off is the single most likely way this feature gets written
    /// off as broken.
    private func applyCurrent() {
        guard let scenario = current else { return }
        Mocks.shared.setMockingEnabled(true)
        let outcome = Scenarios.shared.apply(scenario)
        notice = outcome.isComplete
            ? scenario.name
            : "\(scenario.name) — \(outcome.missing.count) missing"
    }

    func next() {
        guard !isLast else { return }
        recordSkipIfNeeded()
        index += 1
        isReviewing = false
        applyCurrent()
    }

    func finish() {
        recordSkipIfNeeded()
        if let run { try? RunStore.shared.save(run) }
        isReviewing = false
    }

    /// A state nobody captured is recorded as such rather than dropped. The
    /// gap in the report is the point: it names what was not looked at.
    private func recordSkipIfNeeded() {
        guard let scenario = current, var run else { return }
        guard !run.captures.contains(where: { $0.scenarioName == scenario.name }) else { return }
        run.captures.append(
            ScenarioRun.Capture(scenarioName: scenario.name, pinned: Self.pinned(in: scenario))
        )
        self.run = run
        try? RunStore.shared.save(run)
    }

    // MARK: - Capture

    func capture(in scene: UIWindowScene?) {
        guard let scenario = current, var run else { return }

        let image = WindowSnapshot.capture(in: scene)
        var fileName: String?
        if let image {
            fileName = try? RunStore.shared.writeImage(image, for: run, index: run.captures.count + 1)
        }

        let capture = ScenarioRun.Capture(
            scenarioName: scenario.name,
            pinned: Self.pinned(in: scenario),
            imageFileName: fileName
        )
        run.captures.removeAll { $0.scenarioName == scenario.name }
        run.captures.append(capture)
        self.run = run
        try? RunStore.shared.save(run)

        isReviewing = true
        notice = fileName == nil ? "Could not read the screen" : nil
    }

    func setVerdict(_ verdict: ScenarioRun.Capture.Verdict) {
        update { $0.verdict = verdict }
    }

    func setNote(_ note: String) {
        update { $0.note = note }
    }

    private func update(_ change: (inout ScenarioRun.Capture) -> Void) {
        guard let name = current?.name, var run else { return }
        guard let position = run.captures.lastIndex(where: { $0.scenarioName == name }) else { return }
        change(&run.captures[position])
        self.run = run
        try? RunStore.shared.save(run)
    }

    /// `endpoint → variant` for everything the scenario switches on, kept with
    /// the capture because the rules will have moved on long before anyone
    /// reads the report.
    private static func pinned(in scenario: Scenario) -> [String] {
        let enabled = scenario.entries.filter(\.isEnabled)
        guard !enabled.isEmpty else { return ["all rules off — live traffic"] }
        return enabled.map { "\($0.endpointKey) → \($0.variantName)" }
    }
}

private extension Array {

    subscript(safeIndex index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
#endif
