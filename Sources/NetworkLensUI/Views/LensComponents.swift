//
//  LensComponents.swift
//  NetworkLensUI
//
//  Created by Rohit Sahay on 30/07/26.
//

#if canImport(UIKit)
import SwiftUI
import NetworkLensCore

/// Provenance badge. Anything the tool synthesised is tinted the same, so a
/// scan of the list separates real traffic from tool output without reading.
struct SourceBadge: View {

    let source: Source

    var body: some View {
        Text(source.label.uppercased())
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

/// How a JSON body is drawn. Only offered for JSON — text and binary have no
/// tree, and a picker with one usable option is worse than no picker.
enum BodyViewMode: String, CaseIterable {
    case tree
    case raw

    var label: String {
        switch self {
        case .tree: return "Tree"
        case .raw: return "Raw"
        }
    }
}

/// Renders a body according to what it actually is, rather than forcing every
/// payload through a JSON parser and showing mojibake when it is not JSON.
struct BodyView: View {

    let data: Data?
    let contentType: String?
    var truncated: Bool = false

    /// Remembered across bodies rather than per view, so someone who prefers
    /// raw text does not have to re-pick it on every row they open.
    @AppStorage("com.networklens.bodyViewMode") private var mode: BodyViewMode = .tree

    var body: some View {
        switch presentation {
        case .empty:
            Text("No body").foregroundStyle(.secondary).font(.footnote)

        case .json:
            VStack(alignment: .leading, spacing: 8) {
                Picker("View", selection: $mode) {
                    ForEach(BodyViewMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                if truncated {
                    Label("Truncated by the capture cap", systemImage: "scissors")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                switch mode {
                case .tree:
                    if let node = parsed {
                        JSONTreeView(node: node)
                    } else {
                        // Truncation cuts a body mid-token, so the capture is
                        // real but unparseable. Raw is the honest fallback.
                        scrollingText(rawText)
                    }
                case .raw:
                    scrollingText(prettyJSON)
                }
            }

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

    private var parsed: JSONNode? {
        guard let data else { return nil }
        return try? JSONNodeParser.parse(data)
    }

    private var rawText: String {
        guard let data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
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

/// A list section that folds away.
///
/// Built from a plain `Section` with a tappable header rather than
/// `DisclosureGroup`, which draws its own indentation and disclosure chrome
/// inside a list row and stops looking like the rest of the sections.
///
/// `id` is separate from `title` because a title can carry live detail — the
/// response header shows its status code — and the expanded set has to survive
/// that changing.
struct CollapsibleSection<Content: View>: View {

    let id: String
    let title: String
    @Binding var expanded: Set<String>
    @ViewBuilder let content: () -> Content

    private var isExpanded: Bool { expanded.contains(id) }

    var body: some View {
        Section {
            if isExpanded { content() }
        } header: {
            Button {
                if isExpanded { expanded.remove(id) } else { expanded.insert(id) }
            } label: {
                HStack {
                    Text(title)
                    Spacer(minLength: 8)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
