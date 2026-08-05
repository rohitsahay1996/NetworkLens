//
//  MockRequestRewrite.swift
//  NetworkLensCore
//
//  Created by Rohit Sahay on 31/07/26.
//

import Foundation

/// Changes applied to a request on its way *out*.
///
/// The other half of mocking. A canned response answers "what if the server
/// said this"; a rewrite answers "what if we sent this" — the question behind
/// every malformed-payload bug, every field the backend rejects, and every
/// "works on my account" report.
///
/// Unlike a response mock, this one reaches a real server. A rewritten request
/// is a real request: it can create real records, spend real money and be
/// audited by whoever runs the backend. Which is why `LensURLProtocol` refuses
/// to apply one to a host listed in `productionHostPatterns`, and why the
/// exchange records exactly what was changed.
public struct MockRequestRewrite: Codable, Sendable, Hashable {

    /// Replaces the request body entirely. `nil` leaves it alone.
    public var body: Data?

    /// Set on the outgoing request, replacing any existing value.
    public var headers: [String: String]

    /// Removed from the outgoing request. Runs after `headers`, so a name in
    /// both ends up removed.
    public var removedHeaders: [String]

    /// Replaces the HTTP method. `nil` leaves it alone.
    public var method: String?

    public init(
        body: Data? = nil,
        headers: [String: String] = [:],
        removedHeaders: [String] = [],
        method: String? = nil
    ) {
        self.body = body
        self.headers = headers
        self.removedHeaders = removedHeaders
        self.method = method
    }

    /// True when this would not change anything.
    public var isEmpty: Bool {
        body == nil && headers.isEmpty && removedHeaders.isEmpty && method == nil
    }

    /// Applies the changes, recomputing `Content-Length` so a rewritten body
    /// cannot be truncated by a stale header.
    public func applied(to request: URLRequest) -> URLRequest {
        var rewritten = request

        if let method { rewritten.httpMethod = method }
        for (name, value) in headers { rewritten.setValue(value, forHTTPHeaderField: name) }
        for name in removedHeaders { rewritten.setValue(nil, forHTTPHeaderField: name) }

        if let body {
            rewritten.httpBody = body
            rewritten.setValue("\(body.count)", forHTTPHeaderField: "Content-Length")
        }

        return rewritten
    }

    /// Short summary for a row: `body, 2 headers`.
    public var summary: String? {
        guard !isEmpty else { return nil }
        var parts: [String] = []
        if body != nil { parts.append("body") }
        if let method { parts.append(method) }
        let headerCount = headers.count + removedHeaders.count
        if headerCount > 0 {
            parts.append("\(headerCount) header\(headerCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: ", ")
    }
}
