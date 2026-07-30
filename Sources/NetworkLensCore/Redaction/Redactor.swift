//
//  Redactor.swift
//  NetworkLensCore
//
//  Created by Rohit Sahay on 29/07/26.
//

import Foundation

/// Strips secrets from a snapshot.
///
/// Redaction runs **before persistence**, not before display. Auth headers and
/// payment fields must never reach the store, so there is no code path where a
/// stored exchange still holds them — including the milestone 4 JSON trace
/// written to disk in CI.
public protocol Redactor: Sendable {
    func redact(_ request: RequestSnapshot) -> RequestSnapshot
    func redact(_ response: ResponseSnapshot) -> ResponseSnapshot
}

/// Pass-through, for tests and for apps that opt out deliberately.
public struct NoRedactor: Redactor {
    public init() {}
    public func redact(_ request: RequestSnapshot) -> RequestSnapshot { request }
    public func redact(_ response: ResponseSnapshot) -> ResponseSnapshot { response }
}
