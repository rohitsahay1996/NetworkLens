//
//  JSONTreeView.swift
//  NetworkLensUI
//
//  Created by Rohit Sahay on 30/07/26.
//

#if canImport(UIKit)
import SwiftUI
import NetworkLensCore

/// Collapsible view of a parsed body.
///
/// Built on `JSONNode` rather than `JSONSerialization` so the order the server
/// sent is the order shown — a viewer that sorts keys makes the tree disagree
/// with the raw text beside it, and with any diff taken against the response.
///
/// Rows are produced by flattening the expanded part of the tree into a list
/// rather than by nesting `DisclosureGroup`s. Nesting rebuilds the entire
/// subtree on every toggle, which is exactly the case this is for: a payload
/// large enough that scrolling the raw text is useless.
///
/// The flattening is held in state and edited in place. Deriving it in `body`
/// re-walked the visible tree on every SwiftUI evaluation — and `body` is
/// re-evaluated on every captured request, so simply leaving this screen open
/// while the app kept making calls was enough to lock the main thread.
struct JSONTreeView: View {

    let tree: JSONTree

    /// Collapsed containers, by path.
    @State private var collapsed: Set<String> = []
    /// Only what is visible under `collapsed`, maintained incrementally.
    @State private var rows: [JSONTreeRow.Row] = []
    /// Rows actually drawn. A single expand can uncover tens of thousands of
    /// them, and a `List` measures every row it is handed.
    @State private var visibleRows = Self.pageSize

    private static let pageSize = 300

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(Array(0..<min(visibleRows, rows.count)), id: \.self) { index in
                JSONTreeRow(
                    row: rows[index],
                    isCollapsed: collapsed.contains(rows[index].path),
                    toggle: { toggle(at: index) }
                )
            }

            if rows.count > visibleRows {
                Button {
                    visibleRows += Self.pageSize
                } label: {
                    Text("Show \(min(Self.pageSize, rows.count - visibleRows)) more · "
                         + "\(rows.count - visibleRows) hidden")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .padding(.top, 4)
            }
        }
        .onAppear {
            // Both halves were built off the main thread; this is an assignment.
            guard rows.isEmpty else { return }
            collapsed = tree.collapsed
            rows = tree.rows
        }
    }

    /// Expands or collapses one container, touching only its own subtree.
    ///
    /// Re-flattening the whole payload per tap is what a naive version does,
    /// and on the payloads this view exists for that is the tap that drops
    /// frames. A collapse removes a contiguous run — every descendant sits
    /// directly below its container and is deeper than it — and an expand
    /// inserts exactly one level.
    private func toggle(at index: Int) {
        guard index < rows.count else { return }
        let row = rows[index]
        guard row.isContainer else { return }

        if collapsed.contains(row.path) {
            // Built in a local and assigned once: what the newly uncovered
            // level looks like depends on the child paths added a line earlier,
            // and reading `@State` back mid-update is not something to rely on.
            var updated = collapsed
            updated.remove(row.path)
            updated.formUnion(JSONTree.childContainerPaths(of: row.node, path: row.path))

            var inserted: [JSONTreeRow.Row] = []
            JSONTree.flattenChildren(
                of: row.node, path: row.path, depth: row.depth,
                collapsed: updated, into: &inserted
            )
            collapsed = updated
            rows.insert(contentsOf: inserted, at: index + 1)
        } else {
            collapsed.insert(row.path)
            var end = index + 1
            while end < rows.count, rows[end].depth > row.depth { end += 1 }
            rows.removeSubrange((index + 1)..<end)
        }
    }
}

/// One line of the tree.
struct JSONTreeRow: View {

    struct Row: Sendable {
        let path: String
        /// Key, or array index. `nil` for the root.
        let label: String?
        let node: JSONNode
        let depth: Int

        var isContainer: Bool { node.isContainer }
    }

    let row: Row
    let isCollapsed: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Color.clear.frame(width: CGFloat(row.depth) * 12, height: 1)

            if row.isContainer {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
            } else {
                Color.clear.frame(width: 10, height: 1)
            }

            if let label = row.label {
                Text(label)
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .foregroundStyle(.primary)
                Text(":").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }

            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(valueTint)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .textSelection(.enabled)
    }

    /// A collapsed container summarises what is inside it, so the shape of the
    /// payload survives collapsing. `{…}` alone would make the tree useless as
    /// an overview, which is its main job.
    ///
    /// Scalars are shown on one line, truncated in the middle. A base64 image
    /// in a JSON field is otherwise a single row several screens tall, and it
    /// is laid out before anything below it can be drawn.
    private var value: String {
        switch row.node {
        case .object(let entries):
            return isCollapsed || entries.isEmpty
                ? "{ \(entries.count) \(entries.count == 1 ? "key" : "keys") }"
                : "{"
        case .array(let elements):
            return isCollapsed || elements.isEmpty
                ? "[ \(elements.count) \(elements.count == 1 ? "item" : "items") ]"
                : "["
        case .string(let text):
            return "\"\(text.count > Self.maxScalarLength ? String(text.prefix(Self.maxScalarLength)) + "…" : text)\""
        // Rendered from the literal the server sent, not from a `Double`, so
        // long ids and trailing zeros do not change on the way to the screen.
        case .number(let literal):
            return literal
        case .bool(let flag):
            return flag ? "true" : "false"
        case .null:
            return "null"
        }
    }

    private static let maxScalarLength = 512

    private var valueTint: Color {
        switch row.node {
        case .object, .array: return .secondary
        case .string: return .green
        case .number: return .blue
        case .bool: return .purple
        case .null: return .orange
        }
    }
}
#endif
