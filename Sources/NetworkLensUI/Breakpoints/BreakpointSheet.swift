//
//  BreakpointSheet.swift
//  NetworkLensUI
//
//  Created by Rohit Sahay on 30/07/26.
//

#if canImport(UIKit)
import SwiftUI
import NetworkLensCore

/// The held request or response, and the controls that release it.
///
/// The app is stopped while this is on screen, so everything here is built
/// around the clock: the auto-resume deadline is always visible, and every edit
/// is staged with the coordinator as it is made. If the tester runs out of time
/// mid-edit, the work still ships — a resume that silently discards it is worse
/// than no editor at all.
struct BreakpointSheet: View {

    @EnvironmentObject private var lens: LensObservable

    /// Read live rather than captured at presentation time. Sheet content is
    /// built once and not necessarily rebuilt when the held item changes, so a
    /// captured snapshot goes stale the moment the queue advances — and every
    /// button here resolves *by id*. `resolve` on a stale id matches no
    /// continuation and returns silently, leaving the app held with nothing on
    /// screen still able to release it.
    private var presentation: BreakpointPresentation { lens.presentation }
    @State private var bodyText = ""
    @State private var statusCode = ""
    @State private var loadedFor: UUID?
    @State private var now = Date()
    /// Measured once per load. `String.utf8.count` walks the whole buffer, and
    /// this is read from `body` — which the countdown redraws twice a second.
    @State private var bodyByteCount = 0
    @State private var isEditingOversizeBody = false
    @StateObject private var validity = JSONValidity()

    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationView {
            List {
                Section {
                    LabelledRow(label: "Endpoint", value: presentation.endpointKey, monospaced: true)
                    LabelledRow(label: "Stage", value: presentation.stage.rawValue)
                    if let queue = presentation.queueLabel {
                        LabelledRow(label: "Queue", value: queue)
                    }
                    countdown
                } footer: {
                    if !presentation.isAutoResumeEnabled {
                        Text("The app's own request timeout keeps running and is not extended. Held past it, the request fails with a timeout — which is the app's real behaviour, not the tool's.")
                    }
                }

                if presentation.stage == .response {
                    Section("Status") {
                        TextField("Status code", text: $statusCode)
                            .keyboardType(.numberPad)
                            .onChange(of: statusCode) { _ in stageEdit() }
                    }
                }

                Section {
                    bodyEditor
                } header: {
                    Text("Body")
                } footer: {
                    Text(bodyFooter)
                }

                Section {
                    Button {
                        resume(with: editedPayload)
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                    }

                    Button {
                        resume(with: originalPayload)
                    } label: {
                        Label("Resume unchanged", systemImage: "arrow.uturn.forward")
                    }

                    Menu {
                        ForEach(MockFailure.presets, id: \.errorCode) { preset in
                            Button(preset.label) { abort(with: preset.urlError) }
                        }
                    } label: {
                        Label("Fail the request", systemImage: "bolt.horizontal.circle")
                    }
                }

                Section {
                    Button("Skip this endpoint for the session") {
                        Breakpoints.shared.skipForSession(endpointKey: presentation.endpointKey)
                        resume(with: originalPayload)
                    }
                    Button("Resume all and disarm", role: .destructive) {
                        Task { await BreakpointCoordinator.shared.resumeAllAndDisableBreakpoints() }
                    }
                } footer: {
                    Text("The escape hatch when a breakpoint fires far more often than expected.")
                }
            }
            .navigationTitle("Paused")
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationViewStyle(.stack)
        .onReceive(tick) { now = $0 }
        .onAppear { load() }
        .onChange(of: presentation.id) { _ in load() }
    }

    // MARK: - Countdown

    @ViewBuilder
    private var countdown: some View {
        Toggle(isOn: autoResumeBinding) {
            HStack(spacing: 6) {
                Image(systemName: presentation.isAutoResumeEnabled ? "clock" : "clock.badge.xmark")
                Text(countdownLabel)
            }
            .font(.subheadline)
            .foregroundStyle(countdownTint)
        }
    }

    private var countdownLabel: String {
        guard presentation.isAutoResumeEnabled, let deadline = presentation.autoResumeAt else {
            // No countdown to show, so the row says what is now true instead:
            // nothing here will let go of the request on its own.
            return "Auto-resume off"
        }
        return "Auto-resumes in \(Int(max(0, deadline.timeIntervalSince(now)).rounded()))s"
    }

