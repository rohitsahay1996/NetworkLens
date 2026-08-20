//
//  MockFromExchangeSheet.swift
//  NetworkLensUI
//
//  Created by Rohit Sahay on 30/07/26.
//

#if canImport(UIKit)
import SwiftUI
import NetworkLensCore

/// Turns a captured exchange into a mock rule, starting from what the server
/// actually sent.
///
/// The live response is prefilled rather than left blank on purpose: recreating
/// a real body by hand is the reason people give up on mocking. Saving without
/// touching anything is the "replay this exact response" case, and every edit
/// from there is a deviation the tester chose.
///
/// Reopening this on an already-mocked endpoint edits that rule rather than
/// stacking a second one behind it: `Mocks.set(_:)` replaces by `endpointKey`
/// *and* match conditions, and this sheet saves with the conditions shown under
/// "Applies to".
struct MockFromExchangeSheet: View {

    /// Adding a new named answer, or editing the one already active.
    ///
    /// Both start from the live response: a new mock is nearly always "what the
    /// server said, with one thing changed", and retyping a real body is the
    /// reason people give up on mocking.
    enum Mode {
        case add
        case edit
    }

    let exchange: NetworkExchange
    var mode: Mode = .edit

    @EnvironmentObject private var lens: LensObservable
    @Environment(\.dismiss) private var dismiss

    @State private var statusCode: String
    @State private var bodyText: String
    @State private var delay: String
    @State private var name: String
    @State private var requestText: String
    @State private var matchesQuery = false
    @State private var isEditingOversizeBody = false
    @State private var isEditingOversizeRequest = false
    @State private var isEditingBodyAsText = false
    @StateObject private var validity = JSONValidity()
    @StateObject private var session = BodyEditSession()

    init(exchange: NetworkExchange, mode: Mode = .edit) {
        self.exchange = exchange
        self.mode = mode
        let response = exchange.response
        _statusCode = State(initialValue: "\(response?.statusCode ?? 200)")
        _bodyText = State(initialValue: Self.text(from: response?.body))
        _delay = State(initialValue: "0")
        // Named by the tester. Empty rather than guessed, because the name is
        // what the switcher shows and "captured 200" tells nobody which state
        // this is.
        _name = State(initialValue: mode == .add ? "" : (
            Mocks.shared.rule(forEndpointKey: exchange.endpointKey)?.name ?? ""
        ))
        _requestText = State(initialValue: Self.text(from: exchange.request.body))
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    LabelledRow(label: "Endpoint", value: exchange.endpointKey, monospaced: true)
                    if existingRule != nil {
                        HStack {
                            Text("Status").foregroundStyle(.secondary)
                            Spacer()
                            MockedBadge()
                        }
                    }
                } footer: {
                    Text(existingRule == nil
                        ? "Everything below starts as the response the server actually sent. Save it unchanged to replay it, or edit it first."
                        : "This endpoint already has a rule. Saving replaces it.")
                }

                if !lens.isMockingEnabled {
                    Section {
                        Toggle("Mocking enabled", isOn: Binding(
                            get: { lens.isMockingEnabled },
                            set: { Mocks.shared.setMockingEnabled($0) }
                        ))
                    } footer: {
                        // Saving into a suspended engine produces a rule that
                        // never fires, which reads as a broken mock rather than
                        // a switched-off one.
                        Text("Mocking is off, so this rule will be saved but not served until you turn it back on.")
                    }
                }

                if hasRequestBody {
                    Section {
                        editor(
                            text: $requestText,
                            minHeight: 120,
                            isOversizeUnlocked: $isEditingOversizeRequest
                        )
                    } header: {
                        Text("Request · \(exchange.request.method)")
                    } footer: {
                        // Said plainly because an editor that looks live and is
                        // not is worse than no editor: a mocked request never
                        // reaches the network at all, so nothing here could
                        // change what a server sees even in principle.
                        Text("Kept with the rule for reference — what the app posted to earn this response. Not sent: a mocked request never leaves the device. To change what the server actually receives, break on the request instead.")
                    }
                }

                Section {
                    TextField("Name — “empty cart”, “expired token”", text: $name)
                    TextField("Status code", text: $statusCode)
                        .keyboardType(.numberPad)
                } header: {
                    Text(mode == .add ? "New mock" : "Response")
                } footer: {
                    if mode == .add {
                        Text("Prefilled with what the server just returned. Edit the body below into the state you want to test, and name it something you will recognise in the switcher.")
                    }
                }

