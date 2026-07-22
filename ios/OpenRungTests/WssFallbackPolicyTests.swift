import Foundation
import XCTest

final class WssFallbackPolicyTests: XCTestCase {
    private struct AcceptingValidator: WssFrontSetValidating {
        func validateExact(_: [WssFrontDescriptor]) throws {}
    }

    private struct RejectingValidator: WssFrontSetValidating {
        func validateExact(_: [WssFrontDescriptor]) throws { throw URLError(.badURL) }
    }

    func testDirectSuccessDoesNotValidateOrAttemptWss() async throws {
        struct MustNotValidate: WssFrontSetValidating {
            func validateExact(_: [WssFrontDescriptor]) throws {
                XCTFail("front validation must remain lazy until a genuine direct-path failure")
            }
        }
        let policy = WssFallbackPolicy(validator: MustNotValidate())
        var wssCalls = 0

        let result: String = try await policy.connect(
            relay: makeWssTestRelay(),
            attemptDirect: { "direct" },
            attemptWss: { _ in wssCalls += 1; return "wss" },
            onDirectFallback: { _ in XCTFail("fallback callback must not run") },
            onWssFailure: { _, _ in XCTFail("WSS callback must not run") }
        )

        XCTAssertEqual(result, "direct")
        XCTAssertEqual(wssCalls, 0)
    }

    func testOnlyTypedRemoteDirectFailureUnlocksSignedFrontsInOrder() async throws {
        let policy = WssFallbackPolicy(validator: AcceptingValidator())
        let log = WssTestEventLog()
        let directFailure = DirectPathError(stage: "tcp", underlying: URLError(.timedOut))

        let result: String = try await policy.connect(
            relay: makeWssTestRelay(),
            attemptDirect: {
                await log.append("direct")
                throw directFailure
            },
            attemptWss: { front in
                await log.append("wss:\(front.id)")
                if front.id == "front-a" {
                    throw WssTransportError(
                        stage: "handshake",
                        frontID: front.id,
                        underlying: URLError(.networkConnectionLost)
                    )
                }
                return "front-b"
            },
            onDirectFallback: { _ in await log.append("fallback") },
            onWssFailure: { front, _ in await log.append("failed:\(front.id)") }
        )

        XCTAssertEqual(result, "front-b")
        let events = await log.snapshot()
        XCTAssertEqual(
            events,
            ["direct", "fallback", "wss:front-a", "failed:front-a", "wss:front-b"]
        )
    }

