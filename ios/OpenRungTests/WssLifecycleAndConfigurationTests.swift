import Foundation
import XCTest

final class WssLifecycleAndConfigurationTests: XCTestCase {
    func testBridgeChangesOnlyRealityTransportEndpointAndKeepsLoopbackInsideTun() throws {
        let relay = makeWssTestRelay()
        let direct = SingBoxConfiguration(relay: relay).makeJSONObject()
        let bridged = SingBoxConfiguration(
            relay: relay,
            bridgeHost: "127.0.0.1",
            bridgePort: 24_680
        ).makeJSONObject()

        var directOutbound = try firstOutbound(direct)
        var bridgedOutbound = try firstOutbound(bridged)
        XCTAssertEqual(directOutbound["server"] as? String, relay.publicHost)
        XCTAssertEqual(directOutbound["server_port"] as? Int, relay.publicPort)
        XCTAssertEqual(bridgedOutbound["server"] as? String, "127.0.0.1")
        XCTAssertEqual(bridgedOutbound["server_port"] as? Int, 24_680)
        directOutbound.removeValue(forKey: "server")
        directOutbound.removeValue(forKey: "server_port")
        bridgedOutbound.removeValue(forKey: "server")
        bridgedOutbound.removeValue(forKey: "server_port")
        XCTAssertEqual(try canonicalJSON(directOutbound), try canonicalJSON(bridgedOutbound))

        let directTun = try firstInbound(direct)
        let bridgedTun = try firstInbound(bridged)
        XCTAssertEqual(directTun["route_exclude_address"] as? [String], ["203.0.113.10/32"])
        XCTAssertNil(bridgedTun["route_exclude_address"])
    }

    func testDescriptorDefaultsLegacyFieldsAndPreservesSignedFrontOrder() throws {
        let relay = makeWssTestRelay()
        let encoded = try JSONEncoder().encode(relay)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "node_class")
        object.removeValue(forKey: "transport")
        object.removeValue(forKey: "wss_fronts")
        object["future_broker_field"] = "ignored"
        let legacy = try JSONDecoder().decode(
            RelayDescriptor.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(legacy.nodeClass, RelayConstants.nodeClassVolunteer)
        XCTAssertEqual(legacy.transport, "")
        XCTAssertEqual(legacy.wssFronts, [])

        let signed = try JSONDecoder().decode(RelayDescriptor.self, from: encoded)
        XCTAssertEqual(signed.nodeClass, RelayConstants.nodeClassFoundation)
        XCTAssertEqual(signed.wssFronts, wssTestFronts)

        var strictObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var strictFronts = try XCTUnwrap(strictObject["wss_fronts"] as? [[String: Any]])
        strictFronts[0]["ticket"] = "must-not-be-discarded"
        strictObject["wss_fronts"] = strictFronts
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                RelayDescriptor.self,
                from: JSONSerialization.data(withJSONObject: strictObject)
            )
        )
    }

    func testNetworkEpochTrackerIgnoresOnlyBaselineAndTreatsEveryLaterUpdateAsANewEpoch() {
        var tracker = NetworkEpochTracker<PhysicalNetworkFingerprint>()
        let wifi = fingerprint(interface: "en0:wifi:4", satisfied: true)
        let cellular = fingerprint(interface: "pdp_ip0:cellular:7", satisfied: true)
        let offline = fingerprint(interface: "", satisfied: false)

        XCTAssertFalse(tracker.absorb(wifi))
        XCTAssertTrue(tracker.absorb(wifi))
        XCTAssertTrue(tracker.absorb(cellular))
        XCTAssertTrue(tracker.absorb(offline))
        XCTAssertTrue(tracker.absorb(offline))
    }

    func testHealthThresholdRequiresThreeConsecutiveRemoteFailuresAndResetsOnSuccess() {
        var threshold = TunnelHealthFailureThreshold(requiredFailures: 3)
        XCTAssertFalse(threshold.recordRemoteFailure())
        XCTAssertFalse(threshold.recordRemoteFailure())
        threshold.recordSuccess()
        XCTAssertEqual(threshold.consecutiveFailures, 0)
        XCTAssertFalse(threshold.recordRemoteFailure())
        XCTAssertFalse(threshold.recordRemoteFailure())
        XCTAssertTrue(threshold.recordRemoteFailure())
        XCTAssertTrue(threshold.recordRemoteFailure())
    }

    func testOnlyPositiveRemoteFailuresQualifyForFallbackOrHealthRecovery() {
        XCTAssertTrue(isGenuineRemoteDataPathFailure(URLError(.timedOut)))
        XCTAssertTrue(isGenuineRemoteDataPathFailure(URLError(.networkConnectionLost)))
        XCTAssertTrue(isGenuineRemoteDataPathFailure(InternetProbeError.unreachable(URLError(.dnsLookupFailed))))
        XCTAssertFalse(isGenuineRemoteDataPathFailure(URLError(.dataNotAllowed)))
        XCTAssertFalse(isGenuineRemoteDataPathFailure(URLError(.badURL)))
        XCTAssertFalse(isGenuineRemoteDataPathFailure(RelayReachabilityError.invalidPort))
        XCTAssertFalse(
            isGenuineRemoteDataPathFailure(PacketTunnelProbeTransportError.invalidConnectionState)
        )
        XCTAssertFalse(isGenuineRemoteDataPathFailure(NSError(domain: "local.platform", code: 1)))
    }

    func testNativeClientFrontAndAdapterReasonsAreLocalButTransportIsNot() {
        XCTAssertTrue(WssNativeClientError.unavailable.isLocalFailure)
        XCTAssertTrue(WssNativeClientError.creationFailed.isLocalFailure)
        XCTAssertTrue(WssNativeClientError.invalidLoopbackEndpoint.isLocalFailure)
        XCTAssertTrue(WssNativeClientError.connectionFailed(reason: "client").isLocalFailure)
        XCTAssertTrue(WssNativeClientError.connectionFailed(reason: "front").isLocalFailure)
        XCTAssertTrue(WssNativeClientError.connectionFailed(reason: "adapter").isLocalFailure)
        XCTAssertTrue(WssNativeClientError.connectionFailed(reason: "protect").isLocalFailure)
        XCTAssertFalse(WssNativeClientError.connectionFailed(reason: "transport").isLocalFailure)
    }

    private func firstOutbound(_ object: [String: Any]) throws -> [String: Any] {
        let outbounds = try XCTUnwrap(object["outbounds"] as? [[String: Any]])
        return try XCTUnwrap(outbounds.first)
    }

    private func firstInbound(_ object: [String: Any]) throws -> [String: Any] {
        let inbounds = try XCTUnwrap(object["inbounds"] as? [[String: Any]])
        return try XCTUnwrap(inbounds.first)
    }

    private func canonicalJSON(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func fingerprint(interface: String, satisfied: Bool) -> PhysicalNetworkFingerprint {
        PhysicalNetworkFingerprint(
            satisfied: satisfied,
            interfaces: interface.isEmpty ? [] : [interface],
            supportsDNS: satisfied,
            supportsIPv4: satisfied,
            supportsIPv6: false,
            isExpensive: interface.contains("cellular"),
            isConstrained: false
        )
    }
}
