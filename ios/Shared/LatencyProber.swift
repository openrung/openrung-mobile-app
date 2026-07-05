import Foundation

/// Concurrent TCP-connect latency probe for exit-relay endpoints, wrapping the existing
/// `RelayReachability.checkTcp` NWConnection timing in a bounded task group.
///
/// Tunnel bypass caveat: unlike Android, an app-side `NWConnection` has no clean `protect()`
/// equivalent, so while the tunnel is up these probes ride it. We report `viaTunnel = true`
/// whenever a probe ran while connected and let the UI disable the affordance in that case;
/// accurate direct RTTs are only guaranteed while disconnected.
struct LatencyProbeTarget {
    let id: String
    let host: String
    let port: Int
}

struct LatencyProbeResult {
    let id: String
    let latencyMs: Int64?
    let reachable: Bool
}

struct LatencyMeasurementResult {
    let viaTunnel: Bool
    let results: [LatencyProbeResult]
}

enum LatencyProber {
    static func measure(
        targets: [LatencyProbeTarget],
        timeoutMillis: Int,
        viaTunnel: Bool,
        concurrency: Int = 8
    ) async -> LatencyMeasurementResult {
        var results: [LatencyProbeResult] = []
        let limit = max(1, concurrency)
        var index = 0

        // Sliding window: keep at most `limit` probes in flight.
        await withTaskGroup(of: LatencyProbeResult.self) { group in
            func addProbe(_ target: LatencyProbeTarget) {
                group.addTask {
                    do {
                        let rtt = try await RelayReachability.checkTcp(
                            host: target.host,
                            port: target.port,
                            timeoutMillis: timeoutMillis
                        )
                        return LatencyProbeResult(id: target.id, latencyMs: rtt, reachable: true)
                    } catch {
                        // Timeout or refused: a dead relay either way.
                        return LatencyProbeResult(id: target.id, latencyMs: nil, reachable: false)
                    }
                }
            }

            while index < targets.count && index < limit {
                addProbe(targets[index])
                index += 1
            }
            for await result in group {
                results.append(result)
                if index < targets.count {
                    addProbe(targets[index])
                    index += 1
                }
            }
        }

        return LatencyMeasurementResult(viaTunnel: viaTunnel, results: results)
    }
}
