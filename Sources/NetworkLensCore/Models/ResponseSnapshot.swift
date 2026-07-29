import Foundation

/// An immutable capture of a response. Same truncation contract as
/// `RequestSnapshot` — a large download is captured up to a cap, not in full.
public struct ResponseSnapshot: Codable, Sendable, Hashable {

    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data?
    public var bodyTruncated: Bool
    public var originalBodyByteCount: Int?
    public var mimeType: String?

    public init(
        statusCode: Int,
        headers: [String: String] = [:],
        body: Data? = nil,
        bodyTruncated: Bool = false,
        originalBodyByteCount: Int? = nil,
        mimeType: String? = nil
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.bodyTruncated = bodyTruncated
        self.originalBodyByteCount = originalBodyByteCount
        self.mimeType = mimeType
    }

    public func header(_ name: String) -> String? {
        if let exact = headers[name] { return exact }
        let lowered = name.lowercased()
        return headers.first { $0.key.lowercased() == lowered }?.value
    }

    public var isSuccess: Bool { (200..<300).contains(statusCode) }
}

extension ResponseSnapshot {

    public init(response: HTTPURLResponse, body: Data?, bodyTruncated: Bool = false) {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String else { continue }
            headers[key] = String(describing: value)
        }
        self.init(
            statusCode: response.statusCode,
            headers: headers,
            body: body,
            bodyTruncated: bodyTruncated,
            originalBodyByteCount: body?.count,
            mimeType: response.mimeType
        )
    }
}
