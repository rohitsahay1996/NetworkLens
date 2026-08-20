//
//  Breakpoint.swift
//  NetworkLensCore
//
//  Created by Rohit Sahay on 29/07/26.
//

import Foundation

/// Which side of the exchange a breakpoint holds.
public enum BreakpointStage: String, Codable, Sendable, CaseIterable {
    case request
    case response
    case both

    public var pausesRequest: Bool { self == .request || self == .both }
    public var pausesResponse: Bool { self == .response || self == .both }

    public var label: String {
        switch self {
        case .request: return "Request"
        case .response: return "Response"
        case .both: return "Request & response"
        }
    }
}

/// A rule that pauses matching traffic.
public struct Breakpoint: Codable, Sendable, Hashable, Identifiable {

    public let id: UUID
    /// Matched against `NetworkExchange.endpointKey`, so it survives path
    /// params and works for GraphQL operations without any special casing.
    public var endpointKey: String
    /// One concrete URL to pin to, query string and all. `nil` — the default —
    /// matches by `endpointKey`.
    ///
    /// The escape hatch for query-routed APIs, where every request shares a
    /// root path and collapses to the same endpoint key (`"GET /"`): the query
    /// is the only thing that tells one call from another, and `endpointKey`
    /// deliberately drops it. Matched leniently through the redactor so a URL
    /// carrying an `?access_token=…` still matches its own traffic — see
    /// `Breakpoints.canonicalURL(_:)`.
    public var url: String?
    public var stage: BreakpointStage
    public var isEnabled: Bool
    /// Auto-disable after the first hit. The common case for "let me see this
    /// one call" without stepping through every retry.
    public var oneShot: Bool

    public init(
        id: UUID = UUID(),
        endpointKey: String,
        url: String? = nil,
        stage: BreakpointStage = .response,
        isEnabled: Bool = true,
        oneShot: Bool = false
    ) {
        self.id = id
        self.endpointKey = endpointKey
        self.url = url
        self.stage = stage
        self.isEnabled = isEnabled
        self.oneShot = oneShot
    }

    /// Stable identity for storage, dedup and the coordinator's hit/skip
    /// bookkeeping. A URL breakpoint is its URL; an endpoint breakpoint its key.
    ///
    /// Two exact-URL breakpoints on the same query-routed endpoint share an
    /// `endpointKey` and would otherwise overwrite each other, so identity has
    /// to be the thing actually matched, not the grouping key.
    public var matchIdentity: String { url ?? endpointKey }

    /// True when this pins one concrete URL rather than a logical endpoint.
    public var isURLScoped: Bool { url != nil }
}

/// A reusable edit, applied to whatever the live payload is at the time.
///
/// Preferred over storing a full payload: a payload goes stale the moment the
/// server adds a field, while "set `/data/items/0/stock` to 0" keeps meaning
/// the same thing.
public struct Perturbation: Codable, Sendable, Hashable, Identifiable {

    public let id: UUID
    /// Short, memorable: "out_of_stock", "expired_card".
    public var name: String
    public var endpointKey: String
    public var ops: [PatchOp]
    /// Whether this is currently rewriting traffic.
    ///
    /// Off by default. Saving a variant is how a tester builds a library of
    /// them — "empty cart", "expired card" — and each one silently taking
    /// effect the moment it is saved would make the library unusable and the
    /// app's behaviour inexplicable.
    public var isEnabled: Bool
    /// Set once someone has confirmed the app behaves correctly under it.
    public var qaVerified: Bool
    /// `JSONNode.shapeHash` of the response this was captured from, so a
    /// contract change can be flagged instead of silently mis-applying.
    public var verifiedAgainstShape: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        endpointKey: String,
        ops: [PatchOp],
        isEnabled: Bool = false,
        qaVerified: Bool = false,
        verifiedAgainstShape: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.endpointKey = endpointKey
        self.ops = ops
        self.isEnabled = isEnabled
        self.qaVerified = qaVerified
        self.verifiedAgainstShape = verifiedAgainstShape
        self.createdAt = createdAt
    }

    /// Applies the ops, reporting whether the payload's shape still matches
    /// what this was captured against.
    public func apply(to tree: JSONNode) throws -> (result: JSONNode, shapeDrifted: Bool) {
        let drifted = verifiedAgainstShape.map { $0 != tree.shapeHash } ?? false
        return (try tree.applying(ops), drifted)
    }
}
