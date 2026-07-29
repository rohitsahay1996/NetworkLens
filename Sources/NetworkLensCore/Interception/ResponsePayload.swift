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

    public var snapshot: ResponseSnapshot {
        ResponseSnapshot(response: response, body: body, bodyTruncated: bodyTruncated)
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
