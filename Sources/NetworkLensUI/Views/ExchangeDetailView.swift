//
//  ExchangeDetailView.swift
//  NetworkLensUI
//
//  Created by Rohit Sahay on 30/07/26.
//

#if canImport(UIKit)
import SwiftUI
import NetworkLensCore

/// One exchange, start to finish, plus the two actions worth reaching for from
/// here: mock this response, or break on this endpoint next time.
struct ExchangeDetailView: View {

    let exchange: NetworkExchange

    @EnvironmentObject private var lens: LensObservable
    @State private var confirmation: String?
    @State private var isMockEditorPresented = false
    @State private var editorMode: MockFromExchangeSheet.Mode = .add

    /// Only the two payloads start open. Everything else is a question asked
    /// about them, and a detail screen that opens fully expanded buries the
    /// bodies under metadata — which is the state this screen is read in.
    @State private var expanded: Set<String> = ["Request", "Response"]

    var body: some View {
        List {
            // The app is waiting on this one, so it outranks even the payload.
            if lens.isHeld(exchange) {
                Section {
                    Button {
                        lens.resume(exchange)
                        confirmation = "Resumed"
                    } label: {
                        Label("Resume this request", systemImage: "play.fill")
                    }
                }
            }

            // The way out of a loading state you asked for. Without it the only
            // exits are the app's timeout and killing the app.
            if lens.isHanging(exchange) {
                Section {
                    Button {
                        lens.releaseHang(exchange)
                        confirmation = "Loading — going to the network"
                    } label: {
                        Label("Load it now", systemImage: "play.circle.fill")
                    }
                } footer: {
                    Text("Resumes the real request from where it was parked, so the loaded state is the server's data rather than something the tool made up.")
                }
            }

            CollapsibleSection(id: "Actions", title: "Actions", expanded: $expanded) {
                // Ungrouped: what the endpoint is doing right now, and the one
                // control the whole loop runs through. Everything below is a
                // change you make occasionally; these three are read and used
                // on every pass.
                if isEndpointMocked {
                    Toggle(isOn: Binding(
                        get: { lens.isServingMock(for: exchange) },
                        set: { lens.setMockServing($0, for: exchange) }
                    )) {
                        Label(
                            lens.isServingMock(for: exchange) ? "Serving mock" : "Serving live",
                            systemImage: lens.isServingMock(for: exchange)
                                ? "square.on.square" : "antenna.radiowaves.left.and.right"
                        )
                    }
                }

                if let rule = lens.rule(for: exchange), rule.variants.count > 1 {
                    Picker(
                        "Variant",
                        selection: Binding(
                            get: { rule.activeVariantID },
                            set: { id in
                                guard let variant = rule.variants.first(where: { $0.id == id })
                                else { return }
                                lens.activateVariant(variant, in: rule)
                            }
                        )
                    ) {
                        ForEach(rule.variants) { variant in
                            Text(variant.name).tag(variant.id)
                        }
                    }
                }

                Button {
                    lens.replay(exchange)
                    confirmation = "Replaying \(exchange.endpointKey)"
                } label: {
                    Label("Replay this request", systemImage: "arrow.clockwise")
                }
                .disabled(!lens.canReplay(exchange))

                // Grouped below, because the list had grown to eleven controls
                // and the two that matter were somewhere in the middle of it.
                DisclosureBlock(title: "Mocking", startsOpen: true) {
                    ActionButton(
                        title: "Add a mock…",
                        icon: "plus.square.on.square",
                        isEnabled: exchange.response != nil
                    ) {
                        editorMode = .add
                        isMockEditorPresented = true
                    }

                    if isEndpointMocked {
                        ActionButton(title: "Edit the active mock", icon: "square.on.square") {
                            editorMode = .edit
                            isMockEditorPresented = true
                        }
                    }

                    // The one-tap version of the loading state, because that is
                    // how it is nearly always wanted: pin this endpoint open and
                    // go look at what the screen does.
                    ActionButton(title: "Keep this endpoint loading", icon: "hourglass") {
                        Mocks.shared.set(
                            MockRule(
                                endpointKey: exchange.endpointKey,
                                steps: [.hang],
                                name: "stuck loading"
                            )
                        )
                        if !Mocks.shared.isMockingEnabled { Mocks.shared.setMockingEnabled(true) }
                        confirmation = "\(exchange.endpointKey) will stay loading"
                    }
                }

                DisclosureBlock(title: "Breakpoint") {
                    // Toggles rather than disabling itself. A disabled button
                    // says "you cannot do this", when what is true is "it is
                    // already done" — and the way to undo it was a different tab.
                    if isBreakpointArmed {
                        ActionButton(
                            title: "Remove breakpoint",
                            icon: "pause.circle.fill",
                            tint: .red
                        ) {
                            for breakpoint in lens.breakpoints
                            where breakpoint.endpointKey == exchange.endpointKey {
                                Breakpoints.shared.remove(id: breakpoint.id)
                            }
                            confirmation = "Breakpoint removed"
                        }
                    } else {
                        ActionButton(title: "Break on this endpoint", icon: "pause.circle") {
                            Breakpoints.shared.set(
                                Breakpoint(endpointKey: exchange.endpointKey, stage: .response)
                            )
                            confirmation = "Breakpoint armed on \(exchange.endpointKey)"
                        }
                    }
                }

                DisclosureBlock(title: "Share") {
                    // Redacted by default. The unredacted form is a second,
                    // differently-worded action rather than a default with a
                    // warning: a copied command is on its way somewhere else.
                    ActionButton(title: "Copy as cURL", icon: "doc.on.doc") {
                        lens.copyCurl(for: exchange)
                        confirmation = "Copied cURL"
                    }

                    if lens.canIncludeSecrets(in: exchange) {
                        ActionButton(title: "Copy as cURL with secrets", icon: "key") {
                            lens.copyCurl(for: exchange, secrets: .included)
                            confirmation = "Copied with real headers"
                        }
                    }
                }
            }

            CollapsibleSection(id: "Exchange", title: "Exchange", expanded: $expanded) {
                LabelledRow(label: "Endpoint", value: exchange.endpointKey, monospaced: true)
                LabelledRow(label: "Method", value: exchange.request.method)
                LabelledRow(label: "Screen", value: exchange.screen ?? "—")
                LabelledRow(label: "Source", value: exchange.source.label)
                // Says the *endpoint* is mocked from now on, which is a
                // different claim from `Source` — that one says where these
                // particular bytes came from, and a rule armed after the fact
                // does not rewrite history.
                if isEndpointMocked {
                    HStack {
                        Text("Mock rule").foregroundStyle(.secondary)
                        Spacer()
                        MockedBadge()
                    }
                }
                LabelledRow(
                    label: "URL",
                    value: exchange.request.url.absoluteString,
                    monospaced: true
                )
                if let failure = exchange.failure {
                    LabelledRow(
                        label: "Failure",
                        value: "\(failure.kind.rawValue) — \(failure.message)"
                    )
                }
            }

            if let timing = exchange.timing {
                CollapsibleSection(id: "Timing", title: "Timing", expanded: $expanded) {
                    TimingBreakdown(timing: timing)
                }
            }

            if !exchange.request.headers.isEmpty {
                CollapsibleSection(
                    id: "RequestHeaders", title: "Request headers", expanded: $expanded
                ) {
                    ForEach(exchange.request.headers.sorted(by: { $0.key < $1.key }), id: \.key) {
                        LabelledRow(label: $0.key, value: $0.value, monospaced: true)
                    }
                }
            }

            CollapsibleSection(id: "Request", title: "Request", expanded: $expanded) {
                BodyView(
                    data: exchange.request.body,
                    contentType: exchange.request.header("Content-Type"),
                    truncated: exchange.request.bodyTruncated
                )
            }

            if let response = exchange.response, !response.headers.isEmpty {
                CollapsibleSection(
                    id: "ResponseHeaders", title: "Response headers", expanded: $expanded
                ) {
                    ForEach(response.headers.sorted(by: { $0.key < $1.key }), id: \.key) {
                        LabelledRow(label: $0.key, value: $0.value, monospaced: true)
                    }
                }
            }

            if !exchange.edits.isEmpty {
                CollapsibleSection(id: "Edits", title: "Edits", expanded: $expanded) {
                    ForEach(exchange.edits) { record in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.perturbationName ?? record.stage.rawValue)
                                .font(.subheadline.weight(.medium))
                            ForEach(record.ops) { op in
                                Text(op.summary)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            // The edit still applied. This says the response no
                            // longer looks like the one it was captured
                            // against, so what it produced may not be what the
                            // name promises.
                            if record.shapeDrifted {
                                Label(
                                    "Response shape changed since this was saved",
                                    systemImage: "exclamationmark.triangle.fill"
                                )
                                .font(.caption2)
                                .foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }

            // Last, because it is the tall one: a large body in tree view fills
            // the screen, and anything below it is reachable only by scrolling
            // past the whole payload.
            responseSection
        }
        .navigationTitle(exchange.endpointKey)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isMockEditorPresented) {
            MockFromExchangeSheet(exchange: exchange, mode: editorMode)
                .environmentObject(lens)
        }
        .overlay(alignment: .bottom) {
            if let confirmation {
                Text(confirmation)
                    .font(.footnote)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.thinMaterial))
                    .padding(.bottom, 16)
                    .transition(.opacity)
                    .task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        withAnimation { self.confirmation = nil }
                    }
            }
        }
    }

    /// The payload, or an honest account of why there isn't one yet. An empty
    /// top section would read as "the response was empty", which is a different
    /// thing from in flight, held, or failed.
    @ViewBuilder
    private var responseSection: some View {
        if let response = exchange.response {
            CollapsibleSection(
                id: "Response",
                title: "Response · \(response.statusCode)",
                expanded: $expanded
            ) {
                BodyView(
                    data: response.body,
                    contentType: response.mimeType ?? response.header("Content-Type"),
                    truncated: response.bodyTruncated
                )
            }
        } else if let failure = exchange.failure {
            CollapsibleSection(id: "Response", title: "Response", expanded: $expanded) {
                Label(
                    "\(failure.kind.rawValue) — \(failure.message)",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.footnote)
                .foregroundStyle(.red)
            }
        } else {
            CollapsibleSection(id: "Response", title: "Response", expanded: $expanded) {
                Label(
                    lens.isHeld(exchange) ? "Held at a breakpoint" : "In flight",
                    systemImage: lens.isHeld(exchange) ? "pause.fill" : "clock"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var isBreakpointArmed: Bool {
        lens.breakpoints.contains { $0.endpointKey == exchange.endpointKey }
    }

    private var isEndpointMocked: Bool {
        lens.mocks.contains { $0.endpointKey == exchange.endpointKey && $0.isEnabled }
    }
}

/// Phase breakdown from `URLSessionTaskMetrics`. Only the phases the metrics
/// actually reported are drawn — a fabricated zero reads as "instant", which
/// is the opposite of "not measured".
struct TimingBreakdown: View {

    let timing: Timing

    var body: some View {
        LabelledRow(label: "Total", value: formatDuration(timing.total))
        phase("DNS", timing.domainLookup)
        phase("Connect", timing.connect)
        phase("TLS", timing.tls)
        phase("Upload", timing.requestUpload)
        phase("Server", timing.serverThink)
        phase("Download", timing.responseDownload)

        if timing.isReusedConnection {
            LabelledRow(label: "Connection", value: "reused")
        }
        if timing.fromCache {
            LabelledRow(label: "Cache", value: "served from cache")
        }
        if let proto = timing.networkProtocolName {
            LabelledRow(label: "Protocol", value: proto)
        }
    }

    @ViewBuilder
    private func phase(_ label: String, _ value: TimeInterval?) -> some View {
        if let value {
            LabelledRow(label: label, value: formatDuration(value))
        }
    }
}
#endif
