//
//  LensConfiguration.swift
//  NetworkLensCore
//
//  Created by Rohit Sahay on 29/07/26.
//

import Foundation

/// Everything the lens needs, supplied once at `start`.
public struct LensConfiguration: Sendable {

    /// Tried in order; the first matcher to return a key wins. Falls back to
    /// method + raw path when none claim the request.
    public var matchers: [RequestMatcher]

    /// Applied before the exchange reaches the store. Never after.
    public var redactor: Redactor

    /// Ring buffer size.
    public var maxStoredExchanges: Int

    /// Swizzle `UIViewController` appearance to maintain the screen stack.
    /// Turn off to drive attribution purely from `.lensScreen(_:)`.
    public var automaticScreenAttribution: Bool

    /// Cap on bytes read from a request body, including stream-based bodies.
    /// Keeps a multipart file upload from being copied into memory.
    public var maxCapturedRequestBodyBytes: Int

    /// Cap on bytes retained from a response body.
    public var maxCapturedResponseBodyBytes: Int

    /// Hosts the lens captures, or empty to capture everything.
    ///
    /// An app talks to far more hosts than the ones its team owns — analytics,
    /// crash reporting, attribution, fonts, image CDNs — and every one of them
    /// competes for the `maxStoredExchanges` ring buffer. A session that
    /// re-fetches the same banner twenty times evicts the API calls someone
    /// opened the lens to look at.
    ///
    /// Filtering here rather than in the reader is deliberate: a host that is
    /// not captured is never intercepted, so it costs no `URLProtocol` round
    /// trip, takes no buffer slot and writes no trace line. The price is that
    /// mocks, breakpoints and replay do not reach it either — it is invisible
    /// to the whole tool, not merely hidden from the list.
    ///
    /// Matched like `productionHostPatterns`: equal to the host, or the host
    /// ends with `"." + pattern`, with a leading `*.` accepted and stripped.
    public var capturedHostPatterns: [String]

    /// Hosts treated as production. Request breakpoints refuse to arm against
    /// these, because an edited request creates real records on a real backend.
    /// Response breakpoints are unaffected — they never leave the device.
    ///
    /// Each pattern matches the host if it is equal to it, or if the host ends
    /// with `"." + pattern`, so `"api.acme.com"` covers `"eu.api.acme.com"`.
    /// A leading `*.` is accepted and stripped.
    public var productionHostPatterns: [String]

    /// Keep breakpoints, perturbations and mock rules across launches. Off by
    /// default: a forgotten breakpoint that survives a relaunch is
    /// indistinguishable from a hung app, and a forgotten mock from a backend
    /// bug.
    public var keepBreakpointsAcrossLaunches: Bool

    /// Write rules to disk and read them back at `start`.
    ///
    /// Independent of `keepBreakpointsAcrossLaunches`, which decides what is
    /// allowed to come back *armed*. With persistence on and that flag off —
    /// the default pair — saved perturbations survive while breakpoints and
    /// mocks do not.
    ///
    /// Off by default because it writes to Application Support, which is not
    /// something a debugging tool should start doing to a host app uninvited.
    public var persistsRules: Bool

    /// Run saved rules through the redactor before writing them to disk.
    ///
    /// On by default, and the safe default is the right one: a rule captured
    /// from a real response carries whatever that response carried, and
    /// Application Support ends up in backups.
    ///
    /// The cost is real and worth stating — a mock whose token was scrubbed
    /// will not satisfy an app that reads that token back, so a rule restored
    /// after relaunch can behave differently from the one that was saved. Turn
    /// this off deliberately when a rule's fidelity matters more than what
    /// lands on disk.
    public var redactsPersistedRules: Bool

    /// Write finished exchanges to a newline-delimited JSON file, or nil for
    /// the default of writing nothing.
    ///
    /// Off by default for the same reason `persistsRules` is: a debugging tool
    /// should not start writing a host app's traffic to disk uninvited. The
    /// trace is redacted on the way out, like every other thing this package
    /// persists.
    public var trace: TraceOptions?

    public init(
        matchers: [RequestMatcher] = [PathMatcher()],
        redactor: Redactor = DefaultRedactor(),
        maxStoredExchanges: Int = 500,
        automaticScreenAttribution: Bool = true,
        maxCapturedRequestBodyBytes: Int = 1_048_576,
        maxCapturedResponseBodyBytes: Int = 1_048_576,
        capturedHostPatterns: [String] = [],
        productionHostPatterns: [String] = [],
        keepBreakpointsAcrossLaunches: Bool = false,
        persistsRules: Bool = false,
        redactsPersistedRules: Bool = true,
        trace: TraceOptions? = nil
    ) {
        self.capturedHostPatterns = capturedHostPatterns
        self.productionHostPatterns = productionHostPatterns
        self.keepBreakpointsAcrossLaunches = keepBreakpointsAcrossLaunches
        self.persistsRules = persistsRules
        self.redactsPersistedRules = redactsPersistedRules
        self.trace = trace
        self.matchers = matchers
        self.redactor = redactor
        self.maxStoredExchanges = maxStoredExchanges
        self.automaticScreenAttribution = automaticScreenAttribution
        self.maxCapturedRequestBodyBytes = maxCapturedRequestBodyBytes
        self.maxCapturedResponseBodyBytes = maxCapturedResponseBodyBytes
    }

    /// True when the host is covered by `productionHostPatterns`.
    ///
    /// A `nil` host is treated as non-production: it means a malformed URL,
    /// and blocking on it would be confusing without protecting anything.
    public func isProductionHost(_ host: String?) -> Bool {
        Self.host(host, matchesAnyOf: productionHostPatterns)
    }

    /// True when the lens should capture traffic to this host.
    ///
    /// An empty `capturedHostPatterns` captures everything, so an app that
    /// never sets one keeps exactly the behaviour it had before the list
    /// existed.
    ///
    /// A `nil` host is captured only while the list is empty. Once a caller
    /// has named the hosts they want, a malformed URL cannot be shown to be
    /// one of them, and an allowlist that admits unknowns is not an allowlist
    /// — the opposite of `isProductionHost`, where letting an unknown through
    /// costs nothing.
    public func capturesHost(_ host: String?) -> Bool {
        guard !capturedHostPatterns.isEmpty else { return true }
        return Self.host(host, matchesAnyOf: capturedHostPatterns)
    }

    /// Shared by both host lists so the two cannot drift apart on what a
    /// pattern means.
    private static func host(_ host: String?, matchesAnyOf patterns: [String]) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        for raw in patterns {
            var pattern = raw.lowercased()
            if pattern.hasPrefix("*.") { pattern.removeFirst(2) }
            guard !pattern.isEmpty else { continue }
            if host == pattern || host.hasSuffix("." + pattern) { return true }
        }
        return false
    }

    /// REST defaults.
    public static var `default`: LensConfiguration { LensConfiguration() }

    /// GraphQL first, REST fallback for auth and file endpoints.
    public static func graphQL(paths: Set<String> = ["/graphql"]) -> LensConfiguration {
        LensConfiguration(matchers: [GraphQLMatcher(paths: paths), PathMatcher()])
    }
}
