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
            readRenderedFace: { nil },
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
            readRenderedFace: { nil },
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
            readLastFace: { stored },
            writeLastFace: { stored = $0 },
            readRenderedFace: { nil },
            clearStaleTunnelMarker: {},
            reload: { reloads += 1 }
        )
        XCTAssertFalse(gate.publish(statusRawValue: "connected"))
        XCTAssertEqual(reloads, 0)
    }

    func testReloadGateSkipsAFaceTheWidgetAlreadyRendered() {
        // The app's catch-up got "connected" rendered before the tunnel's own flush for it.
        var stored: WidgetFace? = .connecting
        var reloads = 0
        let gate = WidgetReloadGate(
            readLastFace: { stored },
            writeLastFace: { stored = $0 },
            readRenderedFace: { .connected },
            clearStaleTunnelMarker: {},
            reload: { reloads += 1 }
        )
        XCTAssertFalse(gate.publish(statusRawValue: "connected"))
        XCTAssertEqual(stored, .connected, "the request is still recorded as made")
        XCTAssertEqual(reloads, 0)
        XCTAssertTrue(gate.publish(statusRawValue: "disconnecting"), "a face not yet rendered reloads")
        XCTAssertEqual(reloads, 1)
    }

    // MARK: - App-side catch-up (WidgetKit defers reloads requested while the app is not in front)

    func testCatchUpRequestsAReloadOnlyWhileTheRenderedFaceLags() {
        // Connect from the app, quit while connecting: the tunnel's "connected" request was
        // deferred, the widget still shows connecting. The app comes back and asks once.
        var rendered: WidgetFace? = .connecting
        var reloads = 0
        var catchUp = WidgetRenderCatchUp(readRenderedFace: { rendered }, reload: { reloads += 1 })
        XCTAssertTrue(catchUp.publish(currentFace: .connected))
        XCTAssertFalse(catchUp.publish(currentFace: .connected), "same face is never asked for twice")
        XCTAssertEqual(reloads, 1)
        rendered = .connected
        XCTAssertFalse(catchUp.publish(currentFace: .connected), "rendered: nothing to do")
        XCTAssertTrue(catchUp.publish(currentFace: .disconnecting), "a new lag asks again")
        XCTAssertEqual(reloads, 2)
    }

    func testCatchUpAsksAgainAfterAnActivation() {
        var reloads = 0
        var catchUp = WidgetRenderCatchUp(readRenderedFace: { .connecting }, reload: { reloads += 1 })
        XCTAssertTrue(catchUp.publish(currentFace: .connected))
        XCTAssertFalse(catchUp.publish(currentFace: .connected))
        catchUp.resetForActivation()
        XCTAssertTrue(catchUp.publish(currentFace: .connected), "a deferred request is worth repeating in front")
        XCTAssertEqual(reloads, 2)
    }

    func testCatchUpWithNoWidgetEverRenderedAsksOncePerFace() {
        var reloads = 0
        var catchUp = WidgetRenderCatchUp(readRenderedFace: { nil }, reload: { reloads += 1 })
        XCTAssertTrue(catchUp.publish(currentFace: .connecting))
        XCTAssertFalse(catchUp.publish(currentFace: .connecting), "log-line refreshes cost nothing")
        XCTAssertTrue(catchUp.publish(currentFace: .connected))
        XCTAssertEqual(reloads, 2)
    }

    // MARK: - The widget's own refresh of a transitional face

    func testSettledFacesNeverSelfRefresh() {
        for face in [WidgetFace.disconnected, .connected, .failed] {
            XCTAssertFalse(face.isTransitional)
            XCTAssertNil(WidgetSelfRefresh.delay(for: face, age: 0))
            XCTAssertNil(WidgetSelfRefresh.delay(for: face, age: nil))
        }
    }

    func testTransitionalFacesRefreshQuicklyThenBackOff() {
        for face in [WidgetFace.connecting, .disconnecting] {
            XCTAssertTrue(face.isTransitional)
            XCTAssertEqual(WidgetSelfRefresh.delay(for: face, age: 0), WidgetSelfRefresh.earlyDelay)
            XCTAssertEqual(WidgetSelfRefresh.delay(for: face, age: 59), WidgetSelfRefresh.earlyDelay)
            XCTAssertEqual(WidgetSelfRefresh.delay(for: face, age: 60), WidgetSelfRefresh.midDelay)
            XCTAssertEqual(WidgetSelfRefresh.delay(for: face, age: 599), WidgetSelfRefresh.midDelay)
            XCTAssertEqual(WidgetSelfRefresh.delay(for: face, age: 600), WidgetSelfRefresh.lateDelay)
            XCTAssertEqual(WidgetSelfRefresh.delay(for: face, age: 86_400), WidgetSelfRefresh.lateDelay)
        }
    }

    func testAnUnknownOrFutureAgeTakesTheSlowestPace() {
        XCTAssertEqual(WidgetSelfRefresh.delay(for: .connecting, age: nil), WidgetSelfRefresh.lateDelay)
        XCTAssertEqual(WidgetSelfRefresh.delay(for: .connecting, age: -5), WidgetSelfRefresh.lateDelay)
    }

    func testASelfRefreshingTunnelStuckInTransitionStaysWithinTheReloadBudget() {
        // Walk a day of a tunnel that never leaves "connecting".
        var age: TimeInterval = 0
        var reloads = 0
        while age < 86_400, let delay = WidgetSelfRefresh.delay(for: .connecting, age: age) {
            age += delay
            reloads += 1
        }
        XCTAssertLessThanOrEqual(reloads, 40)
    }

    func testRenderedFaceKeyIsTheWidgetsOwn() {
        XCTAssertEqual(WidgetSharedState.renderedFaceKey, "widget_rendered_face")
        XCTAssertNotEqual(WidgetSharedState.renderedFaceKey, WidgetSharedState.lastPublishedFaceKey)
    }
}
