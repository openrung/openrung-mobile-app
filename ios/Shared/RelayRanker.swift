import Foundation

/// Client-side latency ranking for the relay connect ladder. Port of Android `RelayRanker`.
///
/// The broker already orders relays by a composite score (load headroom, success rate, latency,
/// speed) from its own vantage; the one signal it cannot know is THIS client's network path. The
/// ranker probes TCP connect latency to the head of the candidate list in parallel and reorders by
/// latency BUCKET with a stable sort, so broker order — and with it the broker's load balancing —
/// still decides among relays whose measured latency is within `defaultBucketMs` of each other.
/// Only humanly meaningful differences (a bucket boundary) override the broker.
///
/// Ranking is fail-open by design: it reorders candidates but never drops one. A failed or
/// timed-out probe sinks that relay below the reachable ones (the connect ladder's own 5s
/// reachability gate may still succeed where a short probe gave up), and candidates beyond
/// `defaultMaxProbes` keep broker order after the probed head.
///
/// The probe targets `publicHost`, which is the actual exit for the `direct` relays that pass
/// `isUsable` today. If tunnel (CGNAT) relays ever become usable, publicHost is the relay hub —
/// TCP latency to it would not measure the exit path (same trap as geolocating publicHost; see
/// RelayDescriptor).
public enum RelayRanker {
    public static let defaultMaxProbes = 8
    public static let defaultProbeTimeoutMillis = 1_500

    /// Bucket width: within one bucket, broker order is preserved (stable sort).
    public static let defaultBucketMs: Int64 = 30

    public struct RankedRelay: Sendable {
        public let relay: RelayDescriptor
        public let probeMs: Int64?

        public init(relay: RelayDescriptor, probeMs: Int64?) {
            self.relay = relay
            self.probeMs = probeMs
        }
    }

    public static func rankByTcpLatency(
        _ candidates: [RelayDescriptor],
        maxProbes: Int = defaultMaxProbes,
        probeTimeoutMillis: Int = defaultProbeTimeoutMillis,
        bucketMs: Int64 = defaultBucketMs,
        probe: @escaping @Sendable (RelayDescriptor, Int) async throws -> Int64 = { relay, timeout in
            try await RelayReachability.checkTcp(relay, timeoutMillis: timeout)
        }
    ) async -> [RankedRelay] {
        // Nothing to reorder: skip the probes (and their radio wake) entirely.
        guard candidates.count > 1 else {
            return candidates.map { RankedRelay(relay: $0, probeMs: nil) }
        }

        let head = Array(candidates.prefix(maxProbes))
        let tail = candidates.dropFirst(maxProbes)
        var probeResults = [Int64?](repeating: nil, count: head.count)
        await withTaskGroup(of: (Int, Int64?).self) { group in
            for (index, relay) in head.enumerated() {
                group.addTask {
                    // A failed/timed-out/cancelled probe maps to nil (fail-open); the caller's
                    // Task.checkCancellation surfaces a racing stop right after ranking.
                    (index, try? await probe(relay, probeTimeoutMillis))
                }
            }
            for await (index, ms) in group {
                probeResults[index] = ms
            }
        }
        let probed = head.enumerated().map { index, relay in
            RankedRelay(relay: relay, probeMs: probeResults[index])
        }
        // Swift's sort is not guaranteed stable — sort on (bucket, broker index) explicitly so
        // equal buckets keep broker order.
        let reachable = probed.enumerated()
            .filter { $0.element.probeMs != nil }
            .sorted { lhs, rhs in
                let lhsBucket = lhs.element.probeMs! / bucketMs
                let rhsBucket = rhs.element.probeMs! / bucketMs
                return lhsBucket == rhsBucket ? lhs.offset < rhs.offset : lhsBucket < rhsBucket
            }
            .map(\.element)
        let failed = probed.filter { $0.probeMs == nil }
        return reachable + failed + tail.map { RankedRelay(relay: $0, probeMs: nil) }
    }
}
