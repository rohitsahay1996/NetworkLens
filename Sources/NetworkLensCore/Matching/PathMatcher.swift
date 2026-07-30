//
//  PathMatcher.swift
//  NetworkLensCore
//
//  Created by Rohit Sahay on 29/07/26.
//

import Foundation

/// Default REST matcher. Collapses volatile path segments into `{id}` so
/// `GET /users/123/orders/456` and `GET /users/789/orders/1` share one key.
///
/// Query strings are dropped from the key — they are request parameters, not
/// endpoint identity. Trailing slashes are normalised away.
public struct PathMatcher: RequestMatcher {

    public let identifier: String

    /// Placeholder written in place of a volatile segment.
    public let placeholder: String

    /// Hosts this matcher answers for. Empty means every host.
    public let hosts: Set<String>

    public init(
        identifier: String = "path",
        placeholder: String = "{id}",
        hosts: Set<String> = []
    ) {
        self.identifier = identifier
        self.placeholder = placeholder
        self.hosts = hosts
    }

    public func endpointKey(for request: URLRequest) -> String? {
        guard let url = request.url else { return nil }
        if !hosts.isEmpty, let host = url.host, !hosts.contains(host) { return nil }

        let method = request.httpMethod?.uppercased() ?? "GET"
        return "\(method) \(Self.template(forPath: url.path, placeholder: placeholder))"
    }

    /// Templates a path in isolation. Exposed for testing and for reuse by
    /// other matchers that want the same segment rules.
    public static func template(forPath path: String, placeholder: String = "{id}") -> String {
        let segments = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !segments.isEmpty else { return "/" }

        let templated = segments.map { segment -> String in
            isVolatile(String(segment)) ? placeholder : String(segment)
        }
        return "/" + templated.joined(separator: "/")
    }

    /// A segment is volatile when it identifies an instance rather than a
    /// collection: all-numeric, a UUID, or a long hex/opaque token.
    private static func isVolatile(_ segment: String) -> Bool {
        if segment.isEmpty { return false }
        if segment.allSatisfy(\.isNumber) { return true }
        if UUID(uuidString: segment) != nil { return true }
        if isLongHex(segment) { return true }
        return false
    }

    /// Mongo ObjectIDs (24 hex) and similar opaque ids. The length floor keeps
    /// real path words like `feed` and `cafe` from being swallowed.
    private static func isLongHex(_ segment: String) -> Bool {
        guard segment.count >= 16 else { return false }
        return segment.allSatisfy { $0.isHexDigit }
    }
}
