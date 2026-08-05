//
//  ResponsePayload.swift
//  NetworkLensCore
//
//  Created by Rohit Sahay on 29/07/26.
//

import Foundation

/// A response and its body, carried together so a breakpoint can edit both
/// before either reaches the app.
public struct ResponsePayload: @unchecked Sendable {

    public var response: HTTPURLResponse
    public var body: Data
    public var timing: Timing?
    /// True when the captured body is a prefix of what actually arrived.
    public var bodyTruncated: Bool

    public init(
        response: HTTPURLResponse,
        body: Data,
        timing: Timing? = nil,
        bodyTruncated: Bool = false
    ) {
        self.response = response
        self.body = body
        self.timing = timing
        self.bodyTruncated = bodyTruncated
    }

    /// Capture of this response, retaining at most `cap` bytes of body.
    ///
    /// Truncation belongs here and not at the network leg: the app must still
    /// receive every byte it asked for, and the cap is about what the ring
    /// buffer holds on to. Without it, `maxCapturedResponseBodyBytes` sets a
    /// flag and nothing else, and 500 retained exchanges of a multi-megabyte
    /// download is a debugging tool running the app out of memory.
    public func snapshot(cap: Int) -> ResponseSnapshot {
        let limit = max(0, cap)
        guard body.count > limit else {
            return ResponseSnapshot(response: response, body: body, bodyTruncated: bodyTruncated)
        }
        return ResponseSnapshot(
            response: response,
            body: Data(body.prefix(limit)),
            bodyTruncated: true,
            originalBodyByteCount: body.count
        )
    }

    /// Replaces the body and recomputes `Content-Length`.
    ///
    /// A stale `Content-Length` after an edit makes `URLSession` truncate or
    /// hang, so this is the only supported way to change the body.
    public func replacingBody(_ newBody: Data) -> ResponsePayload {
        var headers = response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            guard let key = entry.key as? String else { return }
            result[key] = String(describing: entry.value)
        }
        headers["Content-Length"] = "\(newBody.count)"
        // Body was decoded before we saw it; re-sending it encoded would lie.
        headers.removeValue(forKey: "Content-Encoding")

        let rebuilt = HTTPURLResponse(
            url: response.url ?? URL(string: "about:blank")!,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) ?? response

        return ResponsePayload(
            response: rebuilt,
            body: newBody,
            timing: timing,
            bodyTruncated: false
        )
    }

    /// Replaces the status code, keeping headers and body.
    public func replacingStatusCode(_ code: Int) -> ResponsePayload {
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            guard let key = entry.key as? String else { return }
            result[key] = String(describing: entry.value)
        }
        let rebuilt = HTTPURLResponse(
            url: response.url ?? URL(string: "about:blank")!,
            statusCode: code,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) ?? response

        return ResponsePayload(
            response: rebuilt,
            body: body,
            timing: timing,
            bodyTruncated: bodyTruncated
        )
    }
}
