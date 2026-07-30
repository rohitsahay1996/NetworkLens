//
//  BreakpointListView.swift
//  NetworkLensUI
//
//  Created by Rohit Sahay on 30/07/26.
//

#if canImport(UIKit)
import SwiftUI
import NetworkLensCore

/// The armed breakpoints, the request-editing gate, and saved perturbations.
struct BreakpointListView: View {

    @EnvironmentObject private var lens: LensObservable

    var body: some View {
        List {
            Section {
                Toggle("Allow request editing", isOn: Binding(
                    get: { lens.isRequestEditingEnabled },
                    set: { Breakpoints.shared.setRequestEditingEnabled($0) }
                ))
            } footer: {
                Text("Editing a response is client-side. Editing a request sends altered data to a real backend and can create real records, so it stays off until you turn it on — every session.")
            }

            Section("Breakpoints") {
                ForEach(lens.breakpoints) { breakpoint in
                    BreakpointRow(breakpoint: breakpoint)
                }
                .onDelete { offsets in
                    for index in offsets { Breakpoints.shared.remove(id: lens.breakpoints[index].id) }
                }
            }

            if !lens.perturbations.isEmpty {
                Section {
                    ForEach(lens.perturbations) { perturbation in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(perturbation.name).font(.subheadline.weight(.medium))
                                    if perturbation.qaVerified {
                                        Image(systemName: "checkmark.seal.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.green)
                                    }
                                }
                                Text(perturbation.endpointKey)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Text("\(perturbation.ops.count) op\(perturbation.ops.count == 1 ? "" : "s")")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }

                            Spacer(minLength: 8)

                            // Arming one is what makes it rewrite traffic. Until
                            // this exists a saved perturbation is a note to self.
                            Toggle("", isOn: Binding(
                                get: { perturbation.isEnabled },
                                set: { newValue in
                                    var edited = perturbation
                                    edited.isEnabled = newValue
                                    Breakpoints.shared.save(edited)
                                }
                            ))
                            .labelsHidden()
                        }
                        .opacity(perturbation.isEnabled ? 1 : 0.5)
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            Breakpoints.shared.removePerturbation(id: lens.perturbations[index].id)
                        }
                    }
                } header: {
                    Text("Saved perturbations")
                } footer: {
                    Text("Armed perturbations rewrite matching responses with nobody watching — no breakpoint needed. Stored as edits rather than whole payloads, so they keep meaning the same thing after the server adds a field.")
                }
            }
        }
        .overlay {
            if lens.breakpoints.isEmpty && lens.perturbations.isEmpty {
                EmptyStateView(
                    title: "No breakpoints",
                    message: "Open a captured request and choose “Break on this endpoint”.",
                    systemImage: "pause.circle"
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button("Disable all") { Breakpoints.shared.disableAll() }
                    Button("Clear session skips") { Breakpoints.shared.clearSkips() }
                    Button("Remove all", role: .destructive) { Breakpoints.shared.removeAll() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(lens.breakpoints.isEmpty)
            }
        }
        .navigationTitle("Breakpoints")
    }
}

struct BreakpointRow: View {

    let breakpoint: Breakpoint

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(breakpoint.endpointKey)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(
                    get: { breakpoint.isEnabled },
                    set: { newValue in
                        var edited = breakpoint
                        edited.isEnabled = newValue
                        Breakpoints.shared.set(edited)
                    }
                ))
                .labelsHidden()
            }

            HStack(spacing: 8) {
                Picker("Stage", selection: Binding(
                    get: { breakpoint.stage },
                    set: { newValue in
                        var edited = breakpoint
                        edited.stage = newValue
                        Breakpoints.shared.set(edited)
                    }
                )) {
                    ForEach(BreakpointStage.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                Toggle("Once", isOn: Binding(
                    get: { breakpoint.oneShot },
                    set: { newValue in
                        var edited = breakpoint
                        edited.oneShot = newValue
                        Breakpoints.shared.set(edited)
                    }
                ))
                .font(.caption)
                .fixedSize()
            }
        }
        .padding(.vertical, 2)
        .opacity(breakpoint.isEnabled ? 1 : 0.5)
    }
}
#endif
