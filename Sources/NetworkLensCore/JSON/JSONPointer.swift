import Foundation

/// RFC 6901 JSON Pointer.
///
/// `"/data/items/0/stock"` addresses one node in a `JSONNode` tree. Used by
/// `PatchOp` so a perturbation is a reusable instruction rather than a stored
/// payload — that is what lets one saved edit survive contract drift and replay
/// against a different response.
public struct JSONPointer: Codable, Sendable, Hashable, CustomStringConvertible {

    /// Unescaped tokens, outermost first. Empty means the document root.
    public let tokens: [String]

    public init(tokens: [String]) {
        self.tokens = tokens
    }

    /// Parses `"/a/b~1c/0"`. Throws on anything not starting with `/`.
    public init(string: String) throws {
        guard !string.isEmpty else {
            self.tokens = []
            return
        }
        guard string.hasPrefix("/") else {
            throw PatchError.malformedPointer(string)
        }
        // dropFirst then split keeps empty tokens, which are legal: "/" is a
        // pointer to the member whose key is the empty string.
        tokens = string.dropFirst()
            .components(separatedBy: "/")
            .map(Self.unescape)
    }

    public var description: String {
        tokens.isEmpty ? "" : "/" + tokens.map(Self.escape).joined(separator: "/")
    }

    public var isRoot: Bool { tokens.isEmpty }

    public func appending(_ token: String) -> JSONPointer {
        JSONPointer(tokens: tokens + [token])
    }

    /// Drops the last token, giving the container that holds the target.
    public var parent: JSONPointer? {
        tokens.isEmpty ? nil : JSONPointer(tokens: Array(tokens.dropLast()))
    }

    public var lastToken: String? { tokens.last }

    // MARK: - Escaping

    /// `~` is `~0` and `/` is `~1`. Order matters on the way out.
    static func escape(_ token: String) -> String {
        token
            .replacingOccurrences(of: "~", with: "~0")
            .replacingOccurrences(of: "/", with: "~1")
    }

    /// And the reverse order on the way in, or `~01` would decode to `/`
    /// instead of `~1`.
    static func unescape(_ token: String) -> String {
        token
            .replacingOccurrences(of: "~1", with: "/")
            .replacingOccurrences(of: "~0", with: "~")
    }

    // MARK: - Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(string: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

// MARK: - Errors

public enum PatchError: Error, Equatable, CustomStringConvertible, Sendable {
    case malformedPointer(String)
    /// The path does not exist in this document.
    case pathNotFound(String)
    /// A token addressed into something that is not a container, e.g. `/a/b`
    /// where `a` is a string.
    case notAContainer(path: String, found: String)
    /// An array index token that is not a number, or is out of range.
    case invalidArrayIndex(path: String, token: String)
    /// `replace` or `add` with no value supplied.
    case missingValue(path: String)
    /// `add` into an array at `-` is fine; `add` into an object needs a key.
    case cannotAdd(path: String)

    public var description: String {
        switch self {
        case .malformedPointer(let value):
            return "Malformed JSON Pointer '\(value)' — must be empty or start with '/'"
        case .pathNotFound(let path):
            return "No node at '\(path)'"
        case .notAContainer(let path, let found):
            return "Cannot descend into '\(path)' — it is \(found), not an object or array"
        case .invalidArrayIndex(let path, let token):
            return "'\(token)' is not a valid array index at '\(path)'"
        case .missingValue(let path):
            return "No value supplied for the operation at '\(path)'"
        case .cannotAdd(let path):
            return "Cannot add at '\(path)'"
        }
    }
}
