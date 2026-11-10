import Foundation
import XCTest

/// The widget's read-only view of the tunnel snapshot, the face it renders, and the reload gate
/// that keeps WidgetKit requests to actual face changes.
final class WidgetSharedStateTests: XCTestCase {
    func testKeysMatchTheWriterSide() {
        XCTAssertEqual(WidgetSharedState.appGroupIdentifier, AppConfig.appGroupIdentifier)
        XCTAssertEqual(WidgetSharedState.connectionSnapshotKey, "connection_state")
    }

    func testReadsTheFaceOutOfAFullSnapshot() throws {
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

    // MARK: - What the connected face shows

    private func recent(_ country: String, _ name: String?) -> RecentNode {
        RecentNode(countryCode: country, relayId: "relay-1", label: "Somewhere", relayName: name, latitude: 0, longitude: 0)
    }

    func testConnectedSnapshotCarriesTheRelayAndItsCountry() throws {
        let snapshot = ConnectionStateSnapshot(
            status: .connected,
            brokerURL: "https://broker.example",
            relayLabel: "Ashburn, United States",
            relayName: "suave-mantis",
            recentRegions: [recent("us", "suave-mantis"), recent("JP", "calm-otter")]
        )
        let display = WidgetSharedState.display(fromSnapshotData: try JSONEncoder().encode(snapshot))
        XCTAssertEqual(display.face, .connected)
        XCTAssertEqual(display.relay?.name, "suave-mantis")
        XCTAssertEqual(display.relay?.countryCode, "US")
        XCTAssertEqual(display.relay?.flag, "🇺🇸")
        XCTAssertNil(display.since, "the snapshot carries no time; the gate's record does")
    }

    func testTheCountryIsTakenOnlyFromTheConnectedRelaysOwnRecentEntry() throws {
        // The head of the recents is another relay (this one was not recorded): no flag, not a wrong one.
        let snapshot = ConnectionStateSnapshot(
            status: .connected, brokerURL: "https://broker.example", relayName: "suave-mantis",
            recentRegions: [recent("JP", "calm-otter"), recent("US", "suave-mantis")]
        )
        let relay = WidgetSharedState.display(fromSnapshotData: try JSONEncoder().encode(snapshot)).relay
        XCTAssertEqual(relay?.name, "suave-mantis")
        XCTAssertNil(relay?.countryCode)
        XCTAssertNil(relay?.flag)
    }

    func testTheRelayIsShownOnlyOnTheConnectedFace() throws {
        let json = #"{"status":"connecting","relayName":"suave-mantis","recentRegions":[{"countryCode":"US","relayName":"suave-mantis"}]}"#
        let display = WidgetSharedState.display(fromSnapshotData: Data(json.utf8))
        XCTAssertEqual(display, WidgetDisplay(face: .connecting))
        XCTAssertNil(WidgetSharedState.display(fromSnapshotData: Data(#"{"status":"connected"}"#.utf8)).relay)
        XCTAssertNil(WidgetSharedState.display(fromSnapshotData: Data(#"{"status":"connected","relayName":"  "}"#.utf8)).relay)
    }

    func testAMalformedRelayOrRecentsNeverCostsTheStatus() {
        for json in [
            #"{"status":"connected","relayName":7,"recentRegions":"nope"}"#,
            #"{"status":"connected","relayName":"suave-mantis","recentRegions":[{"countryCode":12}]}"#,
            #"{"status":"connected","relayName":"suave-mantis","recentRegions":[7]}"#,
        ] {
            XCTAssertEqual(WidgetSharedState.face(fromSnapshotData: Data(json.utf8)), .connected, json)
        }
    }

    func testFlagNeedsATwoLetterCountry() {
        func relay(_ country: String) -> WidgetRelay? {
            WidgetRelay(name: "suave-mantis", recents: [.init(countryCode: country, relayName: "suave-mantis")])
        }
        XCTAssertEqual(relay("de")?.flag, "🇩🇪")
        XCTAssertEqual(relay(" JP ")?.flag, "🇯🇵")
        for bad in ["", "U", "USA", "U1", "ÜS"] {
            XCTAssertNil(relay(bad)?.countryCode, bad)
            XCTAssertNil(relay(bad)?.flag, bad)
        }
        XCTAssertNil(WidgetRelay(name: nil))
    }

    func testTheConnectedTimerStartsWhenTheTunnelEnteredTheFace() {
        let now = Date(timeIntervalSince1970: 10_000)
        let connected = WidgetDisplay(face: .connected, relay: WidgetRelay(name: "suave-mantis"))
        func resolve(lastFace: WidgetFace?, lastFaceAt: Double?) -> WidgetDisplay {
            WidgetSharedState.resolve(
                snapshot: connected, systemTunnelDown: false, disconnectRequestedAt: nil,
                lastFace: lastFace, lastFaceAt: lastFaceAt, now: now
            )
        }
        XCTAssertEqual(resolve(lastFace: .connected, lastFaceAt: 9_000).since, Date(timeIntervalSince1970: 9_000))
        XCTAssertEqual(resolve(lastFace: .connected, lastFaceAt: 9_000).relay?.name, "suave-mantis")
        XCTAssertNil(resolve(lastFace: .connecting, lastFaceAt: 9_000).since, "a record for another face says nothing")
        XCTAssertNil(resolve(lastFace: .connected, lastFaceAt: nil).since)
    }

    // MARK: - Disconnect from the widget

    func testAnUnansweredDisconnectIsScheduledToLapseInTheTimeline() {
        let now = Date(timeIntervalSince1970: 10_000)
        func display(at date: Date) -> WidgetDisplay {
            WidgetSharedState.resolve(
                snapshot: WidgetDisplay(face: .connected, relay: WidgetRelay(name: "suave-mantis")),
                systemTunnelDown: false, disconnectRequestedAt: 9_995,
                lastFace: .connected, lastFaceAt: 9_000, now: date
            )
        }
        let entries = WidgetSharedState.timelineDisplays(now: now, display: display(at:))
        XCTAssertEqual(entries.map(\.display.face), [.disconnecting, .connected])
        XCTAssertEqual(entries[0].date, now)
        XCTAssertGreaterThan(entries[1].date, Date(timeIntervalSince1970: 9_995 + WidgetDisconnectRequest.maxAge))
        XCTAssertEqual(entries[1].display.since, Date(timeIntervalSince1970: 9_000), "the timer resumes from the connect")
        XCTAssertEqual(entries[1].display.relay?.name, "suave-mantis")

        // Nothing pending: one entry, whatever the face.
        let settled = WidgetSharedState.timelineDisplays(now: now) { _ in WidgetDisplay(face: .connected) }
        XCTAssertEqual(settled.count, 1)
        let tunnelStopping = WidgetSharedState.timelineDisplays(now: now) { _ in WidgetDisplay(face: .disconnecting) }
        XCTAssertEqual(tunnelStopping.count, 1)
    }

    func testADisconnectRequestIsFreshOnlyBriefly() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(WidgetDisconnectRequest.isFresh(issuedAt: 10_000, now: now))
        XCTAssertTrue(WidgetDisconnectRequest.isFresh(issuedAt: 10_000 - WidgetDisconnectRequest.maxAge, now: now))
        XCTAssertFalse(WidgetDisconnectRequest.isFresh(issuedAt: 10_000 - WidgetDisconnectRequest.maxAge - 1, now: now))
        XCTAssertFalse(WidgetDisconnectRequest.isFresh(issuedAt: 10_001, now: now), "a request from the future is not one")
        XCTAssertFalse(WidgetDisconnectRequest.isFresh(issuedAt: nil, now: now))
    }

    func testAPendingDisconnectReadsAsDisconnectingUntilItGoesStale() {
        let now = Date(timeIntervalSince1970: 10_000)
        let connected = WidgetDisplay(face: .connected, relay: WidgetRelay(name: "suave-mantis"))
        func resolve(_ snapshot: WidgetDisplay, requestedAt: Double?, down: Bool = false) -> WidgetDisplay {
            WidgetSharedState.resolve(
                snapshot: snapshot, systemTunnelDown: down, disconnectRequestedAt: requestedAt,
                lastFace: .connected, lastFaceAt: 9_000, now: now
            )
        }
        let pending = resolve(connected, requestedAt: 9_998)
        XCTAssertEqual(pending.face, .disconnecting)
        XCTAssertNil(pending.relay)
        XCTAssertEqual(pending.since, Date(timeIntervalSince1970: 9_998), "paces the refresh from the tap")
        XCTAssertEqual(pending.expires, Date(timeIntervalSince1970: 9_998 + WidgetDisconnectRequest.maxAge))
        XCTAssertNil(resolve(connected, requestedAt: nil).expires, "what the tunnel reports does not expire")
        // The tunnel never answered: back to what the snapshot says.
        XCTAssertEqual(resolve(connected, requestedAt: 9_000).face, .connected)
        // Only a connected tunnel has anything pending.
        XCTAssertEqual(resolve(WidgetDisplay(face: .disconnected), requestedAt: 9_998).face, .disconnected)
        XCTAssertEqual(resolve(WidgetDisplay(face: .connecting), requestedAt: 9_998).face, .connecting)
        // The app's stale-tunnel marker still wins.
        XCTAssertEqual(resolve(connected, requestedAt: 9_998, down: true), WidgetDisplay(face: .disconnected))
    }

    func testDisconnectRequestKeyIsTheWidgetsOwn() {
        XCTAssertEqual(WidgetSharedState.disconnectRequestKey, "widget_disconnect_request")
        XCTAssertNotEqual(WidgetSharedState.disconnectRequestKey, WidgetSharedState.connectionSnapshotKey)
        XCTAssertNotEqual(WidgetSharedState.disconnectNotificationName, AppConfig.darwinNotificationName)
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

    func testReloadGateReloadsAConnectedFaceWhenItsRelayChanges() {
        var storedFace: WidgetFace? = .connecting
        var storedRelay: String?
        var faceWrites = 0
        var reloads = 0
        let gate = WidgetReloadGate(
            readLastFace: { storedFace },
            writeLastFace: { storedFace = $0; faceWrites += 1 },
            readLastRelay: { storedRelay },
            writeLastRelay: { storedRelay = $0 },
            readRenderedFace: { nil },
            clearStaleTunnelMarker: {},
            reload: { reloads += 1 }
        )
        func connected(_ name: String?, _ country: String = "US") -> WidgetDisplay {
            WidgetDisplay(face: .connected, relay: WidgetRelay(
                name: name, recents: [.init(countryCode: country, relayName: name)]
            ))
        }
        XCTAssertTrue(gate.publish(connected("suave-mantis")))
        XCTAssertEqual(storedRelay, "suave-mantis|US")
        XCTAssertFalse(gate.publish(connected("suave-mantis")), "log-line rewrites change nothing")
        XCTAssertTrue(gate.publish(connected("calm-otter", "JP")), "same face, another relay")
        XCTAssertEqual(faceWrites, 1, "a relay change does not restart the connected timer")
        XCTAssertTrue(gate.publish(statusRawValue: "disconnecting"))
        XCTAssertNil(storedRelay, "no relay is recorded off the connected face")
        XCTAssertFalse(gate.publish(statusRawValue: "disconnecting"))
        XCTAssertEqual(reloads, 3)
    }

    func testReloadGateReadsTheSnapshotTheWayTheWidgetDoes() throws {
        var storedFace: WidgetFace?
        var storedRelay: String?
        let gate = WidgetReloadGate(
            readLastFace: { storedFace },
            writeLastFace: { storedFace = $0 },
            readLastRelay: { storedRelay },
            writeLastRelay: { storedRelay = $0 },
            readRenderedFace: { nil },
            clearStaleTunnelMarker: {},
            reload: {}
        )
        let snapshot = ConnectionStateSnapshot(
            status: .connected, brokerURL: "https://broker.example", relayName: "suave-mantis",
            recentRegions: [recent("US", "suave-mantis")]
        )
        XCTAssertTrue(gate.publish(snapshotData: try JSONEncoder().encode(snapshot)))
        XCTAssertEqual(storedFace, .connected)
        XCTAssertEqual(storedRelay, "suave-mantis|US")
    }

    func testReloadGateSkipsTheDisconnectingFaceTheWidgetShowedForItsOwnTap() {
        // The widget rendered its pending Disconnect as "disconnecting" before the tunnel said so.
        var stored: WidgetFace? = .connected
        var reloads = 0
        let gate = WidgetReloadGate(
            readLastFace: { stored },
            writeLastFace: { stored = $0 },
            readRenderedFace: { .disconnecting },
            clearStaleTunnelMarker: {},
            reload: { reloads += 1 }
        )
        XCTAssertFalse(gate.publish(statusRawValue: "disconnecting"))
        XCTAssertTrue(gate.publish(statusRawValue: "disconnected"))
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
