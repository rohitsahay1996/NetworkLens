//
//  MockResponse.swift
//  NetworkLensCore
//
//  Created by Rohit Sahay on 30/07/26.
//

import Foundation

/// The canned answer a `MockRule` serves in place of a network round trip.
///
/// Stored as status + headers + body rather than as an `HTTPURLResponse`, so a
/// rule is `Codable` and survives a relaunch or a fixture file. The live
/// `HTTPURLResponse` is rebuilt at delivery time from the request's own URL,
/// which is what keeps a saved rule usable against staging and localhost alike.
public struct MockResponse: Codable, Sendable, Hashable {

    public var statusCode: Int

    /// Sent as-is, except for `Content-Length`, which is always recomputed from
    /// `body` at delivery time. A hand-written one is ignored: a wrong value
    /// makes the app's decoder truncate or hang.
    public var headers: [String: String]

    public var body: Data

    /// Latency to simulate before the response is handed to the app.
    ///
    /// Not cosmetic — a mock that answers in zero time hides every spinner,
    /// race and cancellation bug the real endpoint would expose. A delay at or
    /// beyond the request's `timeoutInterval` produces `URLError.timedOut`,
    /// same as the real stack would.
    public var delay: TimeInterval

    public init(
        statusCode: Int = 200,
        headers: [String: String] = [:],
        body: Data = Data(),
        delay: TimeInterval = 0
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.delay = delay
    }

    // MARK: - Builders

    /// JSON from a raw string. The string is not validated — an intentionally
    /// malformed body is a legitimate thing to mock.
    public static func json(
        _ string: String,
        statusCode: Int = 200,
        headers: [String: String] = [:],
        delay: TimeInterval = 0
    ) -> MockResponse {
        MockResponse(
            statusCode: statusCode,
            headers: headers.settingIfAbsent("Content-Type", "application/json"),
            body: Data(string.utf8),
            delay: delay
        )
    }

    /// JSON from an ordered tree, so a body captured from a real response and
    /// then patched keeps its key order and number literals.
    public static func json(
        _ node: JSONNode,
        statusCode: Int = 200,
        headers: [String: String] = [:],
        delay: TimeInterval = 0
    ) -> MockResponse {
        MockResponse(
            statusCode: statusCode,
            headers: headers.settingIfAbsent("Content-Type", "application/json"),
            body: JSONNodeSerializer.data(from: node),
            delay: delay
        )
    }

    /// Status code with an empty body, for 204s and for error codes whose body
    /// the app ignores.
    public static func status(
        _ statusCode: Int,
        headers: [String: String] = [:],
        delay: TimeInterval = 0
    ) -> MockResponse {
        MockResponse(statusCode: statusCode, headers: headers, body: Data(), delay: delay)
    }

    // MARK: - Delivery

    /// Builds the payload handed to the app.
    ///
    /// `elapsed` is the measured wall clock the mock actually took, so a
    /// delayed mock reports the latency it imposed rather than zero.
    public func payload(for url: URL, elapsed: TimeInterval? = nil) -> ResponsePayload {
        var fields = headers.removingHeader("Content-Length")
        fields["Content-Length"] = "\(body.count)"

        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: fields
        ) ?? HTTPURLResponse(
            url: URL(string: "about:blank")!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: fields
        )!

        let total = elapsed ?? delay
        return ResponsePayload(
            response: response,
            body: body,
            // No transaction happened, so every phase but the total is nil
            // rather than fabricated. `fromCache` stays false — this came from
            // the lens, and `Source.mocked` is what says so.
            timing: Timing(total: total, serverThink: total > 0 ? total : nil),
            bodyTruncated: false
        )
    }
}

// MARK: - Header helpers

extension Dictionary where Key == String, Value == String {

    /// Case-insensitive membership check before inserting, because HTTP header
    /// names are case-insensitive and `HTTPURLResponse` would otherwise carry
    /// both `Content-Type` and `content-type`.
    func settingIfAbsent(_ name: String, _ value: String) -> [String: String] {
        let lowered = name.lowercased()
        guard !keys.contains(where: { $0.lowercased() == lowered }) else { return self }
        var copy = self
        copy[name] = value
        return copy
    }

    func removingHeader(_ name: String) -> [String: String] {
        let lowered = name.lowercased()
        return filter { $0.key.lowercased() != lowered }
    }
}