                Section {
                    Picker("Delay", selection: $delay) {
                        ForEach(MockOutcome.delayPresets, id: \.self) { preset in
                            Text(preset == 0 ? "None" : formatDuration(preset))
                                .tag(Self.text(for: preset))
                        }
                    }
                    .pickerStyle(.segmented)

                    TextField("Seconds", text: $delay)
                        .keyboardType(.decimalPad)
                } header: {
                    Text("Throttle")
                } footer: {
                    // Not cosmetic. A mock that answers in zero time is the
                    // least realistic thing the tool can do.
                    Text("Held for this long before the mock is served. A mock that answers instantly hides every spinner, race and cancellation path the real call would expose. Past the request's own timeout it fails with a timeout, exactly as the real stack would.")
                }

                Section {
                    if session.canEdit, !isEditingBodyAsText, let tree = session.tree {
                        JSONTreeView(tree: tree, editor: session)
                        stagedEdits
                    } else {
                        editor(
                            text: $bodyText,
                            minHeight: 200,
                            isOversizeUnlocked: $isEditingOversizeBody,
                            onChange: { validity.check($0) }
                        )
                    }
                } header: {
                    HStack {
                        Text("Body")
                        Spacer()
                        // The text path never goes away. A malformed payload is
                        // a legitimate thing to mock, and no tree can express
                        // one — `bodyFooter` has always said so.
                        if session.canEdit {
                            Button(isEditingBodyAsText ? "Edit fields" : "Edit as text") {
                                if isEditingBodyAsText { session.load(Data(bodyText.utf8)) }
                                isEditingBodyAsText.toggle()
                            }
                            .font(.caption)
                            .textCase(nil)
                        }
                    }
                } footer: {
                    Text(bodyFooter)
                }

                if !capturedQuery.isCatchAll {
                    Section {
                        Toggle("Only when \(capturedQuery.summary ?? "")", isOn: $matchesQuery)
                    } header: {
                        Text("Applies to")
                    } footer: {
                        // Off by default: the endpoint key is the right unit
                        // almost always, and a rule silently pinned to one
                        // query would look like it had stopped working.
                        Text("Off, this rule answers every request to \(exchange.endpointKey). On, it answers only this query — which is how you mock page 2 differently from page 1.")
                    }
                }

