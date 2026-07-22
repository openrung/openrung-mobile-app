import Foundation
import NetworkExtension
import XCTest

/// Unit tests for `FailureClassifier`. The classifier and the error types it maps
/// (`PacketTunnelError`, `BrokerClientError`, `RelayReachabilityError`,
/// `PacketTunnelProxyEngineError`) are compiled directly into this test target — see the
/// `OpenRungTests` target in `project.yml` — so no import of the app/extension is needed.
final class FailureClassifierTests: XCTestCase {

    // MARK: - PacketTunnelError sentinels

    func testRelaySelectionSentinels() {
        XCTAssertEqual(FailureClassifier.classify(PacketTunnelError.noUsableRelay), "no_usable_relay")
        XCTAssertEqual(FailureClassifier.classify(PacketTunnelError.noRelayInCountry("Peru")), "no_relay_in_country")
        XCTAssertEqual(FailureClassifier.classify(PacketTunnelError.relayNotAvailable), "relay_not_in_list")
    }

    // MARK: - Wrappers unwrap and classify the real cause

    func testAllRelaysFailedUnwrapsUnderlyingError() {
        XCTAssertEqual(
            FailureClassifier.classify(PacketTunnelError.allRelaysFailed(URLError(.timedOut))),
            "timeout"
        )
        XCTAssertEqual(
            FailureClassifier.classify(PacketTunnelError.allRelaysFailed(BrokerClientError.httpStatus(429))),
            "rate_limited"
        )
        // No last error captured → generic.
        XCTAssertEqual(FailureClassifier.classify(PacketTunnelError.allRelaysFailed(nil)), "no_usable_relay")
    }

    func testAllRelaysFailedUnwrapsEngineFailure() {
        XCTAssertEqual(
            FailureClassifier.classify(PacketTunnelError.allRelaysFailed(PacketTunnelProxyEngineError.engineStartFailed("boom"))),
            "process_exited"
        )
    }

    func testRelayUnreachableUnwrapsUnderlyingError() {
        XCTAssertEqual(
            FailureClassifier.classify(PacketTunnelError.relayUnreachable(host: "1.2.3.4", port: 443, underlying: URLError(.cannotConnectToHost))),
            "connection_refused"
        )
        XCTAssertEqual(
            FailureClassifier.classify(PacketTunnelError.relayUnreachable(host: "1.2.3.4", port: 443, underlying: RelayReachabilityError.timeout)),
            "timeout"
        )
        // No underlying cause → reachability fallback token.
        XCTAssertEqual(
            FailureClassifier.classify(PacketTunnelError.relayUnreachable(host: "1.2.3.4", port: 443, underlying: nil)),
            "network_unreachable"
        )
    }

    // MARK: - Cancellation

    func testCancellation() {
        XCTAssertEqual(FailureClassifier.classify(CancellationError()), "cancelled")
        XCTAssertEqual(FailureClassifier.classify(URLError(.cancelled)), "cancelled")
    }

    // MARK: - Broker HTTP status

    func testBrokerHTTPStatus() {
        XCTAssertEqual(FailureClassifier.classify(BrokerClientError.httpStatus(429)), "rate_limited")
        XCTAssertEqual(FailureClassifier.classify(BrokerClientError.httpStatus(503)), "http_503")
        XCTAssertEqual(FailureClassifier.classify(BrokerClientError.httpStatus(500)), "http_500")
        XCTAssertEqual(FailureClassifier.classify(BrokerClientError.invalidResponse), "unknown")
    }

    // MARK: - URLError codes

    func testURLErrorCodes() {
        XCTAssertEqual(FailureClassifier.classify(URLError(.timedOut)), "timeout")
        XCTAssertEqual(FailureClassifier.classify(URLError(.cannotFindHost)), "dns_failure")
        XCTAssertEqual(FailureClassifier.classify(URLError(.dnsLookupFailed)), "dns_failure")
        XCTAssertEqual(FailureClassifier.classify(URLError(.secureConnectionFailed)), "tls_handshake")
        XCTAssertEqual(FailureClassifier.classify(URLError(.serverCertificateUntrusted)), "tls_handshake")
        XCTAssertEqual(FailureClassifier.classify(URLError(.cannotConnectToHost)), "connection_refused")
        XCTAssertEqual(FailureClassifier.classify(URLError(.notConnectedToInternet)), "network_unreachable")
        XCTAssertEqual(FailureClassifier.classify(URLError(.networkConnectionLost)), "network_unreachable")
    }

    // MARK: - POSIX errno (bridged as NSError, as NWError/POSIXError would surface)

