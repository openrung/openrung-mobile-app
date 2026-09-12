import Foundation
import XCTest

/// Expectations come from the shipping provider on e1dc94c: stop joins launch,
/// callbacks cannot resurrect a retired provider, wake alone is not an epoch,
/// and pending session telemetry survives a bounded upload failure.
final class EngineHostTests: XCTestCase {
    private let wifi = EngineNetworkSnapshot(up: true, fingerprint: "wifi")

    func testStopDuringStartJoinsBeforeCompletingAndDiscardsBufferedConnected() {
        let queue = DispatchQueue(label: "test.host")
        let native = FakeEngine()
        var dispatcher: EngineEventDispatcher!
        let host = PacketTunnelEngineHost(queue: queue) { dispatcher = $0; return native }
        let owner = FakeOwner()
        let started = expectation(description: "start completed once")
        var calls = 0
        host.start(owner: owner, broker: "https://broker", country: "IR", relay: "relay-id") { error in
            calls += 1
            XCTAssertTrue(error is CancellationError)
            XCTAssertTrue(native.stopped)
            started.fulfill()
        }
        queue.sync {}
        owner.network?(wifi)
        queue.sync {}
        XCTAssertEqual(native.starts, ["https://broker|IR|relay-id"])
        let stopped = expectation(description: "stop completed")
        host.stop(owner: owner) { stopped.fulfill() }
        // Captured attachment is retired before this event can be delivered.
        dispatcher.onEvent(event(1, "connected"))
        wait(for: [started, stopped], timeout: 2)
        queue.sync {}
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(owner.events.isEmpty)
        XCTAssertNil(host.currentOwner())
    }

    func testBlockedTeardownKeepsOldOwnerUntilStopReturns() {
        let queue = DispatchQueue(label: "test.host")
        let native = FakeEngine()
        let host = PacketTunnelEngineHost(queue: queue) { _ in native }
        let first = FakeOwner(), second = FakeOwner()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        host.start(owner: first, broker: "one", country: "", relay: "") { _ in }
        queue.sync {}; first.network?(wifi); queue.sync {}
        native.onStop = { entered.signal(); release.wait() }
        host.start(owner: second, broker: "two", country: "", relay: "") { _ in }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(host.currentOwner() === first)
        XCTAssertFalse(first.observationClosed)
        release.signal()
        queue.sync {}
        XCTAssertTrue(host.currentOwner() === second)
        native.onStop = nil
        host.stop(owner: second) {}; queue.sync {}
    }

    func testReconnectReusesEngineAndRejectsOldOwnerNetworkAndStop() {
        let queue = DispatchQueue(label: "test.host")
        let native = FakeEngine()
        var creates = 0
        let host = PacketTunnelEngineHost(queue: queue) { _ in creates += 1; return native }
        let first = FakeOwner(), second = FakeOwner()
        host.start(owner: first, broker: "one", country: "", relay: "") { _ in }
        queue.sync {}
        first.network?(wifi); queue.sync {}
        let oldNetwork = first.network
        host.start(owner: second, broker: "two", country: "", relay: "") { _ in }
        queue.sync {}
        second.network?(wifi); queue.sync {}
        oldNetwork?(EngineNetworkSnapshot(up: false, fingerprint: "stale"))
        host.stop(owner: first) {}
        queue.sync {}
        XCTAssertEqual(creates, 1)
        XCTAssertEqual(native.starts, ["one||", "two||"])
        XCTAssertEqual(native.networks.map(\.fingerprint), ["wifi", "wifi"])
        XCTAssertTrue(host.currentOwner() === second)
        XCTAssertTrue(first.observationClosed)
        host.stop(owner: second) {}; queue.sync {}
    }

