//
//  RegexMatcher.swift
//  NetworkLensCore
//
//  Created by Rohit Sahay on 29/07/26.
//

import Foundation

/// Escape hatch for APIs whose paths do not follow the numeric/UUID convention
/// `PathMatcher` assumes — versioned slugs, tenant prefixes, locale segments.
///
/// The first matching rule wins, and its template becomes the key.
public struct RegexMatcher: RequestMatcher {

    public struct Rule: Sendable {
        /// Applied to the URL path only, not the full URL.
        public let regex: NSRegularExpression
        /// Template for the key's path portion. Supports `$1`-style capture
        /// group references.
        public let template: String
        /// Restrict the rule to one HTTP method. `nil` matches any.
        public let method: String?

        public init(pattern: String, template: String, method: String? = nil) throws {
            self.regex = try NSRegularExpression(pattern: pattern, options: [])
            self.template = template
            self.method = method?.uppercased()
        }
    }

    public let identifier: String
    public let rules: [Rule]

    public init(identifier: String = "regex", rules: [Rule]) {
        self.identifier = identifier
        self.rules = rules
    }

    public func endpointKey(for request: URLRequest) -> String? {
        guard let path = request.url?.path else { return nil }
        let method = request.httpMethod?.uppercased() ?? "GET"
        let range = NSRange(path.startIndex..<path.endIndex, in: path)

        for rule in rules {
            if let ruleMethod = rule.method, ruleMethod != method { continue }
            guard rule.regex.firstMatch(in: path, options: [.anchored], range: range) != nil else {
                continue
            }
            let templated = rule.regex.stringByReplacingMatches(
                in: path, options: [], range: range, withTemplate: rule.template
            )
            return "\(method) \(templated)"
        }
        return nil
    }
}
