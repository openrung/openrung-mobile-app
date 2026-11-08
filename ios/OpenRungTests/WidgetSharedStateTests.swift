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

    func testStaleTunnelMarkerOverridesALiveSnapshotFaceToDisconnected() throws {
        let data = try JSONEncoder().encode(ConnectionStateSnapshot(status: .connected, brokerURL: "https://broker.example"))
        XCTAssertEqual(WidgetSharedState.face(fromSnapshotData: data, systemTunnelDown: false), .connected)
        XCTAssertEqual(WidgetSharedState.face(fromSnapshotData: data, systemTunnelDown: true), .disconnected)
        XCTAssertEqual(WidgetSharedState.face(fromSnapshotData: nil, systemTunnelDown: true), .disconnected)
    }

    func testStaleTunnelMarkerAppliesOnlyToALiveSnapshotWithTheOSTunnelDown() {
        XCTAssertTrue(WidgetStaleTunnelMarker.applies(systemTunnelIsDown: true, snapshotFace: .connected))
        XCTAssertTrue(WidgetStaleTunnelMarker.applies(systemTunnelIsDown: true, snapshotFace: .connecting))
        for face: WidgetFace in [.disconnected, .disconnecting, .failed] {
            XCTAssertFalse(WidgetStaleTunnelMarker.applies(systemTunnelIsDown: true, snapshotFace: face), "\(face)")
        }
        XCTAssertFalse(WidgetStaleTunnelMarker.applies(systemTunnelIsDown: false, snapshotFace: .connected))
    }

    func testStaleTunnelMarkerIsSetOnceAndReloadsOnce() {
        var marker = false
        var reloads = 0
        let publisher = WidgetStaleTunnelMarker(readMarker: { marker }, writeMarker: { marker = true }, reload: { reloads += 1 })
        XCTAssertFalse(publisher.publish(systemTunnelIsDown: false, snapshotFace: .connected))
        XCTAssertFalse(marker)
        XCTAssertTrue(publisher.publish(systemTunnelIsDown: true, snapshotFace: .connected))
        XCTAssertFalse(publisher.publish(systemTunnelIsDown: true, snapshotFace: .connected), "deduplicated on the stored value")
        XCTAssertFalse(publisher.publish(systemTunnelIsDown: true, snapshotFace: .connecting))
        XCTAssertTrue(marker)
        XCTAssertEqual(reloads, 1)
    }

    /// The launch that matters: the extension died while connected, the app loads its manager and
    /// refreshes once. That first publish must set the marker and reload the widget.
    func testStaleTunnelMarkerIsSetOnTheFirstRefreshAfterLaunch() throws {
        var marker = false
        var reloads = 0
        let publisher = WidgetStaleTunnelMarker(readMarker: { marker }, writeMarker: { marker = true }, reload: { reloads += 1 })
        let data = try JSONEncoder().encode(ConnectionStateSnapshot(status: .connected, brokerURL: "https://broker.example"))
        let snapshotFace = WidgetSharedState.face(fromSnapshotData: data)
        XCTAssertTrue(publisher.publish(systemTunnelIsDown: true, snapshotFace: snapshotFace))
        XCTAssertTrue(marker)
        XCTAssertEqual(reloads, 1)
        XCTAssertEqual(WidgetSharedState.face(fromSnapshotData: data, systemTunnelDown: marker), .disconnected)
    }

    func testEveryTunnelFlushClearsTheStaleTunnelMarker() {
        var stored: WidgetFace? = .connected
        var cleared = 0
        let gate = WidgetReloadGate(
            readLastFace: { stored },
            writeLastFace: { stored = $0 },
            clearStaleTunnelMarker: { cleared += 1 },
            reload: {}
        )
        XCTAssertFalse(gate.publish(statusRawValue: "connected"), "same face: no reload")
        XCTAssertTrue(gate.publish(statusRawValue: "preparing"))
        XCTAssertEqual(cleared, 2, "cleared on every flush, reload or not")
    }

    func testReloadGateRequestsAReloadOnlyWhenTheFaceChanges() {
        var stored: WidgetFace?
        var reloads = 0
        let gate = WidgetReloadGate(
            readLastFace: { stored },
            writeLastFace: { stored = $0 },
            clearStaleTunnelMarker: {},
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
        let gate = WidgetReloadGate(
            readLastFace: { stored }, writeLastFace: { stored = $0 }, clearStaleTunnelMarker: {}, reload: { reloads += 1 }
        )
        XCTAssertFalse(gate.publish(statusRawValue: "connected"))
        XCTAssertEqual(reloads, 0)
    }
}