    private func posix(_ code: POSIXErrorCode) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code.rawValue))
    }

    func testPOSIXErrno() {
        XCTAssertEqual(FailureClassifier.classify(posix(.ECONNREFUSED)), "connection_refused")
        XCTAssertEqual(FailureClassifier.classify(posix(.ECONNRESET)), "connection_reset")
        XCTAssertEqual(FailureClassifier.classify(posix(.ENETUNREACH)), "network_unreachable")
        XCTAssertEqual(FailureClassifier.classify(posix(.EHOSTUNREACH)), "network_unreachable")
        XCTAssertEqual(FailureClassifier.classify(posix(.ETIMEDOUT)), "timeout")
        XCTAssertEqual(FailureClassifier.classify(posix(.EACCES)), "permission_denied")
        XCTAssertEqual(FailureClassifier.classify(posix(.EPERM)), "permission_denied")
    }

    func testErrnoRootCauseWinsOverWrapper() {
        // A refused connection surfacing as the last relay error must classify as connection_refused,
        // unwrapped from the allRelaysFailed wrapper (socket errno before engine-exit / unknown).
        XCTAssertEqual(
            FailureClassifier.classify(PacketTunnelError.allRelaysFailed(posix(.ECONNREFUSED))),
            "connection_refused"
        )
    }

    // MARK: - Permission / engine / unknown

    func testPermissionAndEngineAndUnknown() {
        XCTAssertEqual(FailureClassifier.classify(NSError(domain: NEVPNErrorDomain, code: 1)), "permission_denied")
        XCTAssertEqual(FailureClassifier.classify(PacketTunnelProxyEngineError.engineStartFailed("died")), "process_exited")
        XCTAssertEqual(FailureClassifier.classify(PacketTunnelProxyEngineError.engineNotLinked), "process_exited")
        XCTAssertEqual(FailureClassifier.classify(NSError(domain: "com.example.other", code: 7)), "unknown")
    }

    func testWssWrappersKeepLocalAndTransportClassificationSeparate() {
        XCTAssertEqual(
            FailureClassifier.classify(
                DirectPathError(stage: "tcp", underlying: URLError(.timedOut))
            ),
            "timeout"
        )
        XCTAssertEqual(
            FailureClassifier.classify(
                LocalTunnelError(stage: "permission", underlying: NSError(domain: NEVPNErrorDomain, code: 1))
            ),
            "permission_denied"
        )
        XCTAssertEqual(
            FailureClassifier.classify(
                WssTransportError(stage: "ticket", frontID: "front-a", underlying: BrokerClientError.httpStatus(503))
            ),
            "http_503"
        )
        XCTAssertEqual(
            FailureClassifier.classify(
                DirectPathError(
                    stage: "internet_probe",
                    underlying: InternetProbeError.unreachable(URLError(.dnsLookupFailed))
                )
            ),
            "dns_failure"
        )
        XCTAssertEqual(
            FailureClassifier.classify(
                WssTransportError(
                    stage: "ticket",
                    frontID: "front-a",
                    underlying: WssTicketStatusError(status: 429, retryAfterMilliseconds: 1_000)
                )
            ),
            "rate_limited"
        )
        XCTAssertEqual(
            FailureClassifier.classify(
                WssTicketStatusError(status: 503, retryAfterMilliseconds: nil)
            ),
            "http_503"
        )
        XCTAssertEqual(
            FailureClassifier.detail(
                WssTransportError(
                    stage: "ticket",
                    frontID: "front-a",
                    underlying: WssTicketStatusError(status: 503, retryAfterMilliseconds: nil)
                )
            ),
            "WSS ticket HTTP status 503"
        )
    }

    // MARK: - failure_detail truncation

    func testDetailTruncatesOnUTF8Boundary() {
        // 254 ASCII bytes + a 4-byte emoji = 258 bytes; a naive 256-byte cut would split the emoji.
        let base = String(repeating: "a", count: 254)
        let message = base + "😀" // U+1F600, F0 9F 98 80
        let truncated = FailureClassifier.truncate(message)

        XCTAssertEqual(truncated, base)
        XCTAssertLessThanOrEqual(truncated.utf8.count, 256)
        XCTAssertFalse(truncated.contains("\u{FFFD}"))
    }

    func testTruncateLeavesValuesWithinLimitUntouched() {
        let short = "connect timed out"
        XCTAssertEqual(FailureClassifier.truncate(short), short)

        let exactly256 = String(repeating: "a", count: 256)
        XCTAssertEqual(FailureClassifier.truncate(exactly256), exactly256)

        let over = String(repeating: "a", count: 300)
        XCTAssertEqual(FailureClassifier.truncate(over).utf8.count, 256)
    }

    func testDetailUsesUnderlyingDescription() {
        struct RootCause: LocalizedError {
            var errorDescription: String? { "connect timed out root cause" }
        }

        XCTAssertEqual(
            FailureClassifier.detail(PacketTunnelError.allRelaysFailed(RootCause())),
            "connect timed out root cause"
        )
        XCTAssertEqual(
            FailureClassifier.detail(PacketTunnelError.relayUnreachable(host: "1.2.3.4", port: 443, underlying: RootCause())),
            "connect timed out root cause"
        )
    }

    func testDetailFallsBackToWrapperDescriptionWithoutUnderlyingError() {
        let detail = FailureClassifier.detail(PacketTunnelError.allRelaysFailed(nil))
        XCTAssertTrue(detail.hasPrefix("All relay connection attempts failed."))
    }
}
