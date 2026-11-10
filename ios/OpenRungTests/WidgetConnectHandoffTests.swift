import Foundation
import NetworkExtension
import XCTest

/// The widget → app handoff: what may start a tunnel, how long a tap stays valid, how repeat taps
/// collapse, and which URLs count as a connect request. Hostless; no WidgetKit or React.
final class WidgetConnectHandoffTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Policy

    func testStartsOnlyFromAFullyDownTunnel() {
        XCTAssertEqual(WidgetConnectPolicy.decide(sharedStatus: .disconnected, systemTunnel: .down), .start)
        XCTAssertEqual(WidgetConnectPolicy.decide(sharedStatus: .failed, systemTunnel: .down), .start)
    }

    func testNeverTouchesASharedStateInMotion() {
        for status: ConnectionStatus in [.preparing, .connecting, .connected, .disconnecting] {
            XCTAssertEqual(
                WidgetConnectPolicy.decide(sharedStatus: status, systemTunnel: .down),
                .ignore(.sharedStateBusy),
                "\(status)"
            )
        }
    }

    func testNeverTouchesALiveSystemTunnelWhateverTheSnapshotSays() {
        XCTAssertEqual(
            WidgetConnectPolicy.decide(sharedStatus: .disconnected, systemTunnel: .live),
            .ignore(.systemTunnelLive)
        )
        XCTAssertEqual(
            WidgetConnectPolicy.decide(sharedStatus: .failed, systemTunnel: .live),
            .ignore(.systemTunnelLive)
        )
    }

    func testSystemTunnelMappingTreatsEveryTransitionalStateAsLive() {
        XCTAssertEqual(WidgetConnectPolicy.SystemTunnel(.invalid), .down)
        XCTAssertEqual(WidgetConnectPolicy.SystemTunnel(.disconnected), .down)
        for status: NEVPNStatus in [.connecting, .connected, .reasserting, .disconnecting] {
            XCTAssertEqual(WidgetConnectPolicy.SystemTunnel(status), .live, "\(status.rawValue)")
        }
    }

    // MARK: - Mailbox freshness and duplicate collapsing

    func testFreshRequestIsCollectedOnce() {
        let mailbox = WidgetConnectMailbox()
        let request = WidgetConnectRequest(source: .intent, issuedAt: epoch)
        XCTAssertTrue(mailbox.submit(request))
        XCTAssertEqual(mailbox.collect(now: epoch.addingTimeInterval(2)), request)
        XCTAssertNil(mailbox.collect(now: epoch.addingTimeInterval(3)))
    }

    func testStaleRequestIsDroppedNotActedOn() {
        let mailbox = WidgetConnectMailbox()
        mailbox.submit(WidgetConnectRequest(source: .url, issuedAt: epoch))
        XCTAssertNil(mailbox.collect(now: epoch.addingTimeInterval(WidgetConnectMailbox.maxAge + 1)))
        XCTAssertNil(mailbox.collect(now: epoch.addingTimeInterval(WidgetConnectMailbox.maxAge + 2)), "dropped, not kept")
    }

    func testRequestAtTheFreshnessBoundaryStillCounts() {
        let mailbox = WidgetConnectMailbox()
        let request = WidgetConnectRequest(source: .url, issuedAt: epoch)
        mailbox.submit(request)
        XCTAssertEqual(mailbox.collect(now: epoch.addingTimeInterval(WidgetConnectMailbox.maxAge)), request)
    }

    func testDuplicateDeliveriesOfOneTapCollapseWhilePending() {
        let mailbox = WidgetConnectMailbox()
        let first = WidgetConnectRequest(source: .intent, issuedAt: epoch)
        XCTAssertTrue(mailbox.submit(first))
        XCTAssertFalse(mailbox.submit(WidgetConnectRequest(source: .url, issuedAt: epoch.addingTimeInterval(0.2))))
        XCTAssertFalse(mailbox.submit(WidgetConnectRequest(source: .intent, issuedAt: epoch.addingTimeInterval(5))))
        XCTAssertEqual(mailbox.collect(now: epoch.addingTimeInterval(6)), first)
        XCTAssertNil(mailbox.collect(now: epoch.addingTimeInterval(6)))
    }

    func testRetapRightAfterCollectionIsTheSameTap() {
        let mailbox = WidgetConnectMailbox()
        mailbox.submit(WidgetConnectRequest(source: .intent, issuedAt: epoch))
        XCTAssertNotNil(mailbox.collect(now: epoch.addingTimeInterval(1)))
        XCTAssertFalse(mailbox.submit(WidgetConnectRequest(
            source: .intent,
            issuedAt: epoch.addingTimeInterval(1 + WidgetConnectMailbox.collapseWindow - 0.5)
        )))
        XCTAssertNil(mailbox.collect(now: epoch.addingTimeInterval(4)))
    }

    func testTapAfterTheCollapseWindowIsANewRequest() {
        let mailbox = WidgetConnectMailbox()
        mailbox.submit(WidgetConnectRequest(source: .intent, issuedAt: epoch))
        XCTAssertNotNil(mailbox.collect(now: epoch.addingTimeInterval(1)))
        let later = WidgetConnectRequest(source: .intent, issuedAt: epoch.addingTimeInterval(1 + WidgetConnectMailbox.collapseWindow))
        XCTAssertTrue(mailbox.submit(later))
        XCTAssertEqual(mailbox.collect(now: later.issuedAt.addingTimeInterval(1)), later)
    }

    func testANewTapReplacesAnUncollectedStaleOne() {
        // JS never came up for the first tap; a tap a minute later must not be swallowed by it.
        let mailbox = WidgetConnectMailbox()
        mailbox.submit(WidgetConnectRequest(source: .intent, issuedAt: epoch))
        let later = WidgetConnectRequest(source: .intent, issuedAt: epoch.addingTimeInterval(60))
        XCTAssertTrue(mailbox.submit(later))
        XCTAssertEqual(mailbox.collect(now: later.issuedAt.addingTimeInterval(1)), later)
    }

    func testSubmitNotifiesTheConsumerOnlyForAcceptedRequests() {
        let mailbox = WidgetConnectMailbox()
        var notifications = 0
        mailbox.onSubmit = { notifications += 1 }
        mailbox.submit(WidgetConnectRequest(source: .intent, issuedAt: epoch))
        mailbox.submit(WidgetConnectRequest(source: .intent, issuedAt: epoch.addingTimeInterval(1)))
        XCTAssertEqual(notifications, 1)
    }

    // MARK: - URL scheme

    func testAcceptsExactlyTheConnectURL() {
        XCTAssertTrue(WidgetConnectURL.isConnectRequest(WidgetConnectURL.connect))
        XCTAssertTrue(WidgetConnectURL.isConnectRequest(URL(string: "OPENRUNG://Connect")!))
    }

    func testRejectsEverythingThatCouldCarryATarget() {
        let rejected = [
            "openrung://open",
            "openrung://",
            "openrung://connect/",
            "openrung://connect/jp",
            "openrung://connect?country=JP",
            "openrung://connect?",
            "openrung://connect#relay",
            "openrung://connect#",
            "openrung://user@connect",
            "openrung://user:pw@connect",
            "openrung://connect:443",
            "openrung://connect.example",
            "openrung://broker",
            "https://connect",
            "openrung:connect",
            "openrung:///connect",
        ]
        for raw in rejected {
            guard let url = URL(string: raw) else { continue }
            XCTAssertFalse(WidgetConnectURL.isConnectRequest(url), raw)
        }
    }

    func testHandleSubmitsOneRequestForAConnectURLAndNothingOtherwise() {
        let mailbox = WidgetConnectMailbox()
        XCTAssertFalse(WidgetConnectURL.handle([WidgetConnectURL.open], mailbox: mailbox, now: epoch, enabled: true))
        XCTAssertNil(mailbox.collect(now: epoch))
        XCTAssertTrue(WidgetConnectURL.handle(
            [WidgetConnectURL.open, WidgetConnectURL.connect], mailbox: mailbox, now: epoch, enabled: true
        ))
        XCTAssertEqual(mailbox.collect(now: epoch), WidgetConnectRequest(source: .url, issuedAt: epoch))
    }

    func testURLHandoffIsIgnoredWhereTheIntentPathExists() {
        let mailbox = WidgetConnectMailbox()
        XCTAssertFalse(WidgetConnectURL.handle([WidgetConnectURL.connect], mailbox: mailbox, now: epoch, enabled: false))
        XCTAssertNil(mailbox.collect(now: epoch))
    }

    func testURLHandoffIsEnabledOnlyBelowiOS17() {
        if #available(iOS 17.0, *) {
            XCTAssertFalse(WidgetConnectURL.acceptsURLHandoff)
        } else {
            XCTAssertTrue(WidgetConnectURL.acceptsURLHandoff)
        }
    }

    // MARK: - Background connect

    /// A `WidgetBackgroundConnect` over an in-memory key, counting reload requests.
    private final class BackgroundConnectHarness {
        var available = false
        var reloads = 0
        lazy var subject = WidgetBackgroundConnect(
            readAvailable: { [unowned self] in self.available },
            writeAvailable: { [unowned self] in self.available = $0 },
            reload: { [unowned self] in self.reloads += 1 }
        )
    }

    func testBackgroundConnectIsOfferedOnlyOnceTheAppSaysSo() {
        let harness = BackgroundConnectHarness()
        XCTAssertFalse(harness.subject.isAvailable, "a fresh install opens the app")
        XCTAssertTrue(harness.subject.publish(available: true))
        XCTAssertTrue(harness.subject.isAvailable)
        XCTAssertEqual(harness.reloads, 1)
    }

    func testRepublishingTheSameAvailabilityCostsNoReload() {
        let harness = BackgroundConnectHarness()
        XCTAssertFalse(harness.subject.publish(available: false))
        harness.subject.publish(available: true)
        XCTAssertFalse(harness.subject.publish(available: true))
        XCTAssertEqual(harness.reloads, 1)
        XCTAssertTrue(harness.subject.publish(available: false))
        XCTAssertEqual(harness.reloads, 2)
    }

    func testAnUnavailableStartSendsTheNextTapToTheApp() async {
        let harness = BackgroundConnectHarness()
        harness.available = true
        let outcome = await harness.subject.run(start: { .unavailable }, tunnelHasAnswered: { false })
        XCTAssertEqual(outcome, .unavailable)
        XCTAssertFalse(harness.available)
        XCTAssertEqual(harness.reloads, 0, "the rebuild after the intent picks it up")
    }

    func testWithoutAnInstalledStartTheTapFallsBackToo() async {
        let harness = BackgroundConnectHarness()
        harness.available = true
        let outcome = await harness.subject.run(start: nil, tunnelHasAnswered: { false })
        XCTAssertEqual(outcome, .unavailable)
        XCTAssertFalse(harness.available)
    }

    func testAnIgnoredTapKeepsBackgroundConnectAndDoesNotWait() async {
        let harness = BackgroundConnectHarness()
        harness.available = true
        var pauses = 0
        let outcome = await harness.subject.run(
            start: { .ignored }, tunnelHasAnswered: { false }, pause: { pauses += 1 }
        )
        XCTAssertEqual(outcome, .ignored)
        XCTAssertTrue(harness.available)
        XCTAssertEqual(pauses, 0)
    }

    func testAStartWaitsForTheTunnelsFirstSnapshot() async {
        let harness = BackgroundConnectHarness()
        harness.available = true
        var pauses = 0
        let outcome = await harness.subject.run(
            start: { .started }, tunnelHasAnswered: { pauses >= 2 }, pause: { pauses += 1 }
        )
        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(pauses, 2)
        XCTAssertTrue(harness.available)
        XCTAssertEqual(harness.reloads, 0)
    }

    func testAStartStopsWaitingAtTheSettleLimit() async {
        let harness = BackgroundConnectHarness()
        var clock = epoch
        var pauses = 0
        let outcome = await harness.subject.run(
            start: { .started },
            tunnelHasAnswered: { false },
            now: { clock },
            pause: {
                pauses += 1
                clock = clock.addingTimeInterval(1)
            }
        )
        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(pauses, Int(WidgetBackgroundConnect.settleWait))
    }

    func testBackgroundConnectKeyIsTheWidgetsOwn() {
        XCTAssertEqual(WidgetSharedState.backgroundConnectKey, "widget_background_connect")
        XCTAssertNotEqual(WidgetSharedState.backgroundConnectKey, WidgetSharedState.connectionSnapshotKey)
    }
}
