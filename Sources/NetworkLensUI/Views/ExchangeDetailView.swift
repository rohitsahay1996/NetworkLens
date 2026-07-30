#if canImport(UIKit)
import SwiftUI
import NetworkLensCore

/// One exchange, start to finish, plus the two actions worth reaching for from
/// here: mock this response, or break on this endpoint next time.
struct ExchangeDetailView: View {

    let exchange: NetworkExchange

    @EnvironmentObject private var lens: LensObservable
    @State private var confirmation: String?

    var body: some View {
        List {
            Section("Exchange") {
                LabelledRow(label: "Endpoint", value: exchange.endpointKey, monospaced: true)
                LabelledRow(label: "Method", value: exchange.request.method)
                LabelledRow(label: "Screen", value: exchange.screen ?? "—")
                LabelledRow(label: "Source", value: exchange.source.label)
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

            Section("Actions") {
                Button {
                    if lens.mock(exchange) != nil {
                        confirmation = "Mocked \(exchange.endpointKey)"
                    } else {
                        confirmation = "Nothing to mock — this exchange has no response"
                    }
                } label: {
                    Label("Mock this response", systemImage: "square.on.square")
                }
                .disabled(exchange.response == nil)

                Button {
                    Breakpoints.shared.set(
                        Breakpoint(endpointKey: exchange.endpointKey, stage: .response)
                    )
                    confirmation = "Breakpoint armed on \(exchange.endpointKey)"
                } label: {
                    Label("Break on this endpoint", systemImage: "pause.circle")
                }
                .disabled(isBreakpointArmed)
            }

            if let timing = exchange.timing {
                Section("Timing") { TimingBreakdown(timing: timing) }
            }

            Section("Request") {
                if exchange.request.headers.isEmpty {
                    Text("No headers").foregroundStyle(.secondary).font(.footnote)
                } else {
                    ForEach(exchange.request.headers.sorted(by: { $0.key < $1.key }), id: \.key) {
                        LabelledRow(label: $0.key, value: $0.value, monospaced: true)
                    }
                }
                BodyView(
                    data: exchange.request.body,
                    contentType: exchange.request.header("Content-Type"),
                    truncated: exchange.request.bodyTruncated
                )
            }

            if let response = exchange.response {
                Section("Response · \(response.statusCode)") {
                    ForEach(response.headers.sorted(by: { $0.key < $1.key }), id: \.key) {
                        LabelledRow(label: $0.key, value: $0.value, monospaced: true)
                    }
                    BodyView(
                        data: response.body,
                        contentType: response.mimeType ?? response.header("Content-Type"),
                        truncated: response.bodyTruncated
                    )
                }
            }

            if !exchange.edits.isEmpty {
                Section("Edits") {
                    ForEach(exchange.edits) { record in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.perturbationName ?? record.stage.rawValue)
                                .font(.subheadline.weight(.medium))
                            ForEach(record.ops) { op in
                                Text(op.summary)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(exchange.endpointKey)
        .navigationBarTitleDisplayMode(.inline)
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

    private var isBreakpointArmed: Bool {
        lens.breakpoints.contains { $0.endpointKey == exchange.endpointKey }
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
