//
//  ResponseSnapshot.swift
//  NetworkLensCore
//
//  Created by Rohit Sahay on 29/07/26.
//

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

    /// - Parameter originalBodyByteCount: size before truncation. Defaults to
    ///   the size of `body`, which is only correct when nothing was cut — a
    ///   truncated capture that reports its own length says a 12 MB download was
    ///   1 MB, and the one number that could have explained the truncation is
    ///   gone.
    public init(
        response: HTTPURLResponse,
        body: Data?,
        bodyTruncated: Bool = false,
        originalBodyByteCount: Int? = nil
    ) {
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
            originalBodyByteCount: originalBodyByteCount ?? body?.count,
            mimeType: response.mimeType
        )
    }
}
