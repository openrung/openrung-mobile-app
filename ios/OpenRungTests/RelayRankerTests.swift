import Foundation
import XCTest

/// Unit tests for `RelayRanker`. The ranker and its compile closure (`RelayDescriptor`,
/// `RelayReachability`, `RelayReachabilityError`) are compiled directly into this test target —
/// see the `OpenRungTests` target in `project.yml` — so no import of the app/extension is needed.
/// Every test injects a fake probe; no sockets are opened.
final class RelayRankerTests: XCTestCase {

    func testSortsProbedRelaysByLatencyBucketFastestFirst() async {
        let relays = [relay("a"), relay("b"), relay("c")]
        let latencies: [String: Int64] = ["a": 200, "b": 40, "c": 120]

        let ranked = await RelayRanker.rankByTcpLatency(relays) { relay, _ in
            latencies[relay.id]!
        }

        XCTAssertEqual(ranked.map(\.relay.id), ["b", "c", "a"])
        XCTAssertEqual(ranked.map(\.probeMs), [40, 120, 200])
    }

    func testBrokerOrderDecidesWithinALatencyBucket() async {
        // 31 and 45 share the 30ms bucket; broker order (a before b) must survive even though
        // b measured marginally faster. c's 95 lands two buckets up and sorts last.
        let relays = [relay("a"), relay("b"), relay("c")]
        let latencies: [String: Int64] = ["a": 45, "b": 31, "c": 95]

        let ranked = await RelayRanker.rankByTcpLatency(relays) { relay, _ in
            latencies[relay.id]!
        }

        XCTAssertEqual(ranked.map(\.relay.id), ["a", "b", "c"])
    }

    func testFailedProbesSinkBelowReachableRelaysButAreNeverDropped() async {
        let relays = [relay("dead"), relay("slow"), relay("fast")]

        let ranked = await RelayRanker.rankByTcpLatency(relays) { relay, _ in
            switch relay.id {
            case "dead": throw RelayReachabilityError.timeout
            case "slow": return 400
            default: return 20
            }
        }

        XCTAssertEqual(ranked.map(\.relay.id), ["fast", "slow", "dead"])
        XCTAssertNil(ranked.last?.probeMs ?? nil)
    }

    func testUnprobedTailKeepsBrokerOrderAfterTheProbedHead() async {
        let relays = (1...5).map { relay("r\($0)") }
        // Probe only the first three; reverse their latency so the head visibly reorders.
        let latencies: [String: Int64] = ["r1": 300, "r2": 150, "r3": 10]

        let ranked = await RelayRanker.rankByTcpLatency(relays, maxProbes: 3) { relay, _ in
            latencies[relay.id]!
        }

        XCTAssertEqual(ranked.map(\.relay.id), ["r3", "r2", "r1", "r4", "r5"])
        XCTAssertNil(ranked[3].probeMs)
        XCTAssertNil(ranked[4].probeMs)
    }

    func testSingleCandidateShortCircuitsWithoutProbing() async {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func increment() { lock.lock(); value += 1; lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        }
        let probes = Counter()

        let ranked = await RelayRanker.rankByTcpLatency([relay("only")]) { _, _ in
            probes.increment()
            return 10
        }

        XCTAssertEqual(ranked.map(\.relay.id), ["only"])
        XCTAssertNil(ranked[0].probeMs)
        XCTAssertEqual(probes.count, 0)
    }

    func testProbesRunConcurrentlyNotSequentially() async {
        let relays = (1...4).map { relay("r\($0)") }
        let started = DispatchTime.now().uptimeNanoseconds

        _ = await RelayRanker.rankByTcpLatency(relays) { _, _ in
            try await Task.sleep(nanoseconds: 200_000_000) // 200ms each
            return 50
        }

        let elapsedMs = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        // Four sequential probes would need >=800ms; allow generous scheduler slack.
        XCTAssertLessThan(elapsedMs, 600)
    }

    private func relay(_ id: String) -> RelayDescriptor {
        RelayDescriptor(
            id: id,
            publicHost: "203.0.113.10",
            publicPort: 443,
            relayProtocol: RelayConstants.protocolVLESSRealityVision,
            clientID: "e6b1a1de-9f0f-4c1a-8bb1-1f2b3c4d5e6f",
            realityPublicKey: "key",
            shortID: "abcd",
            serverName: "www.example.com",
            flow: RelayConstants.flowVision,
            exitMode: RelayConstants.exitModeDirect,
            maxSessions: 8,
            maxMbps: 100,
            relayVersion: "1.0.0",
            registeredAt: Date(timeIntervalSince1970: 1_767_225_600),
            lastHeartbeatAt: Date(timeIntervalSince1970: 1_767_225_600),
            expiresAt: Date(timeIntervalSince1970: 1_767_229_200)
        )
    }
}
