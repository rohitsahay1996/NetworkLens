import Foundation

/// An immutable capture of an outgoing request, taken before it hits the wire.
///
/// `body` is whatever we could read at capture time. For stream-based bodies
/// (`httpBodyStream`, multipart uploads) we read a bounded prefix and set
/// `bodyTruncated`, so the UI can say "truncated" instead of "empty".
public struct RequestSnapshot: Codable, Sendable, Hashable {

    public var method: String
    public var url: URL

    /// Header field names are canonicalised to their original casing as sent.
    /// Lookups should go through `header(_:)`, which is case-insensitive.
    public var headers: [String: String]

    /// Body bytes as captured. `nil` means there was no body at all.
    /// An empty `Data` means there was a body but we captured none of it.
    public var body: Data?

    /// True when `body` holds only a prefix of the real payload.
    public var bodyTruncated: Bool

    /// Full size of the original body when known. For streamed bodies this is
    /// only known if the stream ran to completion within the capture cap.
    public var originalBodyByteCount: Int?

    public init(
        method: String,
        url: URL,
        headers: [String: String] = [:],
        body: Data? = nil,
        bodyTruncated: Bool = false,
        originalBodyByteCount: Int? = nil
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.bodyTruncated = bodyTruncated
        self.originalBodyByteCount = originalBodyByteCount
    }

    public func header(_ name: String) -> String? {
        if let exact = headers[name] { return exact }
        let lowered = name.lowercased()
        return headers.first { $0.key.lowercased() == lowered }?.value
    }
}

extension RequestSnapshot {

    /// Convenience capture from a `URLRequest`. Does **not** read
    /// `httpBodyStream` — the interception layer owns bounded stream draining
    /// and passes the result in explicitly.
    public init(request: URLRequest) {
        self.init(
            method: request.httpMethod ?? "GET",
            url: request.url ?? URL(string: "about:blank")!,
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody,
            bodyTruncated: false,
            originalBodyByteCount: request.httpBody?.count
        )
    }
}
