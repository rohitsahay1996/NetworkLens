//
//  FailureInfo.swift
//  NetworkLensCore
//
//  Created by Rohit Sahay on 29/07/26.
//

import Foundation

/// Why an exchange did not produce a usable success response.
///
/// The `kind` buckets are the ones the session stats view reports against, so
/// they are part of the contract rather than a display detail.
public struct FailureInfo: Codable, Sendable, Hashable {

    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// No HTTP response at all — DNS, TLS, timeout, cancellation, offline.
        case transport
        /// 4xx.
        case clientError
        /// 5xx.
        case serverError
        /// HTTP succeeded but the payload could not be decoded. Only the host
        /// app can report this, via `NetworkLens.record(_:)`.
        case decode
    }

    public var kind: Kind
    public var domain: String?
    public var code: Int?
    public var message: String

    public init(kind: Kind, domain: String? = nil, code: Int? = nil, message: String) {
        self.kind = kind
        self.domain = domain
        self.code = code
        self.message = message
    }

    /// Transport failure from a `URLSession` error.
    public init(error: Error) {
        let nsError = error as NSError
        self.init(
            kind: .transport,
            domain: nsError.domain,
            code: nsError.code,
            message: nsError.localizedDescription
        )
    }

    /// Non-2xx failure derived from a response. Returns `nil` for 2xx and 3xx.
    public init?(statusCode: Int) {
        switch statusCode {
        case 400..<500: self.init(kind: .clientError, code: statusCode, message: "HTTP \(statusCode)")
        case 500..<600: self.init(kind: .serverError, code: statusCode, message: "HTTP \(statusCode)")
        default: return nil
        }
    }
}