    func testSleepChangedEpochThenWakePreservesCommandOrder() {
        let queue = DispatchQueue(label: "test.host")
        let native = FakeEngine()
        let host = PacketTunnelEngineHost(queue: queue) { _ in native }
        let owner = FakeOwner()
        host.start(owner: owner, broker: "broker", country: "", relay: "") { _ in }
        queue.sync {}; owner.network?(wifi); queue.sync {}
        host.sleep(owner: owner) {}
        owner.network?(EngineNetworkSnapshot(up: true, fingerprint: "cell"))
        host.wake(owner: owner)
        queue.sync {}
        XCTAssertEqual(Array(native.commands.suffix(3)), ["pause", "network:cell", "resume"])
        XCTAssertEqual(native.starts.count, 1)
        host.stop(owner: owner) {}; queue.sync {}
    }

    func testUploadTimeoutAllowsReuseButIncompleteTeardownPoisonsHost() {
        for incomplete in [false, true] {
            let queue = DispatchQueue(label: "test.host")
            let native = FakeEngine()
            let host = PacketTunnelEngineHost(queue: queue) { _ in native }
            let owner = FakeOwner(), replacement = FakeOwner()
            host.start(owner: owner, broker: "one", country: "", relay: "") { _ in }
            queue.sync {}; owner.network?(wifi); queue.sync {}
            native.stopError = URLError(.timedOut)
            native.teardownComplete = !incomplete
            host.stop(owner: owner) {}; queue.sync {}
            host.start(owner: replacement, broker: "two", country: "", relay: "") { _ in }
            queue.sync {}
            replacement.network?(wifi); queue.sync {}
            XCTAssertEqual(native.starts.count, incomplete ? 1 : 2)
            XCTAssertEqual(owner.teardownFailed, incomplete)
            if !incomplete { host.stop(owner: replacement) {}; queue.sync {} }
        }
    }

    func testFailurePersistsAndCannotCompleteStartTwice() {
        let queue = DispatchQueue(label: "test.host")
        let native = FakeEngine()
        var dispatcher: EngineEventDispatcher!
        let host = PacketTunnelEngineHost(queue: queue) { dispatcher = $0; return native }
        let owner = FakeOwner()
        var completions = 0
        host.start(owner: owner, broker: "broker", country: "", relay: "") { _ in completions += 1 }
        queue.sync {}; owner.network?(wifi); queue.sync {}
        dispatcher.onEvent(event(1, "connected")); queue.sync {}
        dispatcher.onEvent(event(2, "failed")); queue.sync {}
        host.stop(owner: owner) {}; queue.sync {}
        XCTAssertEqual(completions, 1)
        XCTAssertNotNil(owner.stoppedError)
        XCTAssertEqual(owner.stoppedStartPending, false, "Established tunnel failure must use cancellation")
        XCTAssertNil(host.currentOwner())
    }

    func testStopBeforeInitialNetworkNeverStartsEngine() {
        let queue = DispatchQueue(label: "test.host")
        let native = FakeEngine()
        let host = PacketTunnelEngineHost(queue: queue) { _ in native }
        let owner = FakeOwner()
        host.start(owner: owner, broker: "broker", country: "", relay: "") { _ in }
        queue.sync {}
        let delayed = owner.network
        host.stop(owner: owner) {}; queue.sync {}
        delayed?(wifi); queue.sync {}
        XCTAssertTrue(native.starts.isEmpty)
    }

    func testLocalStartFailuresPersistBeforeCompletingWithoutCancellationSignal() {
        for failurePoint in ["factory", "start", "missingNetwork"] {
            let queue = DispatchQueue(label: "test.failure-order")
            let native = FakeEngine()
            let failure = PacketTunnelEngineError.unavailable
            if failurePoint == "start" { native.startError = failure }
            let host = PacketTunnelEngineHost(queue: queue) { _ in
                if failurePoint == "factory" { throw failure }
                return native
            }
            let owner = FakeOwner()
            let completed = expectation(description: failurePoint)
            host.start(owner: owner, broker: "broker", country: "", relay: "") { error in
                XCTAssertNotNil(error)
                XCTAssertNotNil(owner.stoppedError, "Failure must be durable before NE completion")
                XCTAssertEqual(owner.stoppedStartPending, true, "Use completion, not cancelTunnelWithError")
                XCTAssertEqual(owner.notifications, ["stopped"])
                completed.fulfill()
            }
            queue.sync {}
            if failurePoint == "start" { owner.network?(wifi) }
            wait(for: [completed], timeout: 7)
            queue.sync {}
            XCTAssertNil(host.currentOwner())
        }
    }

