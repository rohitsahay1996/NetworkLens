//
//  GraphQLMatcher.swift
//  NetworkLensCore
//
//  Created by Rohit Sahay on 29/07/26.
//

import Foundation

/// Identifies GraphQL operations by body field rather than by path.
///
/// This is the matcher that proves the abstraction earns its keep: every
/// operation in a GraphQL app shares `POST /graphql`, so `PathMatcher` would
/// collapse the entire API into a single row.
///
/// Key format: `"GRAPHQL GetUserProfile"`.
public struct GraphQLMatcher: RequestMatcher {

    public let identifier: String

    /// Paths treated as GraphQL endpoints. Compared case-insensitively against
    /// the URL path.
    public let paths: Set<String>

    public init(identifier: String = "graphql", paths: Set<String> = ["/graphql"]) {
        self.identifier = identifier
        self.paths = Set(paths.map { $0.lowercased() })
    }

    public func endpointKey(for request: URLRequest) -> String? {
        guard let url = request.url, paths.contains(url.path.lowercased()) else { return nil }
        guard let body = request.httpBody, !body.isEmpty else { return nil }
        guard let root = try? JSONNodeParser.parse(body) else { return nil }

        // Batched queries arrive as an array of operation objects.
        if case .array(let operations) = root {
            let names = operations.compactMap(Self.operationName(in:))
            guard !names.isEmpty else { return nil }
            return "GRAPHQL [\(names.joined(separator: ", "))]"
        }
        guard let name = Self.operationName(in: root) else { return nil }
        return "GRAPHQL \(name)"
    }

    /// Prefers the explicit `operationName` field, falling back to parsing the
    /// name out of the query document — Apollo iOS omits `operationName` when
    /// the document holds exactly one operation.
    private static func operationName(in node: JSONNode) -> String? {
        if let explicit = node["operationName"]?.stringValue, !explicit.isEmpty {
            return explicit
        }
        guard let query = node["query"]?.stringValue else { return nil }
        return parseOperationName(fromDocument: query)
    }

    /// Scans `query Foo(...)` / `mutation Foo {` / `subscription Foo {` and
    /// returns `Foo`. Returns `nil` for anonymous documents like `{ me { id } }`.
    static func parseOperationName(fromDocument document: String) -> String? {
        var scanner = Substring(document)

        func skipSpaces() {
            while let first = scanner.first, first.isWhitespace { scanner.removeFirst() }
        }

        skipSpaces()
        for keyword in ["query", "mutation", "subscription"] {
            guard scanner.hasPrefix(keyword) else { continue }
            scanner.removeFirst(keyword.count)
            skipSpaces()
            let name = scanner.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            return name.isEmpty ? nil : String(name)
        }
        return nil
    }
}
