import Foundation

/// An ordered, lossless JSON model.
///
/// `JSONSerialization` is unusable for this package: it parses objects into
/// `[String: Any]`, which loses key order and collapses duplicate keys, and it
/// parses numbers into `NSNumber`, which turns `1.0` into `1` and rounds large
/// integers. Milestone 2 edits this tree and writes it back, so number literals
/// are kept as their original source text and object entries stay an array.
public indirect enum JSONNode: Sendable, Hashable, Codable {
    case object([Entry])
    case array([JSONNode])
    case string(String)
    /// The literal exactly as it appeared in the source, e.g. `"1.0"`, `"1e-7"`,
    /// `"9007199254740993"`. Never re-formatted.
    case number(String)
    case bool(Bool)
    case null

    /// One key/value pair. A named struct rather than a tuple so the enum stays
    /// `Hashable` and `Codable`-friendly.
    public struct Entry: Sendable, Hashable {
        public var key: String
        public var value: JSONNode

        public init(key: String, value: JSONNode) {
            self.key = key
            self.value = value
        }
    }
}

// MARK: - Codable

extension JSONNode {

    /// Encoded as its JSON source text in a single value container.
    ///
    /// The synthesised enum encoding would work, but it would bury a payload
    /// inside `{"object":{"_0":[…]}}` wrappers in every trace file and bug
    /// report. Round-tripping through the lossless parser and serializer keeps
    /// ordering and number literals and stays readable to a human opening the
    /// file in an editor.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        self = try JSONNodeParser.parse(text)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(JSONNodeSerializer.string(from: self))
    }
}

extension JSONNode {

    /// First value for `key`, in document order. Duplicate keys are preserved
    /// in the tree; this returns the first.
    public subscript(key: String) -> JSONNode? {
        guard case .object(let entries) = self else { return nil }
        return entries.first { $0.key == key }?.value
    }

    public subscript(index: Int) -> JSONNode? {
        guard case .array(let items) = self, items.indices.contains(index) else { return nil }
        return items[index]
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// The number literal as written. Use `doubleValue` only for display maths.
    public var numberLiteral: String? {
        if case .number(let literal) = self { return literal }
        return nil
    }

    public var doubleValue: Double? {
        guard case .number(let literal) = self else { return nil }
        return Double(literal)
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public var isContainer: Bool {
        switch self {
        case .object, .array: return true
        default: return false
        }
    }
}
