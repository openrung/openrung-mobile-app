import Foundation
import XCTest

/// Integration-style startup tests for the confirmed China-bypass regression: geosite-cn contains
/// www.gstatic.com, so before the probe pins a dead proxy still yielded a passing probe over the
/// direct path and the app published CONNECTED.
///
/// These run the REAL seams — the WSS fallback ladder, the startup verification/classification
/// (`verifyStartupTunnelPath`, which alone authorizes success), the composite fresh-DNS + HTTPS
/// probe, resolver rotation, and the real cn-bypass configuration (DnsConfigurationTests pins
/// that every probe flow is proxied). Fakes exist only at the two socket boundaries, which is
/// precisely what a dead or working proxy controls. Mirror of Android
/// `StartupProbeChinaBypassTest`.
final class StartupPathVerificationTests: XCTestCase {
    func testDeadProxyWithChinaBypassAndWorkingDirectInternetNeverConnects() async throws {
        let rotation = DnsResolverRotation()
        let harness = LadderHarness(
            rotation: rotation,
            dnsBehavior: .throwError(URLError(.timedOut)),
            httpBehavior: .throwError(URLError(.timedOut))
        )

        do {
            _ = try await harness.connectLadder()
            XCTFail("startup must fail when every probe path is proxied and the proxy is dead")
        } catch let error as RelayFailureAlreadyRecordedError {
            XCTAssertEqual(error.directFailure.stage, startupStageDnsProbe)
        }

        // CONNECTED must never have been published, on any transport rung.
        let connected = await harness.log.connected()
        XCTAssertTrue(connected.isEmpty)
        let events = await harness.log.events()
        XCTAssertEqual(events, ["direct", "direct", "fallback", "wss:front-a", "wss:front-b"])
        // Real resolver failover: the same-relay retry and each later rung led with the
        // alternate resolver of the order that had just failed.
        let serversUsed = await harness.log.serversUsed()
        XCTAssertEqual(serversUsed, [
            ["1.1.1.1", "8.8.8.8"],
            ["8.8.8.8", "1.1.1.1"],
            ["1.1.1.1", "8.8.8.8"],
            ["8.8.8.8", "1.1.1.1"],
        ])
    }

    func testWorkingProxyWithChinaBypassConnectsExactlyOnce() async throws {
        let rotation = DnsResolverRotation()
        let harness = LadderHarness(
            rotation: rotation,
            dnsBehavior: .answer,
            httpBehavior: .respond204
        )

        let result = try await harness.connectLadder()
        XCTAssertEqual(result, "direct")
        let connected = await harness.log.connected()
        XCTAssertEqual(connected, ["direct"])
        // A healthy resolver path must not rotate anything.
        XCTAssertEqual(rotation.currentServers(), ["1.1.1.1", "8.8.8.8"])
    }

    func testEngineStopDuringVerificationStaysLocalAndNeverRotates() async {
        // A dead engine must neither authorize WSS fallback nor advance the resolver rotation:
        // the resolver was never given a functioning engine to answer through.
        let rotation = DnsResolverRotation()
        var rotated = false
        do {
            _ = try await verifyStartupTunnelPath(
                probe: {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    throw URLError(.timedOut)
                },
                waitForUnexpectedStop: { "libbox exited" },
                hasUnexpectedStop: { true },
                prepareForExpectedStop: { false },
                wssFrontID: nil,
                onDnsPathFailure: { rotated = true }
            )
            XCTFail("an engine stop must fail startup verification")
        } catch let error as LocalTunnelError {
            XCTAssertEqual(error.stage, "active_tunnel_engine")
        } catch {
            XCTFail("engine stop must classify as a local failure, got \(error)")
        }
        XCTAssertFalse(rotated)
        XCTAssertEqual(rotation.currentServers(), ["1.1.1.1", "8.8.8.8"])
    }
}

// MARK: - Harness

private actor LadderEventLog {
    private var eventValues: [String] = []
    private var connectedValues: [String] = []
    private var serverOrders: [[String]] = []

    func recordEvent(_ value: String) { eventValues.append(value) }
    func recordConnected(_ value: String) { connectedValues.append(value) }
    func recordServers(_ value: [String]) { serverOrders.append(value) }

    func events() -> [String] { eventValues }
    func connected() -> [String] { connectedValues }
    func serversUsed() -> [[String]] { serverOrders }
}

