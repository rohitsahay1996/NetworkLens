//
//  LensComponents.swift
//  NetworkLensUI
//
//  Created by Rohit Sahay on 30/07/26.
//

#if canImport(UIKit)
import SwiftUI
import UIKit
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
    var isCopyable: Bool = false

    /// What the copy button puts on the pasteboard, when that differs from what the row reads.
    var copyValue: String?

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(monospaced ? .system(.footnote, design: .monospaced) : .body)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
            if isCopyable {
                CopyValueButton(text: { copyValue ?? value }, accessibilityLabel: "Copy \(label)")
            }
        }
        .font(.subheadline)
    }
}

/// The request's verb, badged. Squared off rather than a `StatusPill` capsule, so two badges side by side do not read as one control.
struct MethodBadge: View {

    let method: String

    var body: some View {
        Text(method.uppercased())
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.16)))
            .foregroundStyle(tint)
    }

    private var tint: Color {
        switch method.uppercased() {
        case "GET": return .blue
        case "POST": return .indigo
        case "PUT": return .orange
        case "PATCH": return .purple
        case "DELETE": return .red
        default: return .secondary
        }
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
///
/// The payload is classified, parsed and laid out once, off the main thread,
/// and the result is cached — see `RenderedBody`. Everything here is a read of
/// that result, so a store notification arriving while this is on screen costs
/// a redraw rather than another parse of a megabyte.
struct BodyView: View {

    let data: Data?
    let contentType: String?
    var truncated: Bool = false

    /// Remembered across bodies rather than per view, so someone who prefers
    /// raw text does not have to re-pick it on every row they open.
    @AppStorage("com.networklens.bodyViewMode") private var mode: BodyViewMode = .tree

    @State private var rendered: RenderedBody?

    private var fingerprint: BodyFingerprint {
        BodyFingerprint(data: data, contentType: contentType)
    }

    var body: some View {
        Group {
            if let rendered {
                content(rendered)
            } else {
                // Only reached for a body big enough to have gone to a
                // background task. A small one is ready on the next frame.
                HStack(spacing: 6) {
                    ProgressView()
                    Text("Reading \(formatBytes(data?.count ?? 0))…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: fingerprint) { await load() }
    }

    /// Renders off the main thread once the payload is large enough for the
    /// hop to be cheaper than the parse. Small bodies stay inline: a detached
    /// task costs a frame, and most captured bodies are a few kilobytes.
    private func load() async {
        let fingerprint = self.fingerprint
        if let cached = BodyRenderCache.shared.value(for: fingerprint) {
            rendered = cached
            return
        }

        let data = self.data
        let contentType = self.contentType
        let built: RenderedBody
        if fingerprint.isLarge {
            built = await Task.detached(priority: .userInitiated) {
                RenderedBody.make(data: data, contentType: contentType)
            }.value
        } else {
            built = RenderedBody.make(data: data, contentType: contentType)
        }

        guard !Task.isCancelled else { return }
        BodyRenderCache.shared.store(built, for: fingerprint)
        rendered = built
    }

    @ViewBuilder
    private func content(_ rendered: RenderedBody) -> some View {
        switch rendered.kind {
        case .empty:
            Text("No body").foregroundStyle(.secondary).font(.footnote)

        case .json(let tree):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Picker("View", selection: $mode) {
                        ForEach(BodyViewMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    // Copies the whole payload in either mode. The tree draws a
                    // page at a time and the raw view is paged too, so without
                    // this there is no way to get a large body off the device.
                    CopyValueButton(text: { rendered.fullText }, accessibilityLabel: "Copy body")
                }

                truncationNotice

                if mode == .tree {
                    JSONTreeView(tree: tree).id(fingerprint)
                } else {
                    PagedTextView(lines: rendered.lines).id(fingerprint)
                }
            }

        case .text:
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    truncationNotice
                    Spacer(minLength: 8)
                    CopyValueButton(text: { rendered.fullText }, accessibilityLabel: "Copy body")
                }
                PagedTextView(lines: rendered.lines).id(fingerprint)
            }

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

    @ViewBuilder
    private var truncationNotice: some View {
        if truncated {
            Label("Truncated by the capture cap", systemImage: "scissors")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }
}

/// Monospaced text, drawn a page of lines at a time.
///
/// One `Text` holding the whole payload is what the raw view used to be, and
/// TextKit lays a string out in full before the first frame — a megabyte of
/// pretty-printed JSON is several seconds of frozen main thread, and enabling
/// selection on it makes that worse. Lines are pre-split by `RenderedBody`;
/// this only decides how many of them to hand to SwiftUI.
struct PagedTextView: View {

    let lines: [RenderedBody.Line]

    @State private var visible = PagedTextView.pageSize

    private static let pageSize = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(lines.prefix(visible)) { line in
                        Text(line.text)
                            .font(.system(.footnote, design: .monospaced))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .textSelection(.enabled)
            }

            if lines.count > visible {
                // Copying lives on the body header, not here: it applies to the
                // tree just as much, and two copy buttons meaning the same
                // thing is worse than one somewhere predictable.
                Button("Show \(min(Self.pageSize, lines.count - visible)) more") {
                    visible += Self.pageSize
                }
                .font(.caption2)
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)

                Text("\(lines.count - visible) of \(lines.count) lines hidden")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Puts a value on the pasteboard and confirms in place, since some hosts — the mock and breakpoint editors — have no toast of their own.
struct CopyValueButton: View {

    /// A closure rather than a `String`, so building the value costs nothing until the button is actually tapped.
    let text: () -> String

    var accessibilityLabel: String = "Copy"

    @State private var didCopy = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text()
            didCopy = true
        } label: {
            Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                .font(.footnote)
                .foregroundStyle(didCopy ? Color.green : Color.accentColor)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(didCopy ? "Copied" : accessibilityLabel)
        // Keyed on the flag, so a second tap restarts the countdown rather than
        // letting the first one clear the tick mid-confirmation.
        .task(id: didCopy) {
            guard didCopy else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            didCopy = false
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
