import Foundation
import XCTest

final class BridgeConfigurationTests: XCTestCase {
    func testBridgeChangesOnlyRealityTransportEndpointAndKeepsLoopbackInsideTun() throws {
        // The frozen bound outputs for the direct and bridged shapes (see SingBoxBindingFixtures).
        let relay = SingBoxBindingFixtures.relay()
        let direct = try SingBoxBindingFixtures.golden("ios-tun")
        let bridged = try SingBoxBindingFixtures.golden("ios-bridge")

        var directOutbound = try firstOutbound(direct)
        var bridgedOutbound = try firstOutbound(bridged)
        XCTAssertEqual(directOutbound["server"] as? String, relay.publicHost)
        XCTAssertEqual(directOutbound["server_port"] as? Int, relay.publicPort)
        XCTAssertEqual(bridgedOutbound["server"] as? String, "127.0.0.1")
        XCTAssertEqual(bridgedOutbound["server_port"] as? Int, 54_321)
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

}
