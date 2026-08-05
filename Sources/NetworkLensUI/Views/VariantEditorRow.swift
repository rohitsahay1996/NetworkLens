//
//  VariantEditorRow.swift
//  NetworkLensUI
//
//  Created by Rohit Sahay on 31/07/26.
//

#if canImport(UIKit)
import SwiftUI
import NetworkLensCore

/// One variant in the rule editor: pick it, or open it and edit it in place.
///
/// The list used to show a name and a one-line summary, which answers "which of
/// these is on" and nothing else. Every other question — what status does it
/// return, what is in the body, what did the request look like — meant closing
/// the list, going back to the traffic tab, finding a matching exchange and
/// opening a different sheet. Four screens to check one field.
///
/// So the row opens. Collapsed it is still a radio button; expanded it is the
/// whole answer, editable.
struct VariantEditorRow: View {

    let variant: MockVariant
    let isActive: Bool
    let isExpanded: Bool
    let select: () -> Void
    let toggleExpanded: () -> Void
    let update: (MockVariant) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if isExpanded { detail }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            // Selecting and opening are separate targets: opening a variant to
            // read it must not arm it, or inspecting the 500 case would serve
            // the 500 case.
            Button(action: select) {
                Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)

            Button(action: toggleExpanded) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(variant.name)
                            .foregroundStyle(.primary)
                        Text(summary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var summary: String {
        let steps = variant.steps.map(\.label).joined(separator: " → ")
        guard let response = singleResponse else { return steps }
        let size = response.body.isEmpty ? "empty" : formatBytes(response.body.count)
        let delay = response.delay > 0 ? " · \(formatDuration(response.delay))" : ""
        return "\(response.statusCode) · \(size)\(delay)"
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabelledField(label: "Name", text: nameBinding)

            if let response = singleResponse {
                LabelledField(
                    label: "Status",
                    text: statusBinding(response),
                    keyboard: .numberPad
                )

                delayPicker(response)

                DisclosureBlock(title: "Response headers (\(response.headers.count))") {
                    if response.headers.isEmpty {
                        Text("None").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(response.headers.sorted(by: { $0.key < $1.key }), id: \.key) {
                            LabelledRow(label: $0.key, value: $0.value, monospaced: true)
                        }
                    }
                }

                DisclosureBlock(title: "Response body", startsOpen: true) {
                    TextEditor(text: bodyBinding(response))
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 140)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.25))
                        )
                    if !isValidJSON(response.body) {
                        Label("Not valid JSON — served as-is", systemImage: "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            } else {
                // A script, a failure or a hang has no single body to put in a
                // text box. Saying so beats showing an editor that edits
                // nothing.
                Label(scriptExplanation, systemImage: "list.number")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Request mocking. Separate from the response because it is the
            // only thing here that reaches a real server.
            DisclosureBlock(title: rewrite == nil ? "Request (sent as-is)" : "Request (rewritten)") {
                Toggle("Send a different request", isOn: rewriteEnabledBinding)
                    .font(.subheadline)

                if let rewrite {
                    TextEditor(text: rewriteBodyBinding(rewrite))
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 110)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.orange.opacity(0.5))
                        )
                    Label(
                        "This is sent to the real server. Refused on hosts listed in productionHostPatterns.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption2)
                    .foregroundStyle(.orange)
                }
            }

