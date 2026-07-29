import Foundation

/// Derives `PatchOp`s from an original tree and an edited one.
///
/// This is how the perturbation library actually gets built. Nobody is going to
/// hand-author JSON Pointer paths on a phone, so "save this edit as a
/// perturbation" has to reduce to a diff.
///
/// The generated ops are guaranteed to reproduce the edit:
/// `original.applying(JSONDiff.ops(from: original, to: edited)) == edited`,
/// byte for byte through the serializer. That invariant is what the round-trip
/// test pins down.
public enum JSONDiff {

    public static func ops(from original: JSONNode, to edited: JSONNode) -> [PatchOp] {
        var collected: [PatchOp] = []
        diff(original, edited, at: JSONPointer(tokens: []), into: &collected)
        return collected
    }

    private static func diff(
        _ original: JSONNode,
        _ edited: JSONNode,
        at path: JSONPointer,
        into ops: inout [PatchOp]
    ) {
        if original == edited { return }

        switch (original, edited) {
        case (.object(let before), .object(let after)):
            diffObject(before, after, at: path, into: &ops)

        case (.array(let before), .array(let after)):
            diffArray(before, after, at: path, into: &ops)

        default:
            // Type changed, or a leaf changed. Either way it is one replace.
            ops.append(PatchOp(kind: .replace, path: path, value: edited))
        }
    }

    private static func diffObject(
        _ before: [JSONNode.Entry],
        _ after: [JSONNode.Entry],
        at path: JSONPointer,
        into ops: inout [PatchOp]
    ) {
        let beforeKeys = before.map(\.key)
        let afterKeys = after.map(\.key)

        // Member-wise ops can only reproduce the edit when the result is
        // "the surviving keys in their original order, then the new ones
        // appended". Anything else — a reordering, or duplicate keys — is not
        // expressible as member ops, because `remove` and `add` cannot say
        // *where*. Reordering is the dangerous case: every key still exists
        // with an equal value, so a member-wise diff finds no ops at all and
        // silently drops the edit. Replace the whole object instead.
        let retained = beforeKeys.filter(afterKeys.contains)
        let added = afterKeys.filter { !beforeKeys.contains($0) }
        let keysAreUnique = Set(beforeKeys).count == beforeKeys.count
            && Set(afterKeys).count == afterKeys.count

        guard keysAreUnique, afterKeys == retained + added else {
            ops.append(PatchOp(kind: .replace, path: path, value: .object(after)))
            return
        }

        // Removals first: doing them before additions keeps later paths valid.
        for entry in before where !afterKeys.contains(entry.key) {
            ops.append(PatchOp(kind: .remove, path: path.appending(entry.key)))
        }

        for entry in after {
            let childPath = path.appending(entry.key)
            guard let existing = before.first(where: { $0.key == entry.key }) else {
                ops.append(PatchOp(kind: .add, path: childPath, value: entry.value))
                continue
            }
            diff(existing.value, entry.value, at: childPath, into: &ops)
        }
    }

    private static func diffArray(
        _ before: [JSONNode],
        _ after: [JSONNode],
        at path: JSONPointer,
        into ops: inout [PatchOp]
    ) {
        // Positional diff. An element inserted at the front shifts everything,
        // which a positional diff renders as "every element changed" — verbose
        // but correct, and QA edits are overwhelmingly in-place value changes
        // rather than insertions.
        let shared = min(before.count, after.count)
        for index in 0..<shared {
            diff(before[index], after[index], at: path.appending("\(index)"), into: &ops)
        }

        if after.count > before.count {
            for element in after[before.count...] {
                ops.append(PatchOp(kind: .add, path: path.appending("-"), value: element))
            }
        } else if before.count > after.count {
            // Remove from the back, so each index is still valid when its op
            // runs. Removing front-first would shift the ones behind it.
            for index in stride(from: before.count - 1, through: after.count, by: -1) {
                ops.append(PatchOp(kind: .remove, path: path.appending("\(index)")))
            }
        }
    }
}

// MARK: - Hashing

extension JSONNode {

    /// Stable fingerprint of the payload, for the edit audit log.
    ///
    /// Serialized-then-hashed so it reflects ordering and number literals — two
    /// payloads that differ only in key order are genuinely different documents
    /// here and should not share a hash.
    public var contentHash: String {
        Self.hash(Data(JSONNodeSerializer.string(from: self).utf8))
    }

    /// Shape fingerprint: keys and container structure, values ignored.
    ///
    /// A perturbation records this so it can warn when the response contract
    /// has drifted out from under a saved edit.
    public var shapeHash: String {
        Self.hash(Data(shapeDescription.utf8))
    }

    private var shapeDescription: String {
        switch self {
        case .object(let entries):
            return "{" + entries.map { "\($0.key):\($0.value.shapeDescription)" }
                .joined(separator: ",") + "}"
        case .array(let items):
            // Only the first element's shape matters — a 3-element and a
            // 300-element list of the same objects are the same contract.
            return "[" + (items.first?.shapeDescription ?? "") + "]"
        case .string: return "s"
        case .number: return "n"
        case .bool: return "b"
        case .null: return "z"
        }
    }

    /// FNV-1a. Not cryptographic — this identifies payloads in a debug log, it
    /// does not authenticate them, and avoiding CryptoKit keeps Core on
    /// Foundation alone.
    private static func hash(_ data: Data) -> String {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01B3
        }
        return String(value, radix: 16)
    }
}
