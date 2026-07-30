//
//  MockMatch.swift
//  NetworkLensCore
//
//  Created by Rohit Sahay on 30/07/26.
//

import Foundation

/// Extra conditions narrowing a rule to some of an endpoint's traffic.
///
/// `endpointKey` deliberately throws the query string away — that is what makes
/// one rule cover `/users/1` and `/users/2`, and it is right almost always. The
/// exception is the case list-heavy apps live in: `GET /items?page=1` and
/// `?page=2` are one key, so "first page full, second page empty" — and every
/// end-of-pagination bug behind it — could not be expressed at all.
///
/// Conditions are AND-ed, and every field left empty matches everything, so the
/// default value is a catch-all that behaves exactly as rules did before.
public struct MockMatch: Codable, Sendable, Hashable {

    /// Query items that must be present with these values.
    ///
    /// A value of `MockMatch.anyValue` matches any value, for "only when
    /// `cursor` is present at all".
    public var query: [String: String]

    /// Header names and values that must be present. Names compare
    /// case-insensitively, because HTTP header names are.
    public var headers: [String: String]

    /// Substring the request body must contain.
    ///
    /// Blunt on purpose: it exists to separate two GraphQL operations or two
    /// POSTs to the same path, and a substring does that without a query
    /// language nobody wants to learn inside a debugging tool.
    public var bodyContains: String?

    public static let anyValue = "*"

    public init(
        query: [String: String] = [:],
        headers: [String: String] = [:],
        bodyContains: String? = nil
    ) {
        self.query = query
        self.headers = headers
        self.bodyContains = bodyContains
    }

    /// Matches every request for its endpoint.
    public static let any = MockMatch()

    public var isCatchAll: Bool {
        query.isEmpty && headers.isEmpty && (bodyContains?.isEmpty ?? true)
    }

    /// How many conditions this imposes.
    ///
    /// Used to order candidates so the narrowest rule wins. Without it the
    /// served answer would depend on insertion order, and "why is the catch-all
    /// beating my page=2 rule?" is not a question a debugging tool should pose.
    public var specificity: Int {
        query.count + headers.count + ((bodyContains?.isEmpty ?? true) ? 0 : 1)
    }

    // MARK: - Matching

    public func matches(_ request: URLRequest) -> Bool {
        guard matchesQuery(request), matchesHeaders(request) else { return false }
        guard let needle = bodyContains, !needle.isEmpty else { return true }
        guard let body = request.httpBody else { return false }
        return String(decoding: body, as: UTF8.self).contains(needle)
    }

    private func matchesQuery(_ request: URLRequest) -> Bool {
        guard !query.isEmpty else { return true }
        guard
            let url = request.url,
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return false }

        return query.allSatisfy { name, expected in
            guard let item = items.first(where: { $0.name == name }) else { return false }
            return expected == Self.anyValue || item.value == expected
        }
    }

    private func matchesHeaders(_ request: URLRequest) -> Bool {
        guard !headers.isEmpty else { return true }
        let actual = request.allHTTPHeaderFields ?? [:]
        return headers.allSatisfy { name, expected in
            guard
                let value = actual.first(where: { $0.key.lowercased() == name.lowercased() })?.value
            else { return false }
            return expected == Self.anyValue || value == expected
        }
    }

    // MARK: - Capture

    /// The conditions that pin a rule to this exact request's query.
    ///
    /// The one-tap path from a captured exchange: mocking page 2 differently
    /// means naming the query it came in on, and nobody wants to retype it.
    public static func matchingQuery(of request: RequestSnapshot) -> MockMatch {
        guard
            let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems,
            !items.isEmpty
        else { return .any }

        var query: [String: String] = [:]
        for item in items { query[item.name] = item.value ?? Self.anyValue }
        return MockMatch(query: query)
    }

    /// Short human summary for a rule row: `page=2, sort=desc`.
    public var summary: String? {
        guard !isCatchAll else { return nil }
        var parts = query.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        parts += headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
        if let bodyContains, !bodyContains.isEmpty { parts.append("body ~ \(bodyContains)") }
        return parts.joined(separator: ", ")
    }
}
