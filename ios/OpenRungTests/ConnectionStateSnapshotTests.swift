import Foundation
import XCTest

final class ConnectionStateSnapshotTests: XCTestCase {
    /// Snapshots persisted by builds that predate `relayClass` decode without error and yield a
    /// nil class. Load-bearing: `SharedConnectionState.snapshot()` falls back to a blank state on
    /// any decode failure, so a throwing legacy decode would wipe the whole persisted state.
    func testDecodingLegacySnapshotWithoutRelayClassYieldsNil() throws {
        let snapshot = ConnectionStateSnapshot(
            status: .connected,
            brokerURL: "https://broker.example",
            relayLabel: "Tokyo, Japan",
            relayName: "Relay 7",
            relayClass: RelayConstants.nodeClassFoundation,
            lastError: nil,
            logLines: ["Connected"],
            recentRegions: [
                RecentNode(
                    countryCode: "JP",
                    relayId: "relay-7",
                    label: "Tokyo, Japan",
                    relayName: "Relay 7",
                    latitude: 36.2,
                    longitude: 138.25
                ),
            ]
        )
        let encoded = try JSONEncoder().encode(snapshot)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "relayClass")
        let legacy = try JSONDecoder().decode(
            ConnectionStateSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(legacy.relayClass)
        XCTAssertEqual(legacy.status, .connected)
        XCTAssertEqual(legacy.relayName, "Relay 7")
    }

