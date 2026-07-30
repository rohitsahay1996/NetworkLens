import Foundation

/// Editing helpers for a held request.
///
/// Every mutation here recomputes `Content-Length`. A stale one makes
/// `URLSession` send the wrong number of bytes — the server either truncates
/// the body or waits forever for bytes that never come, and it presents as a
/// hang rather than as an error.
extension URLRequest {

    /// Replaces the body with serialized JSON, preserving key order and number
    /// literals through the milestone 1 serializer.
    public func replacingJSONBody(_ node: JSONNode) -> URLRequest {
        replacingBody(JSONNodeSerializer.data(from: node))
    }

    public func replacingBody(_ data: Data?) -> URLRequest {
        var edited = self
        // A stream body cannot coexist with a data body, and cannot be re-sent
        // once read, so it goes.
        edited.httpBodyStream = nil
        edited.httpBody = data

        if let data {
            edited.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
        } else {
            edited.setValue(nil, forHTTPHeaderField: "Content-Length")
        }
        return edited
    }

    /// Parses the body as an ordered JSON tree, or `nil` for non-JSON.
    public var jsonBody: JSONNode? {
        guard let body = httpBody, !body.isEmpty else { return nil }
        return try? JSONNodeParser.parse(body)
    }

    /// Whether the body can be shown in the tree editor at all.
    ///
    /// Protobuf, images and HTML get a size summary with editing disabled
    /// rather than a crashed parser or a screen of mojibake.
    public var bodyIsEditableAsJSON: Bool { jsonBody != nil }

    /// Replaces one query item, adding it if absent.
    public func replacingQueryItem(name: String, value: String?) -> URLRequest {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return self
        }
        var items = components.queryItems ?? []
        if let index = items.firstIndex(where: { $0.name == name }) {
            if let value {
                items[index].value = value
            } else {
                items.remove(at: index)
            }
        } else if let value {
            items.append(URLQueryItem(name: name, value: value))
        }
        components.queryItems = items.isEmpty ? nil : items

        var edited = self
        edited.url = components.url ?? url
        return edited
    }

    public func replacingHeader(name: String, value: String?) -> URLRequest {
        var edited = self
        edited.setValue(value, forHTTPHeaderField: name)
        return edited
    }

    public var queryItems: [URLQueryItem] {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return []
        }
        return components.queryItems ?? []
    }
}

// MARK: - Non-JSON bodies

/// How to present a body that is not JSON.
public enum BodyPresentation: Sendable, Equatable {
    case json
    case text(String)
    /// Byte count and a short hex preview. Editing is disabled.
    case binary(byteCount: Int, hexPreview: String)
    case empty

    public var isEditable: Bool { self == .json }
}

extension Data {

    /// Classifies a body for display, never throwing and never handing
    /// arbitrary bytes to the tree parser.
    public func bodyPresentation(contentType: String? = nil) -> BodyPresentation {
        guard !isEmpty else { return .empty }
        if (try? JSONNodeParser.parse(self)) != nil { return .json }

        let lowered = contentType?.lowercased() ?? ""
        let looksTextual = lowered.contains("text/")
            || lowered.contains("xml")
            || lowered.contains("html")
            || lowered.contains("urlencoded")

        if looksTextual, let text = String(data: self, encoding: .utf8) {
            return .text(text)
        }
        if lowered.isEmpty, let text = String(data: self, encoding: .utf8) {
            return .text(text)
        }
        return .binary(byteCount: count, hexPreview: hexPreview(limit: 32))
    }

    func hexPreview(limit: Int) -> String {
        let bytes = prefix(limit).map { String(format: "%02x", $0) }.joined(separator: " ")
        return count > limit ? bytes + " …" : bytes
    }
}