    func testTeardownFailurePrecedesCompletionAndRepeatedOSStopIsHarmless() {
        let queue = DispatchQueue(label: "test.poison-order")
        let native = FakeEngine()
        let host = PacketTunnelEngineHost(queue: queue) { _ in native }
        let owner = FakeOwner()
        let completed = expectation(description: "failed startup completed")
        host.start(owner: owner, broker: "broker", country: "", relay: "") { error in
            XCTAssertNotNil(error)
            XCTAssertEqual(owner.notifications, ["stopping", "teardown"])
            XCTAssertEqual(owner.teardownStartPending, true)
            completed.fulfill()
        }
        queue.sync {}; owner.network?(wifi); queue.sync {}
        native.teardownComplete = false
        host.stop(owner: owner) {}
        wait(for: [completed], timeout: 2)
        queue.sync {}
        let stops = native.stopCalls
        let osStopped = expectation(description: "follow-up OS stop completed")
        host.stop(owner: owner) { osStopped.fulfill() }
        wait(for: [osStopped], timeout: 2)
        queue.sync {}
        XCTAssertEqual(native.stopCalls, stops)
        XCTAssertEqual(owner.notifications, ["stopping", "teardown"])
        XCTAssertTrue(host.currentOwner() === owner, "Keep the potentially live TUN owner")
    }

    private func event(_ sequence: Int, _ status: String) -> String {
        "{\"version\":1,\"sequence\":\(sequence),\"kind\":\"state\",\"payload\":{\"Status\":\"\(status)\",\"LastError\":\"test failure\"}}"
    }
}

private final class FakeOwner: PacketTunnelEngineOwner {
    var network: ((EngineNetworkSnapshot) -> Void)?
    var events: [EngineEvent] = []
    var observationClosed = false
    var stoppedError: Error?
    var teardownFailed = false
    var stoppedStartPending: Bool?
    var teardownStartPending: Bool?
    var notifications: [String] = []
    func observeNetwork(_ receive: @escaping (EngineNetworkSnapshot) -> Void) { network = receive }
    func closeNetworkObservation() { observationClosed = true; network = nil }
    func receiveEngineEvent(_ event: EngineEvent) { events.append(event) }
    func engineStopping() { notifications.append("stopping") }
    func engineStopped(error: Error?, startPending: Bool) {
        stoppedError = error
        stoppedStartPending = startPending
        notifications.append("stopped")
    }
    func engineTeardownFailed(_ error: Error, startPending: Bool) {
        teardownFailed = true
        teardownStartPending = startPending
        notifications.append("teardown")
    }
}

private final class FakeEngine: PacketTunnelEngine {
    var starts: [String] = []
    var commands: [String] = []
    var networks: [EngineNetworkSnapshot] = []
    var stopped = false
    var onStop: (() -> Void)?
    var stopError: Error?
    var startError: Error?
    var stopCalls = 0
    var teardownComplete = true
    func start(broker: String, country: String, relay: String) throws { stopped = false; starts.append("\(broker)|\(country)|\(relay)"); if let startError { throw startError } }
    func stop() throws { stopCalls += 1; onStop?(); stopped = true; if let stopError { throw stopError } }
    func pause() { commands.append("pause") }
    func resume() { commands.append("resume") }
    func networkChanged(_ snapshot: EngineNetworkSnapshot) throws { networks.append(snapshot); commands.append("network:\(snapshot.fingerprint)") }
}