    private var countdownTint: Color {
        guard presentation.isAutoResumeEnabled, let deadline = presentation.autoResumeAt else {
            return .secondary
        }
        return deadline.timeIntervalSince(now) < 5 ? .red : .secondary
    }

    /// Writes straight through to the coordinator; the flag lives on the held
    /// item, not in this view, so a re-presented sheet shows the real state.
    private var autoResumeBinding: Binding<Bool> {
        Binding(
            get: { presentation.isAutoResumeEnabled },
            set: { enabled in
                guard let id = presentation.id else { return }
                Task { await BreakpointCoordinator.shared.setAutoResumeEnabled(enabled, for: id) }
            }
        )
    }

    // MARK: - Loading

    /// Pulls the held payload into the editors once per presented item. Keyed
    /// on the id so the next queued breakpoint reloads, and so a redraw does
    /// not overwrite half-typed edits.
    private func load() {
        guard loadedFor != presentation.id else { return }
        loadedFor = presentation.id

        switch presentation.payload {
        case .request(let request):
            bodyText = text(from: request.httpBody)
            statusCode = ""
        case .response(let payload):
            bodyText = text(from: payload.body)
            statusCode = "\(payload.response.statusCode)"
        case .none:
            bodyText = ""
            statusCode = ""
        }
        bodyByteCount = bodyText.utf8.count
        isEditingOversizeBody = false
        validity.check(bodyText)
    }

    // MARK: - Body editor

    /// The buffer is always loaded, even when it is too big to edit: `resume`
    /// rebuilds the payload from it, and an editor that quietly held only part
    /// of the body would send a truncated response to the app under test.
    /// Only the `TextEditor` is withheld.
    @ViewBuilder
    private var bodyEditor: some View {
        if bodyByteCount > BodyEditorLimit.bytes, !isEditingOversizeBody {
            VStack(alignment: .leading, spacing: 8) {
                Text(bodyText.prefix(BodyEditorLimit.previewCharacters) + "\n…")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button("Edit anyway") { isEditingOversizeBody = true }
                    .font(.footnote)
            }
        } else {
            TextEditor(text: $bodyText)
                .font(.system(.footnote, design: .monospaced))
                .frame(minHeight: 180)
                .onChange(of: bodyText) { newValue in
                    stageEdit()
                    validity.check(newValue)
                }
        }
    }

    private var bodyFooter: String {
        if bodyByteCount > BodyEditorLimit.bytes, !isEditingOversizeBody {
            return "\(formatBytes(bodyByteCount)) — shown as a preview. A text editor "
                + "re-lays its whole buffer on every keystroke, so editing this in place "
                + "would freeze the sheet. Resuming sends the held body untouched."
        }
        return validity.isValid
            ? "Edited as text. Malformed JSON is sent as-is — mocking a broken payload is a legitimate thing to do."
            : "This body is not JSON. Editing it as text may produce something the app cannot decode."
    }

    /// Reformatted through the ordered serializer so key order survives a
    /// round trip; raw text for anything that is not JSON. Cached by payload —
    /// `load()` is guarded per breakpoint, but the same body comes back every
    /// time a queued hold is revisited.
    private func text(from data: Data?) -> String {
        BodyText.pretty(from: data)
    }

    // MARK: - Editing

    private var originalPayload: BreakpointPayload? { presentation.payload }

    private var editedPayload: BreakpointPayload? {
        switch presentation.payload {
        case .request(let request):
            return .request(request.replacingBody(Data(bodyText.utf8)))

        case .response(let payload):
            var edited = payload.replacingBody(Data(bodyText.utf8))
            if let code = Int(statusCode), code != payload.response.statusCode {
                edited = edited.replacingStatusCode(code)
            }
            return .response(edited)

        case .none:
            return nil
        }
    }

    /// Hands the work-in-progress to the coordinator on every keystroke, so an
    /// auto-resume proceeds with it rather than throwing it away.
    private func stageEdit() {
        guard let id = presentation.id, let payload = editedPayload else { return }
        Task { await BreakpointCoordinator.shared.stageEdit(payload, for: id) }
    }

    private func resume(with payload: BreakpointPayload?) {
        guard let id = presentation.id, let payload else { return }
        Task { await BreakpointCoordinator.shared.resolve(id: id, with: .proceed(payload)) }
    }

    private func abort(with error: Error) {
        guard let id = presentation.id else { return }
        Task { await BreakpointCoordinator.shared.resolve(id: id, with: .abort(error)) }
    }
}
#endif