    func testLocalUnknownAndCancellationFailuresNeverUnlockWss() async {
        let policy = WssFallbackPolicy(validator: AcceptingValidator())
        let local = LocalTunnelError(stage: "permission", underlying: URLError(.dataNotAllowed))
        var wssCalls = 0

        do {
            let _: Void = try await policy.connect(
                relay: makeWssTestRelay(),
                attemptDirect: { throw local },
                attemptWss: { _ in wssCalls += 1 },
                onDirectFallback: { _ in XCTFail("local failure must not fallback") },
                onWssFailure: { _, _ in XCTFail("local failure must not emit transport failure") }
            )
            XCTFail("expected local failure")
        } catch {
            XCTAssertTrue(error is LocalTunnelError)
        }
        XCTAssertEqual(wssCalls, 0)

        do {
            let _: Void = try await policy.connect(
                relay: makeWssTestRelay(),
                attemptDirect: { throw CancellationError() },
                attemptWss: { _ in wssCalls += 1 },
                onDirectFallback: { _ in XCTFail("cancellation must not fallback") },
                onWssFailure: { _, _ in XCTFail("cancellation must not emit transport failure") }
            )
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(wssCalls, 0)

        do {
            let _: Void = try await policy.connect(
                relay: makeWssTestRelay(),
                attemptDirect: {
                    throw DirectPathError(stage: "tcp", underlying: CancellationError())
                },
                attemptWss: { _ in wssCalls += 1 },
                onDirectFallback: { _ in XCTFail("wrapped cancellation must not fallback") },
                onWssFailure: { _, _ in XCTFail("wrapped cancellation must not emit transport failure") }
            )
            XCTFail("expected wrapped cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(wssCalls, 0)
    }

    func testIneligibleOrNativeRejectedFrontsPreserveDirectFailure() async {
        let relays = [
            makeWssTestRelay(nodeClass: RelayConstants.nodeClassVolunteer),
            makeWssTestRelay(transport: "tunnel"),
            makeWssTestRelay(exitMode: "proxy"),
            makeWssTestRelay(publicPort: 8443),
            makeWssTestRelay(fronts: []),
        ]
        for policy in [
            WssFallbackPolicy(validator: AcceptingValidator()),
            WssFallbackPolicy(validator: RejectingValidator()),
        ] {
            for relay in relays + [makeWssTestRelay()] where
                relay != makeWssTestRelay() || policy.supportedFronts(for: relay).isEmpty {
                var wssCalls = 0
                do {
                    let _: Void = try await policy.connect(
                        relay: relay,
                        attemptDirect: { throw DirectPathError(stage: "tcp", underlying: URLError(.timedOut)) },
                        attemptWss: { _ in wssCalls += 1 },
                        onDirectFallback: { _ in XCTFail("unsupported fronts must not enter fallback") },
                        onWssFailure: { _, _ in XCTFail("unsupported fronts must not emit WSS failure") }
                    )
                    XCTFail("expected direct failure")
                } catch {
                    XCTAssertTrue(error is DirectPathError)
                }
                XCTAssertEqual(wssCalls, 0)
            }
        }
    }

    func testAllWssFailuresCarryOneRelayPenaltyMarkerAndTransportFailuresOnly() async {
        let policy = WssFallbackPolicy(validator: AcceptingValidator())
        var directFallbacks = 0
        var transportFailures: [String] = []

        do {
            let _: Void = try await policy.connect(
                relay: makeWssTestRelay(),
                attemptDirect: { throw DirectPathError(stage: "tcp", underlying: URLError(.timedOut)) },
                attemptWss: { front in
                    throw WssTransportError(
                        stage: "ticket",
                        frontID: front.id,
                        underlying: URLError(.cannotConnectToHost)
                    )
                },
                onDirectFallback: { _ in directFallbacks += 1 },
                onWssFailure: { front, _ in transportFailures.append(front.id) }
            )
            XCTFail("expected exhausted WSS ladder")
        } catch let marker as RelayFailureAlreadyRecordedError {
            XCTAssertEqual(marker.wssFailures.map(\.frontID), ["front-a", "front-b"])
            XCTAssertTrue(relayFailureAlreadyRecorded(marker))
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(directFallbacks, 1)
        XCTAssertEqual(transportFailures, ["front-a", "front-b"])
    }

    func testLocalFailureDuringWssAbortsRemainingFrontsWithoutTransportPenalty() async {
        let policy = WssFallbackPolicy(validator: AcceptingValidator())
        var attempted: [String] = []
        var transportFailures = 0
        do {
            let _: Void = try await policy.connect(
                relay: makeWssTestRelay(),
                attemptDirect: { throw DirectPathError(stage: "tcp", underlying: URLError(.timedOut)) },
                attemptWss: { front in
                    attempted.append(front.id)
                    throw LocalTunnelError(stage: "wss_client", underlying: URLError(.unsupportedURL))
                },
                onDirectFallback: { _ in },
                onWssFailure: { _, _ in transportFailures += 1 }
            )
            XCTFail("expected local failure")
        } catch {
            XCTAssertTrue(error is LocalTunnelError)
        }
        XCTAssertEqual(attempted, ["front-a"])
        XCTAssertEqual(transportFailures, 0)
    }

    func testNetworkRecoveryStartsANewDirectFirstEpoch() async throws {
        let policy = WssFallbackPolicy(validator: AcceptingValidator())
        let log = WssTestEventLog()
        var epochTracker = NetworkEpochTracker<String>()

        XCTAssertFalse(epochTracker.absorb("wifi"))
        for expectedPath in ["first", "cellular"] {
            if expectedPath == "cellular" { XCTAssertTrue(epochTracker.absorb(expectedPath)) }
            let result: String = try await policy.connect(
                relay: makeWssTestRelay(),
                attemptDirect: {
                    await log.append("direct")
                    throw DirectPathError(stage: "tcp", underlying: URLError(.timedOut))
                },
                attemptWss: { front in
                    await log.append("ticket+WSS:\(front.id)")
                    return expectedPath
                },
                onDirectFallback: { _ in },
                onWssFailure: { _, _ in }
            )
            XCTAssertEqual(result, expectedPath)
        }
        let events = await log.snapshot()
        XCTAssertEqual(
            events,
            ["direct", "ticket+WSS:front-a", "direct", "ticket+WSS:front-a"]
        )
    }

    func testCleanupStopsEngineThenEpochMonitorThenWssAdapter() {
        var order: [String] = []
        TunnelTransportCleanup.run(
            stopEngine: { order.append("engine") },
            closeNetworkMonitor: { order.append("network-monitor") },
            closeWss: { order.append("wss") }
        )
        XCTAssertEqual(order, ["engine", "network-monitor", "wss"])
    }

    func testStopDrainWaitsForCancelledRecoveryOwnerBeforeCleanup() async {
        let log = LockedLifecycleLog()
        let recovery = Task {
            while Task.isCancelled == false { await Task.yield() }
            // Models the cancellation unwind after a noncancellable engine.start returns.
            await Task.yield()
            log.append("recovery-unwound")
        }
        recovery.cancel()

        await TunnelTransportCleanup.drain([recovery])
        TunnelTransportCleanup.run(
            stopEngine: { log.append("engine") },
            closeNetworkMonitor: { log.append("network-monitor") },
            closeWss: { log.append("wss") }
        )

        XCTAssertEqual(log.values, ["recovery-unwound", "engine", "network-monitor", "wss"])
    }
}

private final class LockedLifecycleLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func append(_ value: String) {
        lock.withLock { stored.append(value) }
    }

    var values: [String] {
        lock.withLock { stored }
    }
}
