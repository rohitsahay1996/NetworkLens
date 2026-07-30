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
struct JSONTreeView: View {

    let node: JSONNode

    /// Collapsed containers, by path. Collapsed is the exception, so a small
    /// payload needs no interaction — but see `initiallyCollapsed`.
    @State private var collapsed: Set<String> = []
    @State private var didSeedCollapse = false

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(rows, id: \.path) { row in
                JSONTreeRow(
                    row: row,
                    isCollapsed: collapsed.contains(row.path),
                    toggle: { toggle(row) }
                )
            }
        }
        .onAppear {
            guard !didSeedCollapse else { return }
            didSeedCollapse = true
            collapsed = Self.initiallyCollapsed(node)
        }
    }

    private func toggle(_ row: JSONTreeRow.Row) {
        guard row.isContainer else { return }
        if collapsed.contains(row.path) {
            collapsed.remove(row.path)
        } else {
            collapsed.insert(row.path)
        }
    }

    private var rows: [JSONTreeRow.Row] {
        var output: [JSONTreeRow.Row] = []
        Self.flatten(node, label: nil, path: "", depth: 0, collapsed: collapsed, into: &output)
        return output
    }

    // MARK: - Flattening

    /// Walks only what is visible. A collapsed container contributes its own
    /// row and nothing beneath it, which is what keeps a 10k-node payload
    /// affordable to draw.
    private static func flatten(
        _ node: JSONNode,
        label: String?,
        path: String,
        depth: Int,
        collapsed: Set<String>,
        into output: inout [JSONTreeRow.Row]
    ) {
        let isCollapsed = collapsed.contains(path)
        output.append(
            JSONTreeRow.Row(path: path, label: label, node: node, depth: depth)
        )
        guard node.isContainer, !isCollapsed else { return }

        switch node {
        case .object(let entries):
            for entry in entries {
                flatten(
                    entry.value, label: entry.key, path: "\(path)/\(entry.key)",
                    depth: depth + 1, collapsed: collapsed, into: &output
                )
            }
        case .array(let elements):
            for (index, element) in elements.enumerated() {
                flatten(
                    element, label: "\(index)", path: "\(path)/\(index)",
                    depth: depth + 1, collapsed: collapsed, into: &output
                )
            }
        default:
            break
        }
    }

    /// Collapses containers below the second level on first show.
    ///
    /// The top two levels are the shape of the payload and are what someone
    /// opening a body is looking for; everything under them is detail they can
    /// ask for. Without this a large response opens as a wall of rows, which is
    /// the problem the tree was supposed to solve.
    static func initiallyCollapsed(_ node: JSONNode, maxExpandedDepth: Int = 2) -> Set<String> {
        var output: Set<String> = []
        func walk(_ node: JSONNode, path: String, depth: Int) {
            guard node.isContainer else { return }
            if depth >= maxExpandedDepth { output.insert(path) }

            switch node {
            case .object(let entries):
                for entry in entries {
                    walk(entry.value, path: "\(path)/\(entry.key)", depth: depth + 1)
                }
            case .array(let elements):
                for (index, element) in elements.enumerated() {
                    walk(element, path: "\(path)/\(index)", depth: depth + 1)
                }
            default:
                break
            }
        }
        walk(node, path: "", depth: 0)
        return output
    }
}

/// One line of the tree.
struct JSONTreeRow: View {

    struct Row {
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
                .lineLimit(isCollapsed || !row.isContainer ? 1 : nil)
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
            return "\"\(text)\""
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