    func testEncodeDecodeRoundTripPreservesRelayClass() throws {
        let snapshot = ConnectionStateSnapshot(
            status: .connected,
            brokerURL: "https://broker.example",
            relayName: "Relay 7",
            relayClass: RelayConstants.nodeClassVolunteer
        )
        let decoded = try JSONDecoder().decode(
            ConnectionStateSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        XCTAssertEqual(decoded.relayClass, RelayConstants.nodeClassVolunteer)
        XCTAssertEqual(decoded, snapshot)
    }

    func testSessionIdentityDecodesLegacyAndRoundTrips() throws {
        let legacy = try JSONDecoder().decode(ConnectionStateSnapshot.self,
            from: Data(#"{"status":"connected","relayName":"Relay 7"}"#.utf8))
        XCTAssertNil(legacy.sessionID)
        XCTAssertEqual(legacy.relayName, "Relay 7")
        let active = ConnectionStateSnapshot(status: .connected, sessionID: "engine-session")
        XCTAssertEqual(try JSONDecoder().decode(ConnectionStateSnapshot.self,
            from: JSONEncoder().encode(active)), active)
        XCTAssertNil(active.sanitizedForColdStart().sessionID)
    }

    func testSessionIdentityFollowsEngineRecoveryAndClearsOnTerminalTransitions() throws {
        var snapshot = ConnectionStateSnapshot()
        for (index, status) in ["connecting", "connected", "connecting", "connected"].enumerated() {
            let projection = try XCTUnwrap(EngineStateProjection(EngineEvent(sequence: UInt64(index + 1),
                kind: "state", payload: ["Status": status, "Details": ["SessionID": "engine-session"]])))
            snapshot.applyEngineState(projection)
            XCTAssertEqual(snapshot.sessionID, "engine-session")
            XCTAssertEqual(snapshot.status.rawValue, status)
        }
        snapshot.apply(status: .disconnecting)
        XCTAssertEqual(snapshot.sessionID, "engine-session")
        for status: ConnectionStatus in [.preparing, .disconnected, .failed] {
            var copy = snapshot
            copy.apply(status: status)
            XCTAssertNil(copy.sessionID)
        }
        var failure = snapshot
        failure.applyFailure("local start failure")
        XCTAssertNil(failure.sessionID)
        for status in ["disconnected", "failed"] {
            let terminal = try XCTUnwrap(EngineStateProjection(EngineEvent(sequence: 5, kind: "state",
                payload: ["Status": status, "Details": ["SessionID": "stale-session"]])))
            snapshot.applyEngineState(terminal)
            XCTAssertNil(snapshot.sessionID)
        }
        let noSession = try XCTUnwrap(EngineStateProjection(EngineEvent(sequence: 6, kind: "state",
            payload: ["Status": "connecting"])))
        snapshot.sessionID = "old-session"
        snapshot.applyEngineState(noSession)
        XCTAssertNil(snapshot.sessionID)
    }

    func testSystemTunnelReconciliationRejectsCrashedSessionAndLateReloads() {
        let persisted = ConnectionStateSnapshot(status: .connected, sessionID: "engine-session",
            relayLabel: "Tokyo", relayName: "Relay 7", relayClass: "volunteer")
        var app = persisted.sanitizedForColdStart()
        XCTAssertNil(app.sessionID)
        // Loading a still-live VPN restores identity without a new extension event.
        app = persisted
        app.reconcileSystemTunnel(isDown: false)
        XCTAssertEqual(app.sessionID, "engine-session")
        // A crash and then a delayed shared-state reload both consult the OS.
        for _ in 0..<2 {
            app = persisted
            app.reconcileSystemTunnel(isDown: true)
            XCTAssertNil(app.sessionID)
            XCTAssertEqual(app.status, .disconnected)
            XCTAssertNil(app.relayName)
            XCTAssertNil(app.relayClass)
            XCTAssertNil(app.relayLabel)
        }
        for status: ConnectionStatus in [.preparing, .connecting, .disconnecting, .disconnected, .failed] {
            app = ConnectionStateSnapshot(status: status, sessionID: "stale", lastError: "keep error")
            app.reconcileSystemTunnel(isDown: true)
            XCTAssertNil(app.sessionID)
            XCTAssertEqual(app.lastError, "keep error")
        }
    }

    func testEngineRecentsPromoteDedupeReplaceLegacyAndCap() throws {
        func node(_ id: String?, _ country: String = "JP") -> RecentNode {
            RecentNode(countryCode: country, relayId: id, label: "old", relayName: nil, latitude: 0, longitude: 0)
        }
        var snapshot = ConnectionStateSnapshot(recentRegions:
            [node(nil), node(""), node(" \t"), node("other"), node(nil, "US"), node("current")]
            + (0..<10).map { node("tail-\($0)", "DE") })
        let event = EngineEvent(sequence: 1, kind: "state", payload: ["Status": "connected",
            "Details": ["RelayID": "current", "RelayName": "New name", "LocationLabel": "Tokyo"],
            "Recents": [["RelayID": "current", "CountryCode": "JP", "Latitude": 35.0, "Longitude": 139.0]]])
        snapshot.applyEngineState(try XCTUnwrap(EngineStateProjection(event)))
        XCTAssertEqual(snapshot.recentRegions.count, AppConfig.maxRecents)
        XCTAssertEqual(snapshot.recentRegions.prefix(3).map(\.relayId), ["current", "other", nil])
        XCTAssertEqual(snapshot.recentRegions[2].countryCode, "US")
        XCTAssertEqual(snapshot.recentRegions[0].label, "Tokyo")
        XCTAssertEqual(snapshot.recentRegions[0].relayName, "New name")
        XCTAssertEqual(snapshot.recentRegions[0].latitude, 35)
        XCTAssertEqual(snapshot.recentRegions.last?.relayId, "tail-4")
    }

    func testEngineBuiltBlankRecentIsReplacedByPinnedRelay() throws {
        var snapshot = ConnectionStateSnapshot()
        for id in ["", "relay-new"] {
            let event = EngineEvent(sequence: 1, kind: "state", payload: ["Status": "connected",
                "Details": ["RelayID": id], "Recents": [["RelayID": id, "CountryCode": "JP"]]])
            snapshot.applyEngineState(try XCTUnwrap(EngineStateProjection(event)))
        }
        XCTAssertEqual(snapshot.recentRegions.map(\.relayId), ["relay-new"])
    }

    // MARK: - Pure lifecycle transitions (the rules SharedConnectionState persists)

    func testApplyKeepsRelayIdentityWhileConnectedAndClearsOnAnyOtherStatus() {
        var snapshot = ConnectionStateSnapshot()
        snapshot.apply(
            status: .connected,
            relayName: "Relay 7",
            relayClass: RelayConstants.nodeClassFoundation
        )
        XCTAssertEqual(snapshot.relayClass, RelayConstants.nodeClassFoundation)

        // A mid-session status re-assert with no arguments keeps the identity.
        snapshot.apply(status: .connected)
        XCTAssertEqual(snapshot.relayName, "Relay 7")
        XCTAssertEqual(snapshot.relayClass, RelayConstants.nodeClassFoundation)

        // Any non-connected status auto-clears both, with no explicit clearing arguments.
        snapshot.apply(status: .disconnecting)
        XCTAssertNil(snapshot.relayName)
        XCTAssertNil(snapshot.relayClass)
    }

    func testApplyFailureClearsRelayIdentity() {
        var snapshot = ConnectionStateSnapshot(
            status: .connected,
            relayLabel: "Tokyo, Japan",
            relayName: "Relay 7",
            relayClass: RelayConstants.nodeClassVolunteer
        )
        snapshot.applyFailure("broker unreachable")
        XCTAssertEqual(snapshot.status, .failed)
        XCTAssertEqual(snapshot.lastError, "broker unreachable")
        XCTAssertNil(snapshot.relayLabel)
        XCTAssertNil(snapshot.relayName)
        XCTAssertNil(snapshot.relayClass)
    }

    func testSanitizedForColdStartDropsStaleConnectionAndRelayDetails() {
        let stale = ConnectionStateSnapshot(
            status: .connected,
            relayLabel: "Tokyo, Japan",
            relayName: "Relay 7",
            relayClass: RelayConstants.nodeClassFoundation,
            logLines: ["Connected"]
        )
        let sanitized = stale.sanitizedForColdStart()
        XCTAssertEqual(sanitized.status, .disconnected)
        XCTAssertNil(sanitized.relayLabel)
        XCTAssertNil(sanitized.relayName)
        XCTAssertNil(sanitized.relayClass)
        XCTAssertEqual(sanitized.logLines, ["Connected"])
    }

    /// The connect-time stamp collapses anything that isn't explicitly foundation — unknown
    /// future classes included — to volunteer (the same rule as the TS directory builder).
    func testNormalizedNodeClassCollapsesUnknownClassesToVolunteer() {
        XCTAssertEqual(
            makeWssTestRelay(nodeClass: RelayConstants.nodeClassFoundation).normalizedNodeClass(),
            RelayConstants.nodeClassFoundation
        )
        XCTAssertEqual(
            makeWssTestRelay(nodeClass: RelayConstants.nodeClassVolunteer).normalizedNodeClass(),
            RelayConstants.nodeClassVolunteer
        )
        XCTAssertEqual(
            makeWssTestRelay(nodeClass: "sponsored").normalizedNodeClass(),
            RelayConstants.nodeClassVolunteer
        )
        XCTAssertEqual(
            makeWssTestRelay(nodeClass: "").normalizedNodeClass(),
            RelayConstants.nodeClassVolunteer
        )
    }
}
