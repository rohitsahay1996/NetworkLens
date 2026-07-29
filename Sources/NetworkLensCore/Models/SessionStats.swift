import Foundation

/// Aggregate view over the store, computed on demand.
///
/// Lives in Core rather than the overlay so milestone 4 can print it from a
/// headless CI run with no UI attached.
public struct SessionStats: Sendable, Hashable {

    public struct EndpointStat: Sendable, Hashable, Identifiable {
        public var endpointKey: String
        public var count: Int
        public var failureCount: Int
        /// Mean total duration over exchanges that reported timing.
        public var averageDuration: TimeInterval?

        public var id: String { endpointKey }
    }

    public var totalRequests: Int
    public var inFlightCount: Int
    /// Descending by count, then alphabetical, so the order is stable.
    public var endpoints: [EndpointStat]
    /// Failure counts keyed by bucket. Buckets with zero are omitted.
    public var failuresByKind: [FailureInfo.Kind: Int]
    public var countsBySource: [Source: Int]

    public var totalFailures: Int { failuresByKind.values.reduce(0, +) }

    public init(exchanges: [NetworkExchange]) {
        totalRequests = exchanges.count
        inFlightCount = exchanges.filter(\.isInFlight).count

        var failures: [FailureInfo.Kind: Int] = [:]
        var sources: [Source: Int] = [:]
        var grouped: [String: (count: Int, failures: Int, durations: [TimeInterval])] = [:]

        for exchange in exchanges {
            sources[exchange.source, default: 0] += 1
            if let kind = exchange.failure?.kind {
                failures[kind, default: 0] += 1
            }
            var bucket = grouped[exchange.endpointKey] ?? (0, 0, [])
            bucket.count += 1
            if exchange.failure != nil { bucket.failures += 1 }
            if let total = exchange.timing?.total { bucket.durations.append(total) }
            grouped[exchange.endpointKey] = bucket
        }

        failuresByKind = failures
        countsBySource = sources
        endpoints = grouped
            .map { key, bucket in
                EndpointStat(
                    endpointKey: key,
                    count: bucket.count,
                    failureCount: bucket.failures,
                    averageDuration: bucket.durations.isEmpty
                        ? nil
                        : bucket.durations.reduce(0, +) / Double(bucket.durations.count)
                )
            }
            .sorted { lhs, rhs in
                lhs.count == rhs.count
                    ? lhs.endpointKey < rhs.endpointKey
                    : lhs.count > rhs.count
            }
    }
}
