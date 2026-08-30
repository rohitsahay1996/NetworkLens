//
//  CapturedVariants.swift
//  NetworkLensCore
//
//  Created by Rohit Sahay on 28/08/26.
//

import Foundation

/// Builds a screen's worth of mock rules from the traffic it just made.
///
/// Authoring is the bottleneck, not switching. Building the flash sale pack by
/// hand was roughly thirty interactions before the first scenario existed —
/// open an exchange, save a mock, name a variant, repeat — which is why one
/// screen has a pack and the other forty do not. Everything needed is already
/// in the capture: the real response is the `loaded` variant, and the three
/// states anyone actually tests are derivable from its shape.
///
/// Derived from the captured body rather than templated, deliberately. An empty
/// state that does not match the app's envelope decodes to nil and exercises the
/// error path instead of the empty path — which looks like the empty state
/// working, and is the worst kind of wrong.
public enum CapturedVariants {

    /// `loaded`, `empty`, `500`, `slow`, `timeout`.
    ///
    /// Five is a judgement: enough to cover what a reviewer asks for, few
    /// enough that the variant picker stays readable. Anything more specific is
    /// per-feature and belongs in a hand-made variant.
    public static func standardSet(
        from response: ResponseSnapshot?,
        slowDelay: TimeInterval = 3
    ) -> [MockVariant] {
        let status = response?.statusCode ?? 200
        let headers = response?.headers ?? ["Content-Type": "application/json"]
        let body = response?.body ?? Data()

        let loaded = MockResponse(statusCode: status, headers: headers, body: body)

        return [
            MockVariant(name: "loaded", steps: [.respond(loaded)]),
            MockVariant(
                name: "empty",
                steps: [.respond(MockResponse(statusCode: 200, headers: headers, body: emptied(body)))]
            ),
            MockVariant(
                name: "500",
                steps: [.respond(MockResponse(statusCode: 500, headers: headers, body: failed(body)))]
            ),
            MockVariant(
                name: "slow",
                steps: [.respond(MockResponse(statusCode: status, headers: headers, body: body, delay: slowDelay))]
            ),
            MockVariant(name: "timeout", steps: [.fail(.timedOut())]),
        ]
    }

    /// A rule for one captured exchange, carrying the standard set.
    public static func rule(for exchange: NetworkExchange, slowDelay: TimeInterval = 3) -> MockRule {
        MockRule(
            endpointKey: exchange.endpointKey,
            variants: standardSet(from: exchange.response, slowDelay: slowDelay),
            isEnabled: false
        )
    }

    // MARK: - Deriving

    /// The same response with its content removed and its envelope intact.
    ///
    /// A bare `{}` would be a different response, not an empty one: an app that
    /// reads `data.items` off it fails to decode and shows an error, so the
    /// empty state never renders and the variant tests nothing. Containers are
    /// emptied in place instead — arrays to `[]`, objects to `{}` — and scalars
    /// left alone, so `code` and `status` survive and the payload does not.
    public static func emptied(_ body: Data) -> Data {
        guard
            let json = try? JSONSerialization.jsonObject(with: body),
            let hollowed = hollow(json),
            let data = try? JSONSerialization.data(withJSONObject: hollowed, options: [.fragmentsAllowed, .sortedKeys])
        else {
            return Data("{}".utf8)
        }
        return data
    }

    /// The same response turned into a failure, in the shape the app already
    /// speaks.
    ///
    /// A generic `{"error":…}` body is not what the app's error path parses, so
    /// a mocked 500 that returns one exercises the decoder rather than the
    /// error handling. Where the capture has an envelope, its own fields are
    /// rewritten; where it has none, there is nothing to preserve and a plain
    /// body is honest.
    public static func failed(_ body: Data, statusCode: Int = 500) -> Data {
        guard
            let json = try? JSONSerialization.jsonObject(with: body),
            var object = json as? [String: Any]
        else {
            return Data(#"{"error":"internal server error"}"#.utf8)
        }

        for key in object.keys {
            switch key.lowercased() {
                case "code": object[key] = statusCode
                case "status": object[key] = "INTERNAL_SERVER_ERROR"
                case "data", "value", "result", "payload": object[key] = NSNull()
                default: break
            }
        }
        if object["errorCode"] == nil, object["code"] != nil {
            object["errorCode"] = "SYSTEM_ERROR"
        }

        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data ?? Data(#"{"error":"internal server error"}"#.utf8)
    }

    /// Empties every container, keeps every scalar.
    private static func hollow(_ value: Any) -> Any? {
        if value is [Any] { return [] }
        guard let object = value as? [String: Any] else { return value }
        var result: [String: Any] = [:]
        for (key, nested) in object {
            result[key] = hollow(nested)
        }
        return result
    }
}
