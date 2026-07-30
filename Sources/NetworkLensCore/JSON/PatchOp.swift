//
//  PatchOp.swift
//  NetworkLensCore
//
//  Created by Rohit Sahay on 29/07/26.
//

import Foundation

/// One edit instruction against a `JSONNode` tree.
///
/// Perturbations store these rather than whole payloads, so a saved edit
/// survives contract drift: "set `/data/items/0/stock` to 0" still means
/// something after the server adds three new fields, where a stored payload
/// would have gone stale.
public struct PatchOp: Codable, Sendable, Hashable, Identifiable {

    public enum Kind: String, Codable, Sendable {
        case replace
        case remove
        case add
    }

    public let id: UUID
    public var kind: Kind
    public var path: JSONPointer
    /// Required for `replace` and `add`, ignored by `remove`.
    public var value: JSONNode?

    public init(id: UUID = UUID(), kind: Kind, path: JSONPointer, value: JSONNode? = nil) {
        self.id = id
        self.kind = kind
        self.path = path
        self.value = value
    }

    public init(id: UUID = UUID(), kind: Kind, path: String, value: JSONNode? = nil) throws {
        self.init(id: id, kind: kind, path: try JSONPointer(string: path), value: value)
    }

    // `id` is identity for the UI only, never part of equality — two ops that
    // do the same thing are the same op.
    public static func == (lhs: PatchOp, rhs: PatchOp) -> Bool {
        lhs.kind == rhs.kind && lhs.path == rhs.path && lhs.value == rhs.value
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(path)
        hasher.combine(value)
    }

    /// Human-readable, for the audit log and the bug report bundle.
    public var summary: String {
        switch kind {
        case .remove:
            return "remove \(path)"
        case .replace, .add:
            let rendered = value.map { JSONNodeSerializer.string(from: $0) } ?? "null"
            return "\(kind.rawValue) \(path) = \(rendered)"
        }
    }
}

// MARK: - Application

extension JSONNode {

    /// Applies ops in order, failing on the first one that cannot be applied.
    ///
    /// All-or-nothing: the tree is a value type, so a throw leaves the caller's
    /// original untouched rather than half-patched.
    public func applying(_ ops: [PatchOp]) throws -> JSONNode {
        try ops.reduce(self) { tree, op in try tree.applying(op) }
    }

    public func applying(_ op: PatchOp) throws -> JSONNode {
        switch op.kind {
        case .replace:
            guard let value = op.value else { throw PatchError.missingValue(path: op.path.description) }
            return try replacing(at: op.path.tokens, with: value, fullPath: op.path)
        case .remove:
            return try removing(at: op.path.tokens, fullPath: op.path)
        case .add:
            guard let value = op.value else { throw PatchError.missingValue(path: op.path.description) }
            return try adding(value, at: op.path.tokens, fullPath: op.path)
        }
    }

    /// Reads the node at a pointer, or `nil` when nothing is there.
    public func value(at pointer: JSONPointer) -> JSONNode? {
        var current = self
        for token in pointer.tokens {
            switch current {
            case .object(let entries):
                guard let match = entries.first(where: { $0.key == token }) else { return nil }
                current = match.value
            case .array(let items):
                guard let index = Int(token), items.indices.contains(index) else { return nil }
                current = items[index]
            default:
                return nil
            }
        }
        return current
    }

    // MARK: - Private recursion

    private func replacing(
        at tokens: [String], with value: JSONNode, fullPath: JSONPointer
    ) throws -> JSONNode {
        guard let token = tokens.first else { return value }
        let rest = Array(tokens.dropFirst())

        switch self {
        case .object(let entries):
            guard let index = entries.firstIndex(where: { $0.key == token }) else {
                throw PatchError.pathNotFound(fullPath.description)
            }
            var updated = entries
            updated[index].value = try entries[index].value
                .replacing(at: rest, with: value, fullPath: fullPath)
            return .object(updated)

        case .array(let items):
            let index = try arrayIndex(token, count: items.count, path: fullPath)
            var updated = items
            updated[index] = try items[index].replacing(at: rest, with: value, fullPath: fullPath)
            return .array(updated)

        default:
            throw PatchError.notAContainer(path: fullPath.description, found: typeName)
        }
    }

    private func removing(at tokens: [String], fullPath: JSONPointer) throws -> JSONNode {
        guard let token = tokens.first else {
            // Removing the root is meaningless; treat it as an error rather
            // than silently producing null.
            throw PatchError.cannotAdd(path: fullPath.description)
        }
        let rest = Array(tokens.dropFirst())

        switch self {
        case .object(let entries):
            guard let index = entries.firstIndex(where: { $0.key == token }) else {
                throw PatchError.pathNotFound(fullPath.description)
            }
            var updated = entries
            if rest.isEmpty {
                updated.remove(at: index)
            } else {
                updated[index].value = try entries[index].value
                    .removing(at: rest, fullPath: fullPath)
            }
            return .object(updated)

        case .array(let items):
            let index = try arrayIndex(token, count: items.count, path: fullPath)
            var updated = items
            if rest.isEmpty {
                updated.remove(at: index)
            } else {
                updated[index] = try items[index].removing(at: rest, fullPath: fullPath)
            }
            return .array(updated)

        default:
            throw PatchError.notAContainer(path: fullPath.description, found: typeName)
        }
    }

    private func adding(
        _ value: JSONNode, at tokens: [String], fullPath: JSONPointer
    ) throws -> JSONNode {
        guard let token = tokens.first else { return value }
        let rest = Array(tokens.dropFirst())

        switch self {
        case .object(let entries):
            if rest.isEmpty {
                var updated = entries
                // RFC 6902: add over an existing member replaces it.
                if let index = entries.firstIndex(where: { $0.key == token }) {
                    updated[index].value = value
                } else {
                    updated.append(Entry(key: token, value: value))
                }
                return .object(updated)
            }
            guard let index = entries.firstIndex(where: { $0.key == token }) else {
                throw PatchError.pathNotFound(fullPath.description)
            }
            var updated = entries
            updated[index].value = try entries[index].value
                .adding(value, at: rest, fullPath: fullPath)
            return .object(updated)

        case .array(let items):
            if rest.isEmpty {
                // "-" means append, per RFC 6901.
                if token == "-" { return .array(items + [value]) }
                let index = try arrayIndex(token, count: items.count + 1, path: fullPath)
                var updated = items
                updated.insert(value, at: index)
                return .array(updated)
            }
            let index = try arrayIndex(token, count: items.count, path: fullPath)
            var updated = items
            updated[index] = try items[index].adding(value, at: rest, fullPath: fullPath)
            return .array(updated)

        default:
            throw PatchError.notAContainer(path: fullPath.description, found: typeName)
        }
    }

    private func arrayIndex(_ token: String, count: Int, path: JSONPointer) throws -> Int {
        // Leading zeros are illegal per RFC 6901 and usually signal a key that
        // was meant for an object, so rejecting them catches real mistakes.
        guard let index = Int(token), index >= 0, index < count,
              token == "0" || !token.hasPrefix("0") else {
            throw PatchError.invalidArrayIndex(path: path.description, token: token)
        }
        return index
    }

    var typeName: String {
        switch self {
        case .object: return "an object"
        case .array: return "an array"
        case .string: return "a string"
        case .number: return "a number"
        case .bool: return "a boolean"
        case .null: return "null"
        }
    }
}