                Section {
                    Button("Restore the live response") { restore() }
                        .disabled(!isEdited)
                }
            }
            .navigationTitle(mode == .add ? "New mock" : "Edit mock")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(mode == .add ? "Add" : "Save") { save() }
                        .disabled(Int(statusCode.trimmed) == nil || name.trimmed.isEmpty)
                }
            }
        }
        .navigationViewStyle(.stack)
        // A rule edited once already carries the sample its author kept, which
        // beats the live capture — they may have trimmed it down to the fields
        // that matter.
        .onAppear {
            if let saved = existingRule?.requestSample {
                requestText = Self.text(from: saved)
            }
            validity.check(bodyText)
            session.load(Data(bodyText.utf8))
        }
        // One source of truth stays `bodyText` — `save()` builds the mock from
        // it and is untouched by any of this. The tree is a nicer way to write
        // into it, not a second place the body lives.
        .onChange(of: session.ops) { _ in
            guard let edited = session.prettyText else { return }
            bodyText = edited
        }
    }

    // MARK: - State

    private var existingRule: MockRule? {
        lens.mocks.first { $0.endpointKey == exchange.endpointKey && $0.match == chosenMatch }
    }

    /// The conditions that would pin this rule to the captured request.
    private var capturedQuery: MockMatch {
        MockMatch.matchingQuery(of: exchange.request)
    }

    private var chosenMatch: MockMatch { matchesQuery ? capturedQuery : .any }

    /// GETs have nothing to show here, and an empty editor on every rule is
    /// noise on the screen where the response is the point.
    private var hasRequestBody: Bool {
        !(exchange.request.body?.isEmpty ?? true)
    }

    private var isEdited: Bool {
        statusCode.trimmed != "\(exchange.response?.statusCode ?? 200)"
            || bodyText != Self.text(from: exchange.response?.body)
            || (Double(delay.trimmed) ?? 0) != 0
    }

    private var bodyFooter: String {
        guard !bodyText.isEmpty else { return "An empty body, for a 204 or an error the app ignores." }
        if isOversize(bodyText), !isEditingOversizeBody {
            return "\(formatBytes(bodyText.utf8.count)) — shown as a preview. A text editor "
                + "re-lays its whole buffer on every keystroke, so editing this in place would "
                + "freeze the sheet. Saved unchanged, this mock replays the captured body exactly."
        }
        return validity.isValid
            ? "Served as-is. Content-Length is recomputed at delivery, so an edited body cannot truncate."
            : "This is not valid JSON. It is served anyway — mocking a malformed payload is a legitimate thing to do."
    }

    // MARK: - Editors

    /// A body editor that withholds the `TextEditor` until asked, once the
    /// buffer is large enough that `TextEditor` cannot keep up with typing.
    ///
    /// The buffer itself is always loaded — `save()` builds the mock from it,
    /// and an editor holding only part of the body would save a truncated mock.
    @ViewBuilder
    private func editor(
        text: Binding<String>,
        minHeight: CGFloat,
        isOversizeUnlocked: Binding<Bool>,
        onChange: @escaping (String) -> Void = { _ in }
    ) -> some View {
        if isOversize(text.wrappedValue), !isOversizeUnlocked.wrappedValue {
            VStack(alignment: .leading, spacing: 8) {
                Text(text.wrappedValue.prefix(BodyEditorLimit.previewCharacters) + "\n…")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button("Edit anyway") { isOversizeUnlocked.wrappedValue = true }
                    .font(.footnote)
            }
        } else {
            TextEditor(text: text)
                .font(.system(.footnote, design: .monospaced))
                .frame(minHeight: minHeight)
                .onChange(of: text.wrappedValue) { onChange($0) }
        }
    }

    /// `String` is UTF-8 backed, so this is a stored count rather than a walk —
    /// unlike `String.count`, which counts graphemes.
    private func isOversize(_ text: String) -> Bool {
        text.utf8.count > BodyEditorLimit.bytes
    }

    // MARK: - Actions

    /// Reuses the existing rule's id so hit counts and list position survive an
    /// edit, and carries the live headers over untouched — a mock that answers
    /// without the original `Content-Type` fails in the app's decoder for a
    /// reason that has nothing to do with what was being tested.
    private func save() {
        guard let code = Int(statusCode.trimmed) else { return }

        let response = MockResponse(
            statusCode: code,
            headers: exchange.response?.headers ?? [:],
            body: Data(bodyText.utf8),
            delay: max(0, Double(delay.trimmed) ?? 0)
        )
        let sample = hasRequestBody && !requestText.isEmpty ? Data(requestText.utf8) : nil
        let variant = MockVariant(
            name: name.trimmed,
            steps: [.respond(response)],
            requestSample: sample
        )

        switch mode {
        case .add:
            // Adds to the endpoint's library rather than replacing it, so the
            // states already built stay switchable.
            lens.addVariant(variant, for: exchange)

        case .edit:
            var rule = existingRule ?? MockRule(
                id: UUID(),
                endpointKey: exchange.endpointKey,
                variants: [variant],
                match: chosenMatch
            )
            rule.activeVariant = MockVariant(
                id: rule.activeVariantID,
                name: variant.name,
                steps: variant.steps,
                exhaustion: rule.exhaustion,
                requestSample: sample
            )
            rule.match = chosenMatch
            Mocks.shared.set(rule)
        }
        dismiss()
    }

    private func restore() {
        statusCode = "\(exchange.response?.statusCode ?? 200)"
        bodyText = Self.text(from: exchange.response?.body)
        requestText = Self.text(from: exchange.request.body)
        delay = "0"
        session.load(exchange.response?.body)
    }

    /// What has been changed, in the payload's own words.
    ///
    /// Reuses `PatchOp.summary`, which the perturbation audit trail already
    /// renders for humans — the edit reads the same here as it will in the bug
    /// report it ends up in.
    @ViewBuilder
    private var stagedEdits: some View {
        if let failure = session.failure {
            Label(failure, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
        }

        if session.isEdited {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(session.ops) { op in
                    Text(op.summary)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack(spacing: 18) {
                    Button("Undo") { session.undo() }
                    Button("Revert all") { session.revert() }
                    Spacer(minLength: 0)
                    Text("\(session.ops.count) \(session.ops.count == 1 ? "edit" : "edits")")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
            .padding(.top, 4)
        }
    }

    /// The picker and the free-text field share one `String` state, so a preset
    /// fills the field and a typed value that happens to match a preset selects
    /// it. Two sources of truth for one number would let them disagree.
    private static func text(for delay: TimeInterval) -> String {
        delay == delay.rounded() ? "\(Int(delay))" : "\(delay)"
    }

    /// Reformatted through the ordered serializer so key order and number
    /// literals survive the round trip; raw text for anything not JSON.
    ///
    /// Cached, because this runs in `init` — which SwiftUI re-runs whenever the
    /// presenting view redraws — and again in `isEdited` on every evaluation of
    /// this sheet's own `body`.
    private static func text(from data: Data?) -> String {
        BodyText.pretty(from: data)
    }
}

/// Says an endpoint is answered from the device. Tinted like `SourceBadge`'s
/// synthetic cases, so mocked traffic and mocked rules read as the same thing.
struct MockedBadge: View {

    var body: some View {
        Text("MOCKED")
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.purple.opacity(0.18)))
            .foregroundStyle(Color.purple)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
#endif
