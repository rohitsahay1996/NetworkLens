import Foundation

/// Turns a concrete request into a stable logical endpoint identity.
///
/// Every grouping, stat and (from milestone 2) mock rule keys off this, and it
/// is a protocol from day one because path comparison is a REST-only
/// assumption. A GraphQL app sends everything to `POST /graphql` and identifies
/// operations by a body field; a gRPC-over-HTTP app keys off a header.
public protocol RequestMatcher: Sendable {

    /// Stable identity of the matcher itself, for diagnostics and for
    /// milestone 2's rule storage.
    var identifier: String { get }

    /// Stable grouping key — the same logical endpoint across different path
    /// params. `GET /users/123` and `GET /users/456` both return
    /// `"GET /users/{id}"`.
    ///
    /// Return `nil` to decline the request and let the next matcher try.
    func endpointKey(for request: URLRequest) -> String?
}

/// Resolves an endpoint key by trying matchers in order, first non-nil wins.
public struct MatcherChain: Sendable {

    public let matchers: [RequestMatcher]

    public init(_ matchers: [RequestMatcher]) {
        self.matchers = matchers
    }

    /// Never returns `nil` — falls back to method + path so an unmatched
    /// request still groups sensibly instead of vanishing from the list.
    public func endpointKey(for request: URLRequest) -> String {
        for matcher in matchers {
            if let key = matcher.endpointKey(for: request) { return key }
        }
        let method = request.httpMethod?.uppercased() ?? "GET"
        let path = request.url?.path ?? ""
        return "\(method) \(path.isEmpty ? "/" : path)"
    }
}
