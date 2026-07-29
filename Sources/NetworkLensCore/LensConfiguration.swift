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

    public init(
        matchers: [RequestMatcher] = [PathMatcher()],
        redactor: Redactor = DefaultRedactor(),
        maxStoredExchanges: Int = 500,
        automaticScreenAttribution: Bool = true,
        maxCapturedRequestBodyBytes: Int = 1_048_576,
        maxCapturedResponseBodyBytes: Int = 1_048_576
    ) {
        self.matchers = matchers
        self.redactor = redactor
        self.maxStoredExchanges = maxStoredExchanges
        self.automaticScreenAttribution = automaticScreenAttribution
        self.maxCapturedRequestBodyBytes = maxCapturedRequestBodyBytes
        self.maxCapturedResponseBodyBytes = maxCapturedResponseBodyBytes
    }

    /// REST defaults.
    public static var `default`: LensConfiguration { LensConfiguration() }

    /// GraphQL first, REST fallback for auth and file endpoints.
    public static func graphQL(paths: Set<String> = ["/graphql"]) -> LensConfiguration {
        LensConfiguration(matchers: [GraphQLMatcher(paths: paths), PathMatcher()])
    }
}
