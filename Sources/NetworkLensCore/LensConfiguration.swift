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

    public init(
        matchers: [RequestMatcher] = [PathMatcher()],
        redactor: Redactor = DefaultRedactor(),
        maxStoredExchanges: Int = 500,
        automaticScreenAttribution: Bool = true,
        maxCapturedRequestBodyBytes: Int = 1_048_576,
        maxCapturedResponseBodyBytes: Int = 1_048_576,
        productionHostPatterns: [String] = [],
        keepBreakpointsAcrossLaunches: Bool = false,
        persistsRules: Bool = false,
        redactsPersistedRules: Bool = true
    ) {
        self.productionHostPatterns = productionHostPatterns
        self.keepBreakpointsAcrossLaunches = keepBreakpointsAcrossLaunches
        self.persistsRules = persistsRules
        self.redactsPersistedRules = redactsPersistedRules
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
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        for raw in productionHostPatterns {
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
