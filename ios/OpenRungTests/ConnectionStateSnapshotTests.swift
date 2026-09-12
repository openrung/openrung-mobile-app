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
