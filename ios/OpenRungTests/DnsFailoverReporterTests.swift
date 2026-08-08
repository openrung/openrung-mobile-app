import Foundation
import XCTest

final class DnsFailoverReporterTests: XCTestCase {
    func testStartupFailureAdvancesTheRotationAndReportsThePairOnce() {
        let sink = FailoverSink()
        let reporter = sink.makeReporter()

        XCTAssertTrue(reporter.reportFailure(["1.1.1.1", "8.8.8.8"]))
        XCTAssertEqual(sink.snapshot, ["1.1.1.1->8.8.8.8"])
        XCTAssertEqual(reporter.currentServers(), ["8.8.8.8", "1.1.1.1"])

        // The same order reported twice (startup retry racing the health loop) must neither
        // advance again nor emit a second failover event.
        XCTAssertFalse(reporter.reportFailure(["1.1.1.1", "8.8.8.8"]))
        XCTAssertEqual(sink.snapshot.count, 1)
    }

    func testHealthLoopReportsAgainstTheRunningEnginesFrozenOrder() {
        let sink = FailoverSink()
        let reporter = sink.makeReporter()

        // The engine now running was verified with the default order.
        reporter.activate(["1.1.1.1", "8.8.8.8"])
        // Three consecutive health strikes: only the first may advance, or the recovery
        // reconnect would skip past a resolver that was never tried.
        XCTAssertTrue(reporter.reportFailure())
        XCTAssertFalse(reporter.reportFailure())
        XCTAssertFalse(reporter.reportFailure())

        XCTAssertEqual(sink.snapshot.count, 1)
        XCTAssertEqual(reporter.currentServers(), ["8.8.8.8", "1.1.1.1"])
    }

    func testStaleActiveOrderCannotAdvancePastAnUntriedResolver() {
        let sink = FailoverSink()
        let reporter = sink.makeReporter()

        reporter.activate(["1.1.1.1", "8.8.8.8"])
        // Startup already rotated after this engine started (e.g. a later epoch's DNS failure).
        XCTAssertTrue(reporter.reportFailure(["1.1.1.1", "8.8.8.8"]))
        sink.removeAll()

        // The health loop's strike still names the retired order: it must be absorbed, leaving
        // the freshly-promoted resolver in place to actually be tried.
        XCTAssertFalse(reporter.reportFailure())
        XCTAssertTrue(sink.snapshot.isEmpty)
        XCTAssertEqual(reporter.currentServers(), ["8.8.8.8", "1.1.1.1"])
    }

    func testActivateReFreezesTheOrderForTheNextEngine() {
        let sink = FailoverSink()
        let reporter = sink.makeReporter()

        reporter.activate(["1.1.1.1", "8.8.8.8"])
        XCTAssertTrue(reporter.reportFailure())
        // The recovery reconnect verified a new engine on the rotated order.
        reporter.activate(reporter.currentServers())
        XCTAssertTrue(reporter.reportFailure())

        XCTAssertEqual(sink.snapshot, ["1.1.1.1->8.8.8.8", "8.8.8.8->1.1.1.1"])
        XCTAssertEqual(reporter.currentServers(), ["1.1.1.1", "8.8.8.8"])
    }

    func testResolverCountIsExposedForTheSameRelayRetryBudget() {
        XCTAssertEqual(
            FailoverSink().makeReporter().resolverCount,
            DnsResolverRotation.defaultResolvers.count
        )
    }
}

/// The reporter's callback escapes, so the recorded failovers live in a lock-guarded reference.
private final class FailoverSink: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func makeReporter() -> DnsFailoverReporter {
        DnsFailoverReporter(rotation: DnsResolverRotation()) { [self] failed, next in
            lock.lock()
            values.append("\(failed)->\(next)")
            lock.unlock()
        }
    }

    var snapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func removeAll() {
        lock.lock()
        values.removeAll()
        lock.unlock()
    }
}
