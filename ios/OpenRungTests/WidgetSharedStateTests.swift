import Foundation
import XCTest

/// The widget's read-only view of the tunnel snapshot, the face it renders, and the reload gate
/// that keeps WidgetKit requests to actual face changes.
final class WidgetSharedStateTests: XCTestCase {
    func testKeysMatchTheWriterSide() {
        XCTAssertEqual(WidgetSharedState.appGroupIdentifier, AppConfig.appGroupIdentifier)
        XCTAssertEqual(WidgetSharedState.connectionSnapshotKey, "connection_state")
    }

    func testReadsOnlyTheStatusOutOfAFullSnapshot() throws {
        let snapshot = ConnectionStateSnapshot(
            status: .connected,
            brokerURL: "https://broker.example",
            relayLabel: "Tokyo, Japan",
            relayName: "Relay 7",
            logLines: ["Connected"]
        )
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(WidgetSharedState.face(fromSnapshotData: data), .connected)
    }

    func testMissingOrUndecodableSnapshotReadsAsDisconnected() {
        XCTAssertEqual(WidgetSharedState.face(fromSnapshotData: nil), .disconnected)
        XCTAssertEqual(WidgetSharedState.face(fromSnapshotData: Data("not json".utf8)), .disconnected)
        XCTAssertEqual(WidgetSharedState.face(fromSnapshotData: Data(#"{"brokerURL":"x"}"#.utf8)), .disconnected)
        XCTAssertEqual(WidgetSharedState.face(fromSnapshotData: Data(#"{"status":"teleporting"}"#.utf8)), .disconnected)
    }

    func testFaceCoversEveryStatusAndCollapsesPreparingIntoConnecting() {
        let expected: [ConnectionStatus: WidgetFace] = [
            .disconnected: .disconnected, .preparing: .connecting, .connecting: .connecting,
            .connected: .connected, .disconnecting: .disconnecting, .failed: .failed,
        ]
        for (status, face) in expected {
            XCTAssertEqual(WidgetFace(statusRawValue: status.rawValue), face, status.rawValue)
        }
        XCTAssertEqual(WidgetFace(statusRawValue: ""), .disconnected)
    }

    func testConnectIsOfferedOnlyWhenNothingIsRunning() {
        XCTAssertTrue(WidgetFace.disconnected.offersConnect)
        XCTAssertTrue(WidgetFace.failed.offersConnect)
        XCTAssertFalse(WidgetFace.connecting.offersConnect)
        XCTAssertFalse(WidgetFace.connected.offersConnect)
        XCTAssertFalse(WidgetFace.disconnecting.offersConnect)
    }

    func testReloadGateRequestsAReloadOnlyWhenTheFaceChanges() {
        var stored: WidgetFace?
        var reloads = 0
        let gate = WidgetReloadGate(
            readLastFace: { stored },
            writeLastFace: { stored = $0 },
            reload: { reloads += 1 }
        )
        XCTAssertTrue(gate.publish(statusRawValue: "preparing"))
        XCTAssertFalse(gate.publish(statusRawValue: "connecting"), "same face as preparing")
        XCTAssertFalse(gate.publish(statusRawValue: "connecting"), "log-line rewrites change nothing")
        XCTAssertTrue(gate.publish(statusRawValue: "connected"))
        XCTAssertFalse(gate.publish(statusRawValue: "connected"))
        XCTAssertTrue(gate.publish(statusRawValue: "disconnecting"))
        XCTAssertTrue(gate.publish(statusRawValue: "disconnected"))
        XCTAssertEqual(reloads, 4)
        XCTAssertEqual(stored, .disconnected)
    }

    func testReloadGateHonoursAFacePersistedByAnEarlierProcess() {
        var stored: WidgetFace? = .connected
        var reloads = 0
        let gate = WidgetReloadGate(readLastFace: { stored }, writeLastFace: { stored = $0 }, reload: { reloads += 1 })
        XCTAssertFalse(gate.publish(statusRawValue: "connected"))
        XCTAssertEqual(reloads, 0)
    }
}
