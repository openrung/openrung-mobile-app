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
        XCTAssertFalse(WidgetConnectURL.handle([WidgetConnectURL.open], mailbox: mailbox, now: epoch))
        XCTAssertNil(mailbox.collect(now: epoch))
        XCTAssertTrue(WidgetConnectURL.handle([WidgetConnectURL.open, WidgetConnectURL.connect], mailbox: mailbox, now: epoch))
        XCTAssertEqual(mailbox.collect(now: epoch), WidgetConnectRequest(source: .url, issuedAt: epoch))
    }
}