/// The provider's connect rung for one relay, on the production seams: the WSS fallback policy
/// drives direct → WSS attempts; each attempt races the composite probe against a (quiet) engine
/// stop via `verifyStartupTunnelPath`, and only a returned probe result records CONNECTED — the
/// exact gate in front of SharedConnectionState.setStatus(.connected). The direct rung retries
/// once with the rotated resolver, mirroring attemptDirectCandidate's relay-hub loop.
private struct LadderHarness {
    let rotation: DnsResolverRotation
    let dnsBehavior: ScriptedDnsBehavior
    let httpBehavior: ScriptedHTTPBehavior
    let log = LadderEventLog()

    func connectLadder() async throws -> String {
        let policy = WssFallbackPolicy(validator: AcceptExactFronts())
        let relay = makeWssTestRelay()

        return try await policy.connect(
            relay: relay,
            attemptDirect: {
                var spareResolvers = rotation.resolverCount - 1
                while true {
                    await log.recordEvent("direct")
                    do {
                        return try await verifyRung(transport: "direct", frontID: nil)
                    } catch let error as DirectPathError {
                        guard error.stage == startupStageDnsProbe, spareResolvers > 0 else {
                            throw error
                        }
                        spareResolvers -= 1
                    }
                }
            },
            attemptWss: { front in
                await log.recordEvent("wss:\(front.id)")
                return try await verifyRung(transport: "wss", frontID: front.id)
            },
            onDirectFallback: { _ in await log.recordEvent("fallback") },
            onWssFailure: { _, _ in }
        )
    }

    private func verifyRung(transport: String, frontID: String?) async throws -> String {
        let servers = rotation.currentServers()
        await log.recordServers(servers)
        _ = try await verifyStartupTunnelPath(
            probe: {
                try await PacketTunnelPathProbe(
                    dnsProbe: PacketTunnelDnsProbe(
                        transport: ScriptedDns(behavior: dnsBehavior),
                        deadlineMilliseconds: 100,
                        retryDelayNanoseconds: 20_000_000,
                        attemptTimeoutMilliseconds: 50
                    ),
                    httpProbe: PacketTunnelInternetProbe(
                        transport: ScriptedHTTP(behavior: httpBehavior),
                        deadlineMilliseconds: 100,
                        retryDelayNanoseconds: 20_000_000,
                        requestTimeoutMilliseconds: 50
                    )
                ).verify()
            },
            waitForUnexpectedStop: {
                while Task.isCancelled == false {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                return nil
            },
            hasUnexpectedStop: { false },
            prepareForExpectedStop: { true },
            wssFrontID: frontID,
            onDnsPathFailure: { rotation.noteDnsPathFailure(servers) }
        )
        await log.recordConnected(transport)
        return transport
    }
}

private struct AcceptExactFronts: WssFrontSetValidating {
    func validateExact(_ fronts: [WssFrontDescriptor]) throws {}
}

private enum ScriptedDnsBehavior {
    case answer
    case throwError(Error)
}

private struct ScriptedDns: ThroughTunnelDatagramTransport {
    let behavior: ScriptedDnsBehavior

    func exchange(_ datagram: Data) async throws -> Data {
        switch behavior {
        case .answer:
            let bytes = [UInt8](datagram.prefix(2))
            return Data([bytes[0], bytes[1], 0x81, 0x83, 0, 0, 0, 0, 0, 0, 0, 0])
        case .throwError(let error):
            throw error
        }
    }
}

private enum ScriptedHTTPBehavior {
    case respond204
    case throwError(Error)
}

private struct ScriptedHTTP: ThroughTunnelHTTPTransport {
    let behavior: ScriptedHTTPBehavior

    func responseHead(for endpoint: TunnelProbeEndpoint) async throws -> Data {
        switch behavior {
        case .respond204:
            return Data("HTTP/1.1 204 No Content\r\n\r\n".utf8)
        case .throwError(let error):
            throw error
        }
    }
}
