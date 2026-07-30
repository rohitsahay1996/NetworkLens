//
//  MockListView.swift
//  NetworkLensUI
//
//  Created by Rohit Sahay on 30/07/26.
//

#if canImport(UIKit)
import SwiftUI
import NetworkLensCore

/// The armed mock rules, their scripts, and their hit counts.
struct MockListView: View {

    @EnvironmentObject private var lens: LensObservable
    @State private var editing: MockRule?

    var body: some View {
        List {
            Section {
                Toggle("Mocking enabled", isOn: Binding(
                    get: { lens.isMockingEnabled },
                    set: { Mocks.shared.setMockingEnabled($0) }
                ))
            } footer: {
                Text("Off suspends every rule without discarding it — for comparing mocked and live behaviour.")
            }

            Section("Rules") {
                ForEach(lens.mocks) { rule in
                    Button { editing = rule } label: { MockRuleRow(rule: rule) }
                        .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    for index in offsets { Mocks.shared.remove(id: lens.mocks[index].id) }
                }
            }
        }
        .overlay {
            if lens.mocks.isEmpty {
                EmptyStateView(
                    title: "No mock rules",
                    message: "Open a captured request and choose “Mock this response”.",
                    systemImage: "square.on.square"
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button("Reset hit counts") { Mocks.shared.resetHitCounts() }
                    Button("Disable all") { Mocks.shared.disableAll() }
                    Button("Remove all", role: .destructive) { Mocks.shared.removeAll() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(lens.mocks.isEmpty)
            }
        }
        .sheet(item: $editing) { rule in
            MockRuleEditor(rule: rule).environmentObject(lens)
        }
        .navigationTitle("Mocks")
    }
}

struct MockRuleRow: View {

    let rule: MockRule
    @EnvironmentObject private var lens: LensObservable

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(rule.endpointKey)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(
                    get: { rule.isEnabled },
                    set: { newValue in
                        var edited = rule
                        edited.isEnabled = newValue
                        Mocks.shared.set(edited)
                    }
                ))
                .labelsHidden()
            }

            HStack(spacing: 6) {
                if let name = rule.name {
                    Text(name).font(.caption).foregroundStyle(.secondary)
                }
                if let summary = rule.match.summary {
                    Text(summary)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.blue.opacity(0.15)))
                        .foregroundStyle(.blue)
                        .lineLimit(1)
                }
                if rule.variants.count > 1 {
                    Text("1 of \(rule.variants.count)")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        .foregroundStyle(.secondary)
                }
                Text(scriptSummary)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.purple.opacity(0.15)))
                    .foregroundStyle(.purple)
                Spacer(minLength: 0)
                Text("\(lens.hitCount(for: rule)) served")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .opacity(rule.isEnabled ? 1 : 0.5)
    }

    /// A script reads as its steps in order, so the list answers "what happens
    /// on the next tap" without opening anything.
    private var scriptSummary: String {
        let steps = rule.steps.map(\.label).joined(separator: " → ")
        return rule.isScripted ? "\(steps) · \(rule.exhaustion.label)" : steps
    }
}

/// Edits one rule: its script, its latency, its exhaustion policy.
struct MockRuleEditor: View {

    @State var rule: MockRule
    @EnvironmentObject private var lens: LensObservable
    @Environment(\.dismiss) private var dismiss

    init(rule: MockRule) { _rule = State(initialValue: rule) }

