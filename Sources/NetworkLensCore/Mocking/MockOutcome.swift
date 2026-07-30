import Foundation

/// A transport failure served in place of a network round trip.
///
/// The half of mocking a canned response cannot reach. "Offline", "DNS is
/// down", "the connection dropped mid-body" are not status codes — they are
/// `URLError`s, and an app's retry, cache-fallback and offline-banner paths key
/// off exactly those. Without this, none of that code is reachable from a mock.
public struct MockFailure: Codable, Sendable, Hashable {

    /// `URLError.Code.rawValue`. Stored as `Int` because `URLError.Code` is not
    /// `Codable`, and a rule has to survive a relaunch.
    public var errorCode: Int

    /// Short label for the rule list: "offline", "connection lost".
    public var label: String

    /// Time to burn before failing, so a slow failure is distinguishable from
    /// an instant one. Bounded by the request's timeout the same way a
    /// response delay is.
    public var delay: TimeInterval

    public init(code: URLError.Code, label: String, delay: TimeInterval = 0) {
        self.errorCode = code.rawValue
        self.label = label
        self.delay = delay
    }

    public init(errorCode: Int, label: String, delay: TimeInterval = 0) {
        self.errorCode = errorCode
        self.label = label
        self.delay = delay
    }

    /// The error handed to the app. Indistinguishable from the real thing —
    /// `URLError` carries no provenance, which is the point.
    public var urlError: URLError { URLError(URLError.Code(rawValue: errorCode)) }

    // MARK: - Presets

    /// Airplane mode. The one every offline-banner bug hides behind.
    public static func offline(delay: TimeInterval = 0) -> MockFailure {
        MockFailure(code: .notConnectedToInternet, label: "offline", delay: delay)
    }

    public static func timedOut(delay: TimeInterval = 0) -> MockFailure {
        MockFailure(code: .timedOut, label: "timed out", delay: delay)
    }

    /// Drops after the request went out — the case that exposes non-idempotent
    /// retries, because the server may well have processed it.
    public static func connectionLost(delay: TimeInterval = 0) -> MockFailure {
        MockFailure(code: .networkConnectionLost, label: "connection lost", delay: delay)
    }

    public static func cannotFindHost(delay: TimeInterval = 0) -> MockFailure {
        MockFailure(code: .cannotFindHost, label: "DNS failure", delay: delay)
    }

    public static func secureConnectionFailed(delay: TimeInterval = 0) -> MockFailure {
        MockFailure(code: .secureConnectionFailed, label: "TLS failure", delay: delay)
    }

    /// Every preset, for a picker.
    public static var presets: [MockFailure] {
        [offline(), timedOut(), connectionLost(), cannotFindHost(), secureConnectionFailed()]
    }
}

/// What one mocked hit produces.
public enum MockOutcome: Codable, Sendable, Hashable {

    case respond(MockResponse)
    case fail(MockFailure)

    /// The response, or `nil` for a failure outcome.
    public var response: MockResponse? {
        if case .respond(let response) = self { return response }
        return nil
    }

    public var failure: MockFailure? {
        if case .fail(let failure) = self { return failure }
        return nil
    }

    /// Latency this outcome imposes, whichever kind it is.
    public var delay: TimeInterval {
        switch self {
        case .respond(let response): return response.delay
        case .fail(let failure): return failure.delay
        }
    }

    /// One-line summary for a rule list.
    public var label: String {
        switch self {
        case .respond(let response): return "\(response.statusCode)"
        case .fail(let failure): return failure.label
        }
    }
}

/// What a scripted rule does once its steps run out.
public enum MockExhaustion: String, Codable, Sendable, CaseIterable {

    /// Serve the last step forever. The default: a script written as
    /// "fail, fail, succeed" almost always means "and stay succeeded".
    case repeatLast

    /// Start the script over. For a poller that should keep cycling.
    case loop

    /// Stop claiming and let the request go to the network.
    ///
    /// The one that makes retry testing honest: fail twice from the device,
    /// then let the third attempt hit the real server and prove the app
    /// recovers against real data rather than against another mock.
    case passThrough

    public var label: String {
        switch self {
        case .repeatLast: return "repeat last"
        case .loop: return "loop"
        case .passThrough: return "go live"
        }
    }
}
