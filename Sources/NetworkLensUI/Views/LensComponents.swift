#if canImport(UIKit)
import SwiftUI
import NetworkLensCore

/// Provenance badge. Anything the tool synthesised is tinted the same, so a
/// scan of the list separates real traffic from tool output without reading.
struct SourceBadge: View {

    let source: Source

    var body: some View {
        Text(source.label)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.18)))
            .foregroundStyle(tint)
    }

    private var tint: Color { source.isSynthetic ? .purple : .green }
}

/// Status code, transport error, or a spinner while the request is in flight.
struct StatusPill: View {

    let exchange: NetworkExchange

    var body: some View {
        Group {
            if exchange.isInFlight {
                ProgressView().scaleEffect(0.7)
            } else {
                Text(text)
                    .font(.caption.bold())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(tint.opacity(0.18)))
                    .foregroundStyle(tint)
            }
        }
    }

    private var text: String {
        if let status = exchange.response?.statusCode { return "\(status)" }
        if let kind = exchange.failure?.kind { return kind.rawValue }
        return "—"
    }

    private var tint: Color {
        if exchange.response?.isSuccess == true { return .green }
        if exchange.failure != nil { return .red }
        return .secondary
    }
}

/// Milliseconds under a second, seconds above it. Nobody reads "1340.281 ms".
func formatDuration(_ seconds: TimeInterval) -> String {
    seconds < 1
        ? String(format: "%.0f ms", seconds * 1000)
        : String(format: "%.2f s", seconds)
}

func formatBytes(_ count: Int) -> String {
    count < 1024 ? "\(count) B" : String(format: "%.1f KB", Double(count) / 1024)
}

/// Key/value row used throughout the inspector.
struct LabelledRow: View {

    let label: String
    let value: String
    var monospaced: Bool = false

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(monospaced ? .system(.footnote, design: .monospaced) : .body)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.subheadline)
    }
}

/// Renders a body according to what it actually is, rather than forcing every
/// payload through a JSON parser and showing mojibake when it is not JSON.
struct BodyView: View {

    let data: Data?
    let contentType: String?
    var truncated: Bool = false

    var body: some View {
        switch presentation {
        case .empty:
            Text("No body").foregroundStyle(.secondary).font(.footnote)

        case .json:
            scrollingText(prettyJSON)

        case .text(let text):
            scrollingText(text)

        case .binary(let byteCount, let hexPreview):
            VStack(alignment: .leading, spacing: 6) {
                Text("Binary · \(formatBytes(byteCount))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(hexPreview)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var presentation: BodyPresentation {
        (data ?? Data()).bodyPresentation(contentType: contentType)
    }

    /// Reformatted through the ordered serializer, so key order and number
    /// literals survive — a pretty-printer that reorders keys makes a diff
    /// against the server's response useless.
    private var prettyJSON: String {
        guard let data, let node = try? JSONNodeParser.parse(data) else { return "" }
        return JSONNodeSerializer.string(from: node, format: .pretty)
    }

    private func scrollingText(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if truncated {
                Label("Truncated by the capture cap", systemImage: "scissors")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }
}

/// Empty-state placeholder. `ContentUnavailableView` is iOS 17, and this
/// package still supports 15.
struct EmptyStateView: View {

    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}
#endif
