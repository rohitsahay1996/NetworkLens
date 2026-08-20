//
//  BodyEditSession.swift
//  NetworkLensUI
//
//  Created by Rohit Sahay on 20/08/26.
//

#if canImport(UIKit)
import SwiftUI
import NetworkLensCore

/// Edits a JSON body by accumulating `PatchOp`s against the payload it started
/// from, rather than by rewriting its text.
///
/// The same argument `Perturbation` already makes for itself: an edit stored as
/// "replace `/data/items` with `[]`" still means something after the server adds
/// a field, while an edit stored as a rewritten blob of bytes silently becomes a
/// mock of last month's response.
///
/// Ops are replayed from the original on every change rather than applied
/// incrementally to the current tree. That is slightly more work per keystroke
/// and much easier to reason about: `revert` is emptying an array, undo is
/// dropping the last element, and there is no accumulated state to drift.
@MainActor
final class BodyEditSession: ObservableObject {

    /// The payload as captured. Never mutated.
    private(set) var original: JSONNode?

    /// The edits, oldest first, in the order they were made.
    @Published private(set) var ops: [PatchOp] = []

    /// `original` with `ops` applied, flattened for the tree.
    @Published private(set) var tree: JSONTree?

    /// Set when an op could not be applied — a pointer that no longer resolves
    /// because an earlier edit removed its parent. Surfaced rather than
    /// swallowed: an edit that silently does nothing is the worst outcome here.
    @Published var failure: String?

    /// Guards against reloading the same body on every redraw.
    private var loadedFingerprint: BodyFingerprint?

    var isEdited: Bool { !ops.isEmpty }

    var canEdit: Bool { original != nil }

    // MARK: - Loading

    /// Parses a body once. A second call with the same bytes is a no-op, so
    /// this is safe to drive from `onAppear` or `task(id:)`.
    func load(_ data: Data?) {
        let fingerprint = BodyFingerprint(data: data, contentType: nil)
        guard fingerprint != loadedFingerprint else { return }
        loadedFingerprint = fingerprint

        ops = []
        failure = nil
        guard let data, !data.isEmpty, let node = try? JSONNodeParser.parse(data) else {
            original = nil
            tree = nil
            return
        }
        original = node
        tree = JSONTree(node: node)
    }

    // MARK: - Editing

    /// Stages one edit, or reports why it could not be made.
    ///
    /// Validated by replaying the whole list: an op that throws is dropped
    /// rather than left in a list that can no longer be applied, which would
    /// make every later edit fail too.
    func stage(_ op: PatchOp) {
        guard let original else { return }
        let candidate = ops + [op]
        do {
            let node = try original.applying(candidate)
            ops = candidate
            tree = JSONTree(node: node, collapsed: tree?.collapsed)
            failure = nil
        } catch {
            failure = "\(op.summary) could not be applied — \(error)"
        }
    }

    /// Drops the most recent edit.
    func undo() {
        guard !ops.isEmpty, let original else { return }
        let candidate = Array(ops.dropLast())
        ops = candidate
        tree = (try? original.applying(candidate)).map {
            JSONTree(node: $0, collapsed: tree?.collapsed)
        }
        failure = nil
    }

    /// Back to the captured payload, edits discarded.
    func revert() {
        guard let original else { return }
        ops = []
        failure = nil
        tree = JSONTree(node: original, collapsed: tree?.collapsed)
    }

    // MARK: - Output

    /// The edited payload as text, formatted through the ordered serializer so
    /// key order and number literals survive the round trip.
    var prettyText: String? {
        guard let node = tree?.node else { return nil }
        return JSONNodeSerializer.string(from: node, format: .pretty)
    }

    // MARK: - Convenience edits

    /// The three operations people actually reach for, named as intentions
    /// rather than as patch mechanics.
    func setNull(at pointer: JSONPointer) {
        stage(PatchOp(kind: .replace, path: pointer, value: .null))
    }

    func empty(_ node: JSONNode, at pointer: JSONPointer) {
        switch node {
        case .array:
            stage(PatchOp(kind: .replace, path: pointer, value: .array([])))
        case .object:
            stage(PatchOp(kind: .replace, path: pointer, value: .object([])))
        default:
            break
        }
    }

    func remove(at pointer: JSONPointer) {
        stage(PatchOp(kind: .remove, path: pointer))
    }

    func replace(at pointer: JSONPointer, with value: JSONNode) {
        stage(PatchOp(kind: .replace, path: pointer, value: value))
    }

    /// Grows a list without inventing data: the element is copied, so a
    /// paginated screen can be pushed past its page size using rows the server
    /// actually sent.
    ///
    /// Appends rather than inserting in place, and adds them one at a time from
    /// the end, so the indices in the ops stay meaningful when they are read
    /// back later.
    func duplicate(_ node: JSONNode, at pointer: JSONPointer, times: Int) {
        guard times > 0, let parent = pointer.parent else { return }
        for _ in 0..<times {
            stage(PatchOp(kind: .add, path: parent.appending("-"), value: node))
        }
    }
}
#endif
