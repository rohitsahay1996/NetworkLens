//
//  PassthroughSession.swift
//  NetworkLensCore
//
//  Created by Rohit Sahay on 01/08/26.
//

import Foundation

/// The session used for the real network leg.
///
/// This session, not the app's, is what actually talks to the server once a
/// request has been intercepted — so anything the app configured and this
/// session does not have is silently dropped from every request the lens sees.
/// A bare ephemeral session gets that wrong in the worst way: its cookie jar is
/// empty, so a cookie-authenticated app starts receiving 401s *only while the
/// lens is attached*, and the tool becomes the bug.
///
/// So the configuration is a copy of the app's whenever the app has told us
/// which one it uses — `NetworkLens.install(into:)` — and a copy of
/// `URLSessionConfiguration.default` otherwise, which is the right answer for
/// `URLSession.shared` and for any session built from `.default`: both share
/// `HTTPCookieStorage.shared` and `URLCredentialStorage.shared`.
///
/// Two things are deliberately *not* copied, and both change app behaviour
/// while the lens is attached:
///
/// - caching is off, because a response served from a cache is one the lens
///   never sees and cannot mock or edit;
/// - `LensURLProtocol` is filtered out of `protocolClasses`. The handled tag
///   alone would be enough, but excluding the class as well means a bug in the
///   tagging degrades to "not captured" rather than to an infinite loop.
final class PassthroughSession: @unchecked Sendable {

    static let shared = PassthroughSession()

    private let lock = NSLock()
    /// Snapshot of the app's configuration, or nil until it tells us one.
    private var template: URLSessionConfiguration?
    private var cached: URLSession?

    var session: URLSession {
        lock.lock()
        if let cached {
            lock.unlock()
            return cached
        }
        let template = self.template
        lock.unlock()

        // Built outside the lock: `URLSessionConfiguration.default` is swizzled
        // and reaches back into `NetworkLens`, and holding a lock across that
        // is how a deadlock gets written by accident.
        let built = URLSession(configuration: Self.configuration(from: template))

        lock.lock()
        defer { lock.unlock() }
        // Another thread may have won the race. Keep theirs; ours is discarded
        // unused rather than invalidated, since it owns nothing yet.
        if let cached { return cached }
        cached = built
        return built
    }

    /// Adopts the app's own configuration for the real leg.
    ///
    /// Copied rather than retained: the app is free to keep mutating its
    /// configuration afterwards, and a session that changed underneath the
    /// requests it was already carrying would be worse than one that is stale.
    func adopt(_ configuration: URLSessionConfiguration) {
        guard let copy = configuration.copy() as? URLSessionConfiguration else { return }
        lock.lock()
        let previous = cached
        template = copy
        cached = nil
        lock.unlock()
        // Lets in-flight passthrough legs finish on the old session rather than
        // failing requests that have nothing to do with the change.
        previous?.finishTasksAndInvalidate()
    }

    /// Drops the adopted configuration. Tests only — an app has exactly one.
    func reset() {
        lock.lock()
        let previous = cached
        template = nil
        cached = nil
        lock.unlock()
        previous?.finishTasksAndInvalidate()
    }

    static func configuration(from template: URLSessionConfiguration?) -> URLSessionConfiguration {
        let base = template ?? URLSessionConfiguration.default
        let configuration = (base.copy() as? URLSessionConfiguration)
            ?? URLSessionConfiguration.default

        configuration.protocolClasses = (configuration.protocolClasses ?? [])
            .filter { $0 != LensURLProtocol.self }
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }
}

/// Watches one passthrough task: its metrics, and any redirect it is offered.
final class PassthroughObserver: NSObject, URLSessionTaskDelegate, @unchecked Sendable {

    /// A redirect the server asked for, and the request that would follow it.
    struct Redirect {
        let response: HTTPURLResponse
        let request: URLRequest
    }

    private let lock = NSLock()
    private var collected: Timing?
    private var redirect: Redirect?

    var timing: Timing? {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }

    /// Set when the leg stopped at a 3xx instead of following it.
    var offeredRedirect: Redirect? {
        lock.lock()
        defer { lock.unlock() }
        return redirect
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        lock.lock()
        collected = Timing(metrics: metrics)
        lock.unlock()
    }

    /// Declines to follow, and hands the hop back to `LensURLProtocol`.
    ///
    /// Following it here is invisible in both directions: the app's own
    /// `willPerformHTTPRedirection` never runs, so an app that rewrites or
    /// refuses redirects silently stops doing so while the lens is attached,
    /// and the capture shows only the last hop — a login that 302s through two
    /// hosts looks like one request to a URL nobody asked for.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        redirect = Redirect(response: response, request: request)
        lock.unlock()
        completionHandler(nil)
    }
}