            DisclosureBlock(title: "Request it answers") {
                if let sample = variant.requestSample, !sample.isEmpty {
                    TextEditor(text: requestBinding)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 90)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.25))
                        )
                    Text("Kept for reference. Never sent — a mocked request does not leave the device.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No request body was captured with this variant.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.leading, 26)
        .padding(.top, 2)
    }

    @ViewBuilder
    private func delayPicker(_ response: MockResponse) -> some View {
        HStack {
            Text("Delay").font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Menu {
                ForEach(MockOutcome.delayPresets, id: \.self) { preset in
                    Button(preset == 0 ? "None" : formatDuration(preset)) {
                        var edited = response
                        edited.delay = preset
                        replaceResponse(with: edited)
                    }
                }
            } label: {
                Label(
                    response.delay > 0 ? formatDuration(response.delay) : "None",
                    systemImage: "timer"
                )
                .font(.caption)
                .foregroundStyle(response.delay > 0 ? Color.orange : .secondary)
            }
        }
    }

    private var scriptExplanation: String {
        if variant.isScripted {
            return "A script of \(variant.steps.count) steps. Edit the steps below, in Script."
        }
        if variant.steps.first?.isHang == true {
            return "Never answers — there is no body to edit."
        }
        if variant.steps.first?.rewrite != nil {
            return "Rewrites the request and lets the server answer, so there is no canned response."
        }
        return "A transport failure — there is no body to edit."
    }

    // MARK: - Bindings

    /// The one response this variant serves, when it serves exactly one.
    private var singleResponse: MockResponse? {
        guard variant.steps.count == 1 else { return nil }
        return variant.steps.first?.response
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { variant.name },
            set: { newValue in
                var edited = variant
                // A variant with no name is unpickable in the switcher, which
                // is the only place it appears.
                edited.name = newValue.isEmpty ? "unnamed" : newValue
                update(edited)
            }
        )
    }

    private func statusBinding(_ response: MockResponse) -> Binding<String> {
        Binding(
            get: { "\(response.statusCode)" },
            set: { newValue in
                guard let code = Int(newValue.trimmingCharacters(in: .whitespaces)) else { return }
                var edited = response
                edited.statusCode = code
                replaceResponse(with: edited)
            }
        )
    }

    private func bodyBinding(_ response: MockResponse) -> Binding<String> {
        Binding(
            get: { String(decoding: response.body, as: UTF8.self) },
            set: { newValue in
                var edited = response
                edited.body = Data(newValue.utf8)
                replaceResponse(with: edited)
            }
        )
    }

    private var requestBinding: Binding<String> {
        Binding(
            get: { String(decoding: variant.requestSample ?? Data(), as: UTF8.self) },
            set: { newValue in
                var edited = variant
                edited.requestSample = newValue.isEmpty ? nil : Data(newValue.utf8)
                update(edited)
            }
        )
    }

    /// The rewrite this variant applies, when it has one.
    private var rewrite: MockRequestRewrite? {
        variant.steps.count == 1 ? variant.steps.first?.rewrite : nil
    }

    /// Turning it on replaces the answer with a rewrite, because a variant
    /// either answers the request or changes it and lets the server answer —
    /// doing both would mean the rewrite never reached anything.
    private var rewriteEnabledBinding: Binding<Bool> {
        Binding(
            get: { rewrite != nil },
            set: { isOn in
                var edited = variant
                if isOn {
                    let seed = variant.requestSample ?? Data("{}".utf8)
                    edited.steps = [.rewrite(MockRequestRewrite(body: seed))]
                } else {
                    edited.steps = [.respond(MockResponse())]
                }
                update(edited)
            }
        )
    }

    private func rewriteBodyBinding(_ rewrite: MockRequestRewrite) -> Binding<String> {
        Binding(
            get: { String(decoding: rewrite.body ?? Data(), as: UTF8.self) },
            set: { newValue in
                var edited = variant
                var changed = rewrite
                changed.body = Data(newValue.utf8)
                edited.steps = [.rewrite(changed)]
                update(edited)
            }
        )
    }

    private func replaceResponse(with response: MockResponse) {
        var edited = variant
        edited.steps = [.respond(response)]
        update(edited)
    }

    private func isValidJSON(_ data: Data) -> Bool {
        data.isEmpty || (try? JSONNodeParser.parse(data)) != nil
    }
}

// MARK: - Pieces

/// A labelled single-line field, so the detail block reads as a form rather
/// than a pile of text boxes.
struct LabelledField: View {

    let label: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default

    var body: some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            TextField(label, text: $text)
                .keyboardType(keyboard)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// A row-shaped button for use inside a `DisclosureBlock`.
///
/// `.borderless` because several plain buttons stacked in one list row share a
/// hit area — tapping any of them fires whichever SwiftUI decides owns the row,
/// which is the sort of bug that reads as the tool ignoring you.
struct ActionButton: View {

    let title: String
    let icon: String
    var tint: Color = .accentColor
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(isEnabled ? tint : Color.secondary)
        .disabled(!isEnabled)
    }
}

/// A nested fold inside a row.
///
/// Not `DisclosureGroup`: inside a list row it draws its own indentation and
/// chevron, which stops matching the rest of this screen.
struct DisclosureBlock<Content: View>: View {

    let title: String
    var startsOpen = false
    @ViewBuilder let content: Content

    @State private var isOpen: Bool?

    private var open: Bool { isOpen ?? startsOpen }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                isOpen = !open
            } label: {
                HStack {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open { content }
        }
    }
}
#endif