    var body: some View {
        NavigationView {
            List {
                Section("Rule") {
                    LabelledRow(label: "Endpoint", value: rule.endpointKey, monospaced: true)
                    if let summary = rule.match.summary {
                        LabelledRow(label: "Only when", value: summary, monospaced: true)
                    }
                }

                Section {
                    ForEach(rule.variants) { variant in
                        Button {
                            rule.activate(variantID: variant.id)
                        } label: {
                            HStack {
                                Image(
                                    systemName: variant.id == rule.activeVariantID
                                        ? "largecircle.fill.circle" : "circle"
                                )
                                .foregroundStyle(
                                    variant.id == rule.activeVariantID ? Color.accentColor : .secondary
                                )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(variant.name)
                                    Text(variant.steps.map(\.label).joined(separator: " → "))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        for index in offsets { rule.removeVariant(id: rule.variants[index].id) }
                    }

                    TextField("Rename the selected variant", text: Binding(
                        get: { rule.name ?? "" },
                        set: { rule.name = $0.isEmpty ? nil : $0 }
                    ))

                    Button {
                        // Copies the one on screen rather than starting blank:
                        // a new variant is nearly always "this, but with one
                        // field changed".
                        var copy = rule.activeVariant
                        copy = MockVariant(
                            name: "\(copy.name) copy",
                            steps: copy.steps,
                            exhaustion: copy.exhaustion,
                            requestSample: copy.requestSample
                        )
                        rule.addVariant(copy)
                    } label: {
                        Label("Duplicate this variant", systemImage: "plus.square.on.square")
                    }
                } header: {
                    Text("Variants")
                } footer: {
                    Text("One endpoint, several named answers, one active. The script below belongs to the selected variant — switching rewinds it to its first step.")
                }

                Section {
                    ForEach(Array(rule.steps.enumerated()), id: \.offset) { index, step in
                        MockStepRow(index: index, step: step) { delay in
                            rule.steps[index] = step.settingDelay(delay)
                        }
                    }
                    .onDelete { offsets in
                        rule.steps.remove(atOffsets: offsets)
                        if rule.steps.isEmpty { rule.steps = [.respond(MockResponse())] }
                    }

                    Menu {
                        Button("200 OK") { rule.steps.append(.respond(.json("{}"))) }
                        Button("204 No Content") { rule.steps.append(.respond(.status(204))) }
                        Button("401 Unauthorized") { rule.steps.append(.respond(.status(401))) }
                        Button("500 Server Error") { rule.steps.append(.respond(.status(500))) }
                        Divider()
                        ForEach(MockFailure.presets, id: \.errorCode) { preset in
                            Button(preset.label) { rule.steps.append(.fail(preset)) }
                        }
                        Divider()
                        Button("Never respond — stay loading") { rule.steps.append(.hang) }
                    } label: {
                        Label("Add step", systemImage: "plus.circle")
                    }
                } header: {
                    Text("Script")
                } footer: {
                    Text("One step per request, in order. The bugs worth reproducing are sequences: fail then succeed, 200 then 401. Tap a step's latency to throttle it — a mock that answers instantly hides every spinner and race the real call would expose.")
                }

                if rule.isScripted {
                    Section("When the script runs out") {
                        Picker("After the last step", selection: $rule.exhaustion) {
                            ForEach(MockExhaustion.allCases, id: \.self) {
                                Text($0.label).tag($0)
                            }
                        }
                    }
                }

                Section {
                    LabelledRow(label: "Served", value: "\(lens.hitCount(for: rule)) times")
                    Button("Reset this rule's count") {
                        // Replacing with a fresh id is what resets one rule's
                        // history; `resetHitCounts()` would clear every rule.
                        var replacement = rule
                        replacement = MockRule(
                            endpointKey: rule.endpointKey,
                            steps: rule.steps,
                            exhaustion: rule.exhaustion,
                            isEnabled: rule.isEnabled,
                            name: rule.name
                        )
                        Mocks.shared.remove(id: rule.id)
                        Mocks.shared.set(replacement)
                        rule = replacement
                    }
                }

                Section {
                    Button("Delete rule", role: .destructive) {
                        Mocks.shared.remove(id: rule.id)
                        dismiss()
                    }
                }
            }
            .navigationTitle("Mock")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Mocks.shared.set(rule)
                        dismiss()
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

struct MockStepRow: View {

    let index: Int
    let step: MockOutcome
    /// `nil` in read-only contexts; the editor passes a setter.
    var setDelay: ((TimeInterval) -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.caption2.bold())
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.secondary.opacity(0.15)))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                if setDelay == nil, step.delay > 0 {
                    Text("after \(formatDuration(step.delay))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            // A hang is already unbounded waiting, so throttling it means
            // nothing — offering the control would imply otherwise.
            if let setDelay, !step.isHang {
                Menu {
                    ForEach(MockOutcome.delayPresets, id: \.self) { preset in
                        Button(preset == 0 ? "No delay" : formatDuration(preset)) {
                            setDelay(preset)
                        }
                    }
                } label: {
                    Label(
                        step.delay > 0 ? formatDuration(step.delay) : "instant",
                        systemImage: "timer"
                    )
                    .font(.caption2)
                    .foregroundStyle(step.delay > 0 ? Color.orange : .secondary)
                }
            }

            Image(systemName: icon)
                .foregroundStyle(tint)
        }
    }

    private var title: String {
        if step.isHang { return "Never answers — stays loading" }
        if let failure = step.failure { return failure.label }
        guard let response = step.response else { return "—" }
        let size = response.body.isEmpty ? "empty" : formatBytes(response.body.count)
        return "HTTP \(response.statusCode) · \(size)"
    }

    private var icon: String {
        if step.isHang { return "hourglass" }
        return step.failure == nil ? "arrow.down.circle" : "bolt.horizontal.circle"
    }

    private var tint: Color {
        if step.isHang { return .orange }
        return step.failure == nil ? .green : .red
    }
}
#endif
