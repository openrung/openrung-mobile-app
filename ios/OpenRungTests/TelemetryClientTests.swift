import Foundation
import XCTest

/// The platform-side remainder of the telemetry upload path. The outbox itself — persistence,
/// caps, the pre-0.3.5 array-format migration, identity-homogeneous batching, the per-application
/// flow budget, heartbeat piggybacking, and the commit-only-after-success rule — is the bound Go
/// implementation, pinned end-to-end (including the written-before-upgrade/uploaded-after-upgrade
/// case) by `android/punchbridge/telemetry_binding_test.go` against a real HTTP broker. What
/// remains here is the outcome type the manager consumes and its projection into the bounded
/// `BrokerNativeFailure` contract shared with every other native broker call.
final class TelemetryClientTests: XCTestCase {
    func testFailureProjectsTheBoundedBrokerContract() {
        let outcome = NativeTelemetryFlushOutcome(
            succeeded: false,
            errorKind: "rate_limited",
            errorText: "Broker request was rate-limited",
            httpStatus: 429,
            retryAfterMilliseconds: 5_000
        )
        let failure = outcome.failure(operationName: "native telemetry upload")
        XCTAssertEqual(failure.kind, .rateLimited)
        XCTAssertEqual(failure.httpStatus, 429)
        XCTAssertEqual(failure.retryAfterMilliseconds, 5_000)
        XCTAssertEqual(
            failure.errorDescription,
            "native telemetry upload failed: Broker request was rate-limited"
        )
    }

    func testFailureWithoutDetailKeepsABoundedMessage() {
        let outcome = NativeTelemetryFlushOutcome(succeeded: false, errorKind: "network")
        let failure = outcome.failure(operationName: "native telemetry upload")
        XCTAssertEqual(failure.kind, .network)
        XCTAssertNil(failure.httpStatus)
        XCTAssertNil(failure.retryAfterMilliseconds)
        XCTAssertEqual(failure.errorDescription, "native telemetry upload failed")
    }

    func testUnknownBindingKindsStayInTheBoundedBucket() {
        // Blank and future binding values must never mint new platform failure kinds.
        for kind in ["", "future_kind"] {
            let outcome = NativeTelemetryFlushOutcome(succeeded: false, errorKind: kind)
            XCTAssertEqual(outcome.failure(operationName: "x").kind, .unknown, kind)
        }
    }
}
