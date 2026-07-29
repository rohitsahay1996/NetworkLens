import Foundation

/// Removes credentials and payment data before anything is stored.
///
/// Body redaction goes through `JSONNode`, so key order and number literals
/// survive redaction — the detail view and milestone 2's mock editor both read
/// the redacted tree.
public struct DefaultRedactor: Redactor {

    public static let defaultHeaderNames: Set<String> = [
        "authorization", "cookie", "set-cookie", "x-api-key",
    ]

    public static let defaultBodyKeyTerms: Set<String> = [
        "card", "cvv", "pan", "password", "token", "secret",
    ]

    public static let defaultPlaceholder = "<redacted>"

    /// Compared case-insensitively against header field names.
    public let headerNames: Set<String>

    /// Matched against key *tokens*, case-insensitively. See `matches(key:)`.
    public let bodyKeyTerms: Set<String>

    public let placeholder: String

    public init(
        headerNames: Set<String> = DefaultRedactor.defaultHeaderNames,
        bodyKeyTerms: Set<String> = DefaultRedactor.defaultBodyKeyTerms,
        placeholder: String = DefaultRedactor.defaultPlaceholder
    ) {
        self.headerNames = Set(headerNames.map { $0.lowercased() })
        self.bodyKeyTerms = Set(bodyKeyTerms.map { $0.lowercased() })
        self.placeholder = placeholder
    }

    // MARK: - Redactor

    public func redact(_ request: RequestSnapshot) -> RequestSnapshot {
        var redacted = request
        redacted.headers = redactHeaders(request.headers)
        redacted.url = redactQuery(in: request.url)
        redacted.body = redactBody(request.body, contentType: request.header("Content-Type"))
        return redacted
    }

    public func redact(_ response: ResponseSnapshot) -> ResponseSnapshot {
        var redacted = response
        redacted.headers = redactHeaders(response.headers)
        redacted.body = redactBody(response.body, contentType: response.header("Content-Type"))
        return redacted
    }

    // MARK: - Key matching

    /// A key is sensitive when any of its tokens starts with a sensitive term.
    ///
    /// Tokenising on camelCase, `_`, `-` and digit boundaries is what keeps
    /// `company` and `japan` from matching `pan` while still catching
    /// `cardNumber`, `card_holder`, `cvv2` and `accessToken`. Prefix rather
    /// than exact match so `cardholder` and `tokenExpiry` are covered too —
    /// a false positive costs a hidden field, a false negative leaks a PAN.
    public func matches(key: String) -> Bool {
        // Denylisted header names count as sensitive body keys too. Debug and
        // echo endpoints reflect request headers back inside the response body,
        // so `{"headers":{"authorization":"Bearer …"}}` would otherwise put an
        // auth header on disk through the back door.
        if headerNames.contains(key.lowercased()) { return true }

        for token in Self.tokenize(key) where bodyKeyTerms.contains(where: token.hasPrefix) {
            return true
        }
        return false
    }

    static func tokenize(_ key: String) -> [String] {
        var tokens: [String] = []
        var current = ""

        func flush() {
            if !current.isEmpty { tokens.append(current.lowercased()); current = "" }
        }

        var previous: Character?
        for character in key {
            if character == "_" || character == "-" || character == "." || character == " " {
                flush()
            } else if let previous, character.isUppercase, !previous.isUppercase {
                flush()
                current.append(character)
            } else if let previous, character.isNumber, !previous.isNumber {
                flush()
                current.append(character)
            } else {
                current.append(character)
            }
            previous = character
        }
        flush()
        return tokens
    }

    // MARK: - Headers

    private func redactHeaders(_ headers: [String: String]) -> [String: String] {
        headers.reduce(into: [:]) { result, entry in
            result[entry.key] = headerNames.contains(entry.key.lowercased())
                ? placeholder
                : entry.value
        }
    }

    // MARK: - URL

    /// Query strings routinely carry `?access_token=…`, and the URL is stored
    /// verbatim, so it needs the same treatment as the body.
    private func redactQuery(in url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems, !items.isEmpty else { return url }

        var changed = false
        components.queryItems = items.map { item in
            guard matches(key: item.name), item.value != nil else { return item }
            changed = true
            return URLQueryItem(name: item.name, value: placeholder)
        }
        guard changed else { return url }
        return components.url ?? url
    }

    // MARK: - Body

    private func redactBody(_ body: Data?, contentType: String?) -> Data? {
        guard let body, !body.isEmpty else { return body }

        if let node = try? JSONNodeParser.parse(body) {
            return JSONNodeSerializer.data(from: redactNode(node))
        }
        if contentType?.lowercased().contains("application/x-www-form-urlencoded") == true {
            return redactFormEncoded(body)
        }
        // Unknown format — no field structure to key off, so leave it alone
        // rather than guess. Header and URL redaction still applied.
        return body
    }

    /// Recurses through objects and arrays of objects alike.
    func redactNode(_ node: JSONNode) -> JSONNode {
        switch node {
        case .object(let entries):
            return .object(entries.map { entry in
                guard !matches(key: entry.key) else {
                    return JSONNode.Entry(key: entry.key, value: .string(placeholder))
                }
                return JSONNode.Entry(key: entry.key, value: redactNode(entry.value))
            })
        case .array(let items):
            return .array(items.map(redactNode))
        default:
            return node
        }
    }

    private func redactFormEncoded(_ body: Data) -> Data {
        guard let raw = String(data: body, encoding: .utf8) else { return body }
        let pairs = raw.split(separator: "&", omittingEmptySubsequences: false).map { pair -> String in
            guard let separator = pair.firstIndex(of: "=") else { return String(pair) }
            let name = String(pair[pair.startIndex..<separator])
            let decoded = name.removingPercentEncoding ?? name
            guard matches(key: decoded) else { return String(pair) }
            return "\(name)=\(placeholder)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }
}
