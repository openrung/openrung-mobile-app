import Foundation
import XCTest

final class EngineAdapterTests: XCTestCase {
    func testSettingsCleanupRespectsOSStopAndPreservesCandidateFailures() throws {
        let settings = EngineTunnelSettingsCleanup()
        let failure = NSError(domain: "NEAgentErrorDomain", code: 1)
        XCTAssertThrowsError(try settings.clearAfterRun { throw failure })
        settings.beginProviderStop()
        try settings.clearAfterRun { XCTFail("Requested settings after OS stop") }
        settings.beginProviderStart()
        var cleared = false
        try settings.clearAfterRun { cleared = true }
        XCTAssertTrue(cleared)
        // An NE stop can arrive while setTunnelNetworkSettings is awaiting its
        // completion. Only that explicit handoff makes the rejected clear safe.
        try settings.clearAfterRun { settings.beginProviderStop(); throw failure }
    }
    func testDispatcherIsAsynchronousOrdersAndDropsReplacedOwners() {
        var queued: [() -> Void] = []
        var old: [UInt64] = [], new: [UInt64] = []
        var invalid = 0
        let events = EngineEventDispatcher(post: { queued.append($0) }, invalid: { invalid += 1 })
        func emit(_ sequence: Int, kind: String = "state") {
            events.onEvent("{\"version\":1,\"sequence\":\(sequence),\"kind\":\"\(kind)\",\"payload\":{}}")
        }
        events.attach { old.append($0.sequence) }
        emit(1)
        XCTAssertTrue(old.isEmpty)
        events.detach()
        events.attach { new.append($0.sequence) }
        emit(2); emit(2); emit(1); emit(3, kind: "future"); emit(4)
        events.onEvent("{\"version\":true,\"sequence\":5,\"kind\":\"state\",\"payload\":{}}")
        queued.forEach { $0() }
        XCTAssertTrue(old.isEmpty)
        XCTAssertEqual(new, [2, 4])
        XCTAssertEqual(invalid, 1)
    }

    func testProjectionSanitizesMetadataAndIgnoresStaleRecent() throws {
        let connected = EngineEvent(sequence: 1, kind: "state", payload: ["Status": "connected", "Details": ["SessionID": "session", "RelayID": "relay_1234567890123456", "RelayName": "relay_1234567890123456", "RelayClass": "future", "LocationLabel": "\u{202E}Tokyo, Japan"], "Recents": [["RelayID": "old", "CountryCode": "IR"]]])
        let result = try XCTUnwrap(EngineStateProjection(connected))
        XCTAssertEqual(result.sessionID, "session")
        XCTAssertEqual(result.relayName, "123456789012")
        XCTAssertEqual(result.location, "Tokyo, Japan")
        XCTAssertEqual(result.relayClass, "volunteer")
        XCTAssertNil(result.recent)
        var payload = connected.payload
        payload["Status"] = "connecting"
        let recovery = try XCTUnwrap(EngineStateProjection(EngineEvent(sequence: 2, kind: "state", payload: payload)))
        XCTAssertNil(recovery.location)
        XCTAssertNil(recovery.relayName)
        XCTAssertNil(recovery.relayClass)
    }

    func testSettingsKeepShippingIOSShapeAndProbePins() throws {
        let rules = SplitTunnelRules(bypassLan: true, bypassCountries: ["cn"], ruleSetDirectory: "/rules")
        let input = try JSONSerialization.jsonObject(with: Data(EngineTunnelSettings.json(rules: rules, debug: false).utf8)) as! [String: Any]
        let old = SingBoxConfiguration(relay: SingBoxBindingFixtures.relay(), splitTunnel: rules).bindingInput(debug: false)
        for key in ["tunnel_ipv4_address", "tunnel_ipv6_address", "mtu", "log_level", "probe_domain_suffixes"] {
            XCTAssertEqual(input[key] as? NSObject, old[key] as? NSObject)
        }
        XCTAssertNil(input["relay"])
        XCTAssertNil(input["route_find_process"])
        XCTAssertNil((input["split_tunnel"] as? [String: Any])?["excluded_packages"])
    }

    func testNetworkFingerprintIsStableAndKeepsCostAndDownTransitions() {
        func sample(_ interfaces: [String], up: Bool = true, expensive: Bool = false) -> EngineNetworkSnapshot {
            .make(up: up, interfaces: interfaces, supportsDNS: true, supportsIPv4: true, supportsIPv6: false, expensive: expensive, constrained: false)
        }
        XCTAssertEqual(sample(["wifi", "cell"]), sample(["cell", "wifi"]))
        XCTAssertNotEqual(sample(["wifi"]), sample(["wifi"], up: false))
        XCTAssertNotEqual(sample(["wifi"]), sample(["wifi"], expensive: true))
    }

    func testCancellationJoinsProbeCleanupBeforeReturning() {
        let entered = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var cancelled = false, cleaned = false
        let finished = expectation(description: "worker joined")
        DispatchQueue.global().async {
            do {
                try EngineOperationRunner.run(cancelled: { lock.lock(); defer { lock.unlock() }; return cancelled }) {
                defer { lock.lock(); cleaned = true; lock.unlock() }
                entered.signal()
                try await Task.sleep(nanoseconds: 60_000_000_000)
                }
                XCTFail("cancelled operation succeeded")
            } catch { XCTAssertTrue(error is CancellationError) }
            lock.lock(); let didClean = cleaned; lock.unlock()
            XCTAssertTrue(didClean)
            finished.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        lock.lock(); cancelled = true; lock.unlock()
        wait(for: [finished], timeout: 2)
    }

    func testNativeProbeFactsRetainFailureTaxonomyWithoutUnlockingLocalFailures() {
        let timeout = EngineProbeFailure.result(DnsPathUnverifiedError(underlying: URLError(.timedOut)), cancelled: false, ownsTunnel: true)
        XCTAssertEqual(timeout["remote_stage"] as? String, "dns_probe")
        XCTAssertEqual((timeout["failure_facts"] as? [String: Bool])?["timeout"], true)
        XCTAssertNil(EngineProbeFailure.result(URLError(.timedOut), cancelled: true, ownsTunnel: true)["remote_stage"])
        XCTAssertNil(EngineProbeFailure.result(URLError(.timedOut), cancelled: false, ownsTunnel: false)["remote_stage"])
        XCTAssertNil(EngineProbeFailure.result(PacketTunnelProbeTransportError.invalidConnectionState, cancelled: false, ownsTunnel: true)["remote_stage"])
    }

    func testPrecancelledOperationNeverStartsWorkAndUnknownFailuresStayLocal() {
        XCTAssertThrowsError(try EngineOperationRunner.run(cancelled: { true }) { XCTFail("started cancelled work") })
        XCTAssertFalse(isGenuineRemoteDataPathFailure(NSError(domain: NSPOSIXErrorDomain, code: Int.max)))
        XCTAssertFalse(isGenuineRemoteDataPathFailure(PacketTunnelEngineError.noOwner))
        XCTAssertFalse(isGenuineRemoteDataPathFailure(CancellationError()))
        XCTAssertTrue(isGenuineRemoteDataPathFailure(DnsPathUnverifiedError(underlying: URLError(.timedOut))))
    }
}
