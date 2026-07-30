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

    let presentation: BreakpointPresentation

    @EnvironmentObject private var lens: LensObservable
    @State private var bodyText = ""
    @State private var statusCode = ""
    @State private var loadedFor: UUID?
    @State private var now = Date()

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
                }

                if presentation.stage == .response {
                    Section("Status") {
                        TextField("Status code", text: $statusCode)
                            .keyboardType(.numberPad)
                            .onChange(of: statusCode) { _ in stageEdit() }
                    }
                }

                Section {
                    TextEditor(text: $bodyText)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 180)
                        .onChange(of: bodyText) { _ in stageEdit() }
                } header: {
                    Text("Body")
                } footer: {
                    Text(isEditableJSON
                        ? "Edited as text. Malformed JSON is sent as-is — mocking a broken payload is a legitimate thing to do."
                        : "This body is not JSON. Editing it as text may produce something the app cannot decode.")
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
        if let deadline = presentation.autoResumeAt {
            let remaining = max(0, deadline.timeIntervalSince(now))
            HStack {
                Image(systemName: "clock")
                Text("Auto-resumes in \(Int(remaining.rounded()))s")
                Spacer()
            }
            .font(.subheadline)
            .foregroundStyle(remaining < 5 ? Color.red : .secondary)
        }
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
    }

    /// Reformatted through the ordered serializer so key order survives a
    /// round trip; raw text for anything that is not JSON.
    private func text(from data: Data?) -> String {
        guard let data, !data.isEmpty else { return "" }
        if let node = try? JSONNodeParser.parse(data) {
            return JSONNodeSerializer.string(from: node, format: .pretty)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private var isEditableJSON: Bool {
        (try? JSONNodeParser.parse(Data(bodyText.utf8))) != nil
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
