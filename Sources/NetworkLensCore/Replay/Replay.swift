//
//  Replay.swift
//  NetworkLensCore
//
//  Created by Rohit Sahay on 30/07/26.
//

import Foundation

extension NetworkLens {

    /// Why a request could not be sent again.
    public enum ReplayError: Error, Equatable, Sendable {
        /// The unredacted request is gone — captured in an earlier launch, or
        /// pushed out of the bounded `ReplayStore` by newer traffic.
        case originalRequestUnavailable
    }

    /// Sends a captured request again, through the whole pipeline.
    ///
    /// Iterating on a state used to mean navigating away and back for every
    /// attempt: switch the variant, leave the screen, return, look. On a screen
    /// firing four calls that is most of the time spent debugging it.
    ///
    /// The replay goes through interception like any other request, so armed
    /// mocks, variants, perturbations and breakpoints all apply — which is the
    /// point. Replaying past the tool would only prove the server still works.
    ///
    /// It is sent from the tool, not the app: the app never sees the response,
    /// so this answers "what would the server say now" and "which variant is
    /// armed", not "what does the screen do with it". Re-render still needs the
    /// app to ask.
    @discardableResult
    public static func replay(_ exchange: NetworkExchange) async throws -> NetworkExchange? {
        guard let original = ReplayStore.shared.request(for: exchange.id) else {
            throw ReplayError.originalRequestUnavailable
        }

        let request = original
            .stamped(screen: exchange.screen, exchangeID: UUID())
            .stampedAsReplay(of: exchange.id)

        _ = try? await replaySession.data(for: request)

        // The interception layer records under the id stamped above, so the
        // replayed exchange is found rather than constructed here.
        return store.exchanges.last { $0.replayOf == exchange.id }
    }

    /// Whether `replay(_:)` would have something to send.
    public static func canReplay(_ exchange: NetworkExchange) -> Bool {
        ReplayStore.shared.canReplay(exchange.id)
    }

    /// Its own session, ephemeral and protocol-installed.
    ///
    /// Not `URLSession.shared`: a replay must not inherit the app's cookie jar
    /// or cache, or a "fresh" request could be answered from a cache entry the
    /// app populated and prove nothing.
    private static let replaySession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Explicitly not adopted as the passthrough template: this
        // configuration is the tool's own, and letting it stand in for the
        // app's would hand every intercepted request an empty cookie jar the
        // moment anyone replays anything.
        install(into: configuration, adoptingForPassthrough: false)
        return URLSession(configuration: configuration)
    }()
}
