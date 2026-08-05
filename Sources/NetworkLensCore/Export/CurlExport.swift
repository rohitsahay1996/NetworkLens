//
//  CurlExport.swift
//  NetworkLensCore
//
//  Created by Rohit Sahay on 30/07/26.
//

import Foundation

/// Renders a captured request as a `curl` command.
///
/// The first thing a repro has to do is leave the device. A tester who can
/// reproduce something still cannot hand it to anyone, and "it 500s on my
/// phone" costs a developer the whole reproduction again — so the cheapest
/// useful export is the one a backend engineer can paste into a terminal
/// unchanged.
///
/// Redacted by default, deliberately. Export is the one operation that moves
/// captured traffic off the device and into a ticket, a chat, or a paste bin,
/// which is exactly where a bearer token must not end up. The unredacted form
/// exists for pasting into your own shell and has to be asked for by name.
public enum CurlExport {

    /// Which version of the request to render.
    public enum Secrets: Sendable {
        /// Redacted headers and body, as stored. Safe to paste into a ticket.
        case redacted
        /// The request exactly as it left the device, when it is still in
        /// `ReplayStore` — the same session that captured it.
        ///
        /// For your own terminal. It will contain whatever the app sent,
        /// including credentials.
        case included
    }

    /// Builds the command.
    ///
    /// Long-form flags (`--request`, `--header`) over short ones: the reader is
    /// usually not the author, often not an iOS engineer, and `-H` is one more
    /// thing to look up in a ticket comment.
    public static func command(
        for exchange: NetworkExchange,
        secrets: Secrets = .redacted
    ) -> String {
        let source = unredactedRequest(for: exchange, secrets: secrets)

        let method = source?.httpMethod ?? exchange.request.method
        let url = (source?.url ?? exchange.request.url).absoluteString
        let headers = source?.allHTTPHeaderFields ?? exchange.request.headers
        let body = source?.httpBody ?? exchange.request.body

        var lines = ["curl"]

        // GET is curl's default, so spelling it out is noise.
        if method.uppercased() != "GET" {
            lines.append("--request \(method.uppercased())")
        }

        // Sorted so the same request always produces the same command —
        // a diff between two exports should show what changed, not
        // dictionary ordering.
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            lines.append("--header \(quoted("\(name): \(value)"))")
        }

        if let body, !body.isEmpty {
            if let text = String(data: body, encoding: .utf8) {
                lines.append("--data \(quoted(text))")
            } else {
                // Binary bodies cannot be pasted as text. Saying so beats
                // emitting mojibake that fails for a reason nobody can see.
                lines.append(
                    "--data-binary @request.bin  # \(body.count) bytes, not UTF-8"
                )
            }
        }

        if exchange.request.bodyTruncated {
            lines.append("# body truncated by the capture cap — this is not the whole request")
        }

        lines.append(quoted(url))
        return lines.joined(separator: " \\\n  ")
    }

    /// Commands for several exchanges, oldest first, so a screen's traffic can
    /// be handed over as one block.
    public static func command(
        for exchanges: [NetworkExchange],
        secrets: Secrets = .redacted
    ) -> String {
        exchanges
            .map { command(for: $0, secrets: secrets) }
            .joined(separator: "\n\n")
    }

    // MARK: - Helpers

    private static func unredactedRequest(
        for exchange: NetworkExchange, secrets: Secrets
    ) -> URLRequest? {
        guard case .included = secrets else { return nil }
        return ReplayStore.shared.request(for: exchange.id)
    }

    /// Single-quoted for the shell, with embedded quotes closed and reopened —
    /// the only escaping POSIX `sh` offers inside single quotes.
    private static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
