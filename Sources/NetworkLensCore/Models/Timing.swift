//
//  Timing.swift
//  NetworkLensCore
//
//  Created by Rohit Sahay on 29/07/26.
//

import Foundation

/// Phase breakdown for a single exchange, derived from `URLSessionTaskMetrics`.
///
/// We deliberately do not compute these from manual start/end timestamps —
/// the point is the DNS / TLS / server-think split, which only the metrics
/// transaction records expose. Every phase is optional because a transaction
/// served from cache, or a reused connection, legitimately omits them.
public struct Timing: Codable, Sendable, Hashable {

    /// Wall clock from task start to task completion.
    public var total: TimeInterval

    public var domainLookup: TimeInterval?
    public var connect: TimeInterval?
    public var tls: TimeInterval?

    /// Time spent writing the request.
    public var requestUpload: TimeInterval?

    /// Gap between the last request byte out and the first response byte in.
    /// This is the number engineers actually argue about.
    public var serverThink: TimeInterval?

    /// Time spent reading the response body.
    public var responseDownload: TimeInterval?

    public var isReusedConnection: Bool
    public var isProxyConnection: Bool
    public var fromCache: Bool
    public var networkProtocolName: String?

    public init(
        total: TimeInterval,
        domainLookup: TimeInterval? = nil,
        connect: TimeInterval? = nil,
        tls: TimeInterval? = nil,
        requestUpload: TimeInterval? = nil,
        serverThink: TimeInterval? = nil,
        responseDownload: TimeInterval? = nil,
        isReusedConnection: Bool = false,
        isProxyConnection: Bool = false,
        fromCache: Bool = false,
        networkProtocolName: String? = nil
    ) {
        self.total = total
        self.domainLookup = domainLookup
        self.connect = connect
        self.tls = tls
        self.requestUpload = requestUpload
        self.serverThink = serverThink
        self.responseDownload = responseDownload
        self.isReusedConnection = isReusedConnection
        self.isProxyConnection = isProxyConnection
        self.fromCache = fromCache
        self.networkProtocolName = networkProtocolName
    }
}

extension Timing {

    /// Builds a `Timing` from task metrics, using the last transaction —
    /// redirects produce several, and the last one is the one that answered.
    public init?(metrics: URLSessionTaskMetrics) {
        guard let transaction = metrics.transactionMetrics.last else { return nil }

        func gap(_ start: Date?, _ end: Date?) -> TimeInterval? {
            guard let start, let end else { return nil }
            let delta = end.timeIntervalSince(start)
            return delta >= 0 ? delta : nil
        }

        self.init(
            total: metrics.taskInterval.duration,
            domainLookup: gap(transaction.domainLookupStartDate, transaction.domainLookupEndDate),
            connect: gap(transaction.connectStartDate, transaction.connectEndDate),
            tls: gap(transaction.secureConnectionStartDate, transaction.secureConnectionEndDate),
            requestUpload: gap(transaction.requestStartDate, transaction.requestEndDate),
            serverThink: gap(transaction.requestEndDate, transaction.responseStartDate),
            responseDownload: gap(transaction.responseStartDate, transaction.responseEndDate),
            isReusedConnection: transaction.isReusedConnection,
            isProxyConnection: transaction.isProxyConnection,
            fromCache: transaction.resourceFetchType == .localCache,
            networkProtocolName: transaction.networkProtocolName
        )
    }
}
