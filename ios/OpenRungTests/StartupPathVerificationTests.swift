import Foundation
import XCTest

/// Integration-style startup tests for the confirmed China-bypass regression: geosite-cn contains
/// www.gstatic.com, so before the probe pins a dead proxy still yielded a passing probe over the
/// direct path and the app published CONNECTED.
///
/// These run the REAL seams — the WSS fallback ladder, the startup verification/classification
/// (`verifyStartupTunnelPath`, which alone authorizes success), the composite fresh-DNS + HTTPS
/// probe, resolver failover, and the real cn-bypass configuration (DnsConfigurationTests pins
/// that every probe flow is proxied). Fakes exist only at the two socket boundaries, which is
/// precisely what a dead or working proxy controls. Mirror of Android
/// `StartupProbeChinaBypassTest`.
final class StartupPathVerificationTests: XCTestCase {
    func testDeadProxyWithChinaBypassAndWorkingDirectInternetNeverConnects() async throws {
        let harness = LadderHarness(
            dnsBehavior: .throwError(URLError(.timedOut)),
            httpBehavior: .throwError(URLError(.timedOut))
        )

        do {
            _ = try await harness.connectLadder()
            XCTFail("startup must fail when every probe path is proxied and the proxy is dead")
        } catch let error as RelayFailureAlreadyRecordedError {
            // Resolver failover happens inside the emitted DNS rule chain, so a dns_probe-stage
            // failure here means no configured resolver answered through the dead proxy.
            XCTAssertEqual(error.directFailure.stage, startupStageDnsProbe)
        }

        // CONNECTED must never have been published, on any transport rung.
        let connected = await harness.log.connected()
        XCTAssertTrue(connected.isEmpty)
        let events = await harness.log.events()
        XCTAssertEqual(events, ["direct", "fallback", "wss:front-a", "wss:front-b"])
    }

    func testWorkingProxyWithChinaBypassConnectsExactlyOnce() async throws {
        let harness = LadderHarness(
            dnsBehavior: .answer,
            httpBehavior: .respond204
        )

        let result = try await harness.connectLadder()
        XCTAssertEqual(result, "direct")
        let connected = await harness.log.connected()
        XCTAssertEqual(connected, ["direct"])
        let events = await harness.log.events()
        XCTAssertEqual(events, ["direct"])
    }

    func testEngineStopDuringVerificationStaysLocal() async {
        // A dead engine must never authorize WSS fallback: it is local evidence, not proof of a
        // remote path problem.
        do {
            _ = try await verifyStartupTunnelPath(
                probe: {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    throw URLError(.timedOut)
                },
                waitForUnexpectedStop: { "libbox exited" },
                hasUnexpectedStop: { true },
                prepareForExpectedStop: { false },
                wssFrontID: nil
            )
            XCTFail("an engine stop must fail startup verification")
        } catch let error as LocalTunnelError {
            XCTAssertEqual(error.stage, "active_tunnel_engine")
        } catch {
            XCTFail("engine stop must classify as a local failure, got \(error)")
        }
    }
}

// MARK: - Harness

private actor LadderEventLog {
    private var eventValues: [String] = []
    private var connectedValues: [String] = []

    func recordEvent(_ value: String) { eventValues.append(value) }
    func recordConnected(_ value: String) { connectedValues.append(value) }

    func events() -> [String] { eventValues }
    func connected() -> [String] { connectedValues }
}

/// The provider's connect rung for one relay, on the production seams: the WSS fallback policy
/// drives direct → WSS attempts; each attempt races the composite probe against a (quiet) engine
/// stop via `verifyStartupTunnelPath`, and only a returned probe result records CONNECTED — the
/// exact gate in front of SharedConnectionState.setStatus(.connected).
private struct LadderHarness {
    let dnsBehavior: ScriptedDnsBehavior
    let httpBehavior: ScriptedHTTPBehavior
    let log = LadderEventLog()

    func connectLadder() async throws -> String {
        let policy = WssFallbackPolicy(validator: AcceptExactFronts())
        let relay = makeWssTestRelay()

        return try await policy.connect(
            relay: relay,
            attemptDirect: {
                await log.recordEvent("direct")
                return try await verifyRung(transport: "direct", frontID: nil)
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
            wssFrontID: frontID
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
