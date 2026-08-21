import Foundation
import NetworkExtension
import XCTest

/// Unit tests for `FailureClassifier`. The adapter and the error types it maps
/// (`PacketTunnelError`, `BrokerClientError`, `RelayReachabilityError`,
/// `PacketTunnelProxyEngineError`) are compiled directly into this test target — see the
/// `OpenRungTests` target in `project.yml` — so no import of the app/extension is needed.
///
/// These tests pin the extraction half of the classifier — platform error → binding input facts,
/// plus the wrapper unwrapping and the two pre-classified native taxonomies. The facts→token half
/// (the ladder, its precedence, and the broker-kind projection) lives in Go and is pinned by
/// `android/punchbridge/failure_binding_test.go`, which runs the same input shapes through the
/// real binding.
final class FailureClassifierTests: XCTestCase {

    private func facts(_ error: Error) -> NSDictionary? {
        FailureClassifier.bindingInput(for: error) as NSDictionary?
    }

    private func errnoFacts(_ code: POSIXErrorCode) -> NSDictionary {
        ["errno": Int(code.rawValue)]
    }

    // MARK: - PacketTunnelError sentinels

    func testRelaySelectionSentinels() {
        XCTAssertEqual(facts(PacketTunnelError.noUsableRelay), ["selection": "no_usable_relay"])
        XCTAssertEqual(facts(PacketTunnelError.noRelayInCountry("Peru")), ["selection": "no_relay_in_country"])
        XCTAssertEqual(facts(PacketTunnelError.relayNotAvailable), ["selection": "relay_not_in_list"])
    }

    // MARK: - Wrappers unwrap and describe the real cause

    func testAllRelaysFailedUnwrapsUnderlyingError() {
        XCTAssertEqual(
            facts(PacketTunnelError.allRelaysFailed(URLError(.timedOut))),
            ["timeout": true]
        )
        XCTAssertEqual(
            facts(PacketTunnelError.allRelaysFailed(BrokerClientError.httpStatus(429))),
            ["http_status": 429]
        )
        // No last error captured → the generic sentinel.
        XCTAssertEqual(
            facts(PacketTunnelError.allRelaysFailed(nil)),
            ["selection": "no_usable_relay"]
        )
    }

    func testAllRelaysFailedUnwrapsEngineFailure() {
        XCTAssertEqual(
            facts(PacketTunnelError.allRelaysFailed(PacketTunnelProxyEngineError.engineStartFailed("boom"))),
            ["process_exited": true]
        )
    }

    func testRelayUnreachableUnwrapsUnderlyingError() {
        // URLSession abstracts the refused connect; the platform's errno vocabulary is its fact form.
        XCTAssertEqual(
            facts(PacketTunnelError.relayUnreachable(host: "1.2.3.4", port: 443, underlying: URLError(.cannotConnectToHost))),
            errnoFacts(.ECONNREFUSED)
        )
        XCTAssertEqual(
            facts(PacketTunnelError.relayUnreachable(host: "1.2.3.4", port: 443, underlying: RelayReachabilityError.timeout)),
            ["timeout": true]
        )
        // No underlying cause → the reachability fallback condition.
        XCTAssertEqual(
            facts(PacketTunnelError.relayUnreachable(host: "1.2.3.4", port: 443, underlying: nil)),
            errnoFacts(.ENETUNREACH)
        )
    }

    func testDnsPathUnverifiedUnwrapsToTheRealCause() {
        // The fresh-DNS wrapper must be transparent to the classifier, or every resolver-path
        // failure would land on the dashboard as "unknown" and break the cross-client token
        // contract. Both the bare wrapper and the shape verifyStartupTunnelPath actually
        // produces (DirectPathError wrapping it) are covered.
        XCTAssertEqual(
            facts(DnsPathUnverifiedError(underlying: URLError(.timedOut))),
            ["timeout": true]
        )
        XCTAssertEqual(
            facts(
                DirectPathError(
                    stage: startupStageDnsProbe,
                    underlying: DnsPathUnverifiedError(underlying: URLError(.cannotParseResponse))
                )
            ),
            [:]
        )
        XCTAssertEqual(
            facts(
                DirectPathError(
                    stage: startupStageDnsProbe,
                    underlying: DnsPathUnverifiedError(underlying: URLError(.dnsLookupFailed))
                )
            ),
            ["dns": true]
        )
        // detail() unwraps through the same branch.
        XCTAssertEqual(
            FailureClassifier.detail(DnsPathUnverifiedError(underlying: URLError(.timedOut))),
            URLError(.timedOut).localizedDescription
        )
    }

    // MARK: - Cancellation

    func testCancellation() {
        XCTAssertEqual(facts(CancellationError()), ["cancelled": true])
        XCTAssertEqual(facts(URLError(.cancelled)), ["cancelled": true])
    }

    // MARK: - Broker HTTP status

    func testBrokerHTTPStatus() {
        // The shared ladder folds 429 into rate_limited; the adapter only carries the status.
        XCTAssertEqual(facts(BrokerClientError.httpStatus(429)), ["http_status": 429])
        XCTAssertEqual(facts(BrokerClientError.httpStatus(503)), ["http_status": 503])
        XCTAssertEqual(facts(BrokerClientError.httpStatus(500)), ["http_status": 500])
        XCTAssertEqual(facts(BrokerClientError.invalidResponse), [:])
    }

    func testEveryNativeBrokerKindPassesThroughWithItsStatus() {
        // The kind→token projection that BrokerNativeFailure.failureReason used to own is now the
        // shared classifier's; the adapter forwards the bounded kind string verbatim.
        for kind in BrokerNativeFailureKind.allCases {
            let status: Int? = kind == .httpStatus ? 503 : nil
            var expected: [String: Any] = ["broker_kind": kind.rawValue]
            if let status { expected["http_status"] = status }
            XCTAssertEqual(
                facts(BrokerNativeFailure(kind: kind, httpStatus: status)),
                expected as NSDictionary,
                "kind \(kind.rawValue)"
            )
        }
        // A future binding value normalizes into the bounded unknown kind before extraction.
        XCTAssertEqual(
            facts(
                BrokerNativeFailure(
                    bindingKind: "future_kind",
                    httpStatus: 0,
                    retryAfterMilliseconds: 0,
                    message: ""
                )
            ),
            ["broker_kind": "unknown"]
        )
    }

    // MARK: - URLError codes

    func testURLErrorCodes() {
        XCTAssertEqual(facts(URLError(.timedOut)), ["timeout": true])
        XCTAssertEqual(facts(URLError(.cannotFindHost)), ["dns": true])
        XCTAssertEqual(facts(URLError(.dnsLookupFailed)), ["dns": true])
        XCTAssertEqual(facts(URLError(.secureConnectionFailed)), ["tls": true])
        XCTAssertEqual(facts(URLError(.serverCertificateUntrusted)), ["tls": true])
        XCTAssertEqual(facts(URLError(.cannotConnectToHost)), errnoFacts(.ECONNREFUSED))
        XCTAssertEqual(facts(URLError(.notConnectedToInternet)), errnoFacts(.ENETUNREACH))
        XCTAssertEqual(facts(URLError(.networkConnectionLost)), errnoFacts(.ENETUNREACH))
    }

    // MARK: - POSIX errno (bridged as NSError, as NWError/POSIXError would surface)

    private func posix(_ code: POSIXErrorCode) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code.rawValue))
    }

    func testPOSIXErrno() {
        // The raw darwin number is the honest wire value: the binding is compiled for the same
        // platform, and the errno→token mapping is the shared ladder's.
        for code: POSIXErrorCode in [
            .ECONNREFUSED, .ECONNRESET, .ENETUNREACH, .EHOSTUNREACH, .ETIMEDOUT, .EACCES, .EPERM, .EPIPE,
        ] {
            XCTAssertEqual(facts(posix(code)), errnoFacts(code), "errno \(code.rawValue)")
        }
        // A POSIX-domain code that is no POSIXErrorCode must not be presented as an errno.
        XCTAssertEqual(facts(NSError(domain: NSPOSIXErrorDomain, code: 999_999)), [:])
    }

    func testErrnoRootCauseWinsOverWrapper() {
        // A refused connection surfacing as the last relay error must be described unwrapped from
        // the allRelaysFailed wrapper; the shared ladder keeps the errno ahead of the residual.
        XCTAssertEqual(
            facts(PacketTunnelError.allRelaysFailed(posix(.ECONNREFUSED))),
            errnoFacts(.ECONNREFUSED)
        )
    }

    // MARK: - Permission / engine / unknown

    func testPermissionAndEngineAndUnknown() {
        XCTAssertEqual(facts(NSError(domain: NEVPNErrorDomain, code: 1)), ["permission_denied": true])
        XCTAssertEqual(facts(PacketTunnelProxyEngineError.engineStartFailed("died")), ["process_exited": true])
        XCTAssertEqual(facts(PacketTunnelProxyEngineError.engineNotLinked), ["process_exited": true])
        // No facts: the shared classifier keeps the residual in its bounded "unknown" bucket.
        XCTAssertEqual(facts(NSError(domain: "com.example.other", code: 7)), [:])
    }

    func testWssWrappersKeepLocalAndTransportDescriptionsSeparate() {
        XCTAssertEqual(
            facts(DirectPathError(stage: "tcp", underlying: URLError(.timedOut))),
            ["timeout": true]
        )
        XCTAssertEqual(
            facts(LocalTunnelError(stage: "permission", underlying: NSError(domain: NEVPNErrorDomain, code: 1))),
            ["permission_denied": true]
        )
        XCTAssertEqual(
            facts(WssTransportError(stage: "ticket", frontID: "front-a", underlying: BrokerClientError.httpStatus(503))),
            ["http_status": 503]
        )
        XCTAssertEqual(
            facts(
                DirectPathError(
                    stage: "internet_probe",
                    underlying: InternetProbeError.unreachable(URLError(.dnsLookupFailed))
                )
            ),
            ["dns": true]
        )
        XCTAssertEqual(
            facts(
                WssTransportError(
                    stage: "ticket",
                    frontID: "front-a",
                    underlying: WssTicketStatusError(status: 429, retryAfterMilliseconds: 1_000)
                )
            ),
            ["http_status": 429]
        )
        XCTAssertEqual(
            facts(WssTicketStatusError(status: 503, retryAfterMilliseconds: nil)),
            ["http_status": 503]
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

    // MARK: - Pre-classified native taxonomies (classified without the binding)

    func testNativeWssErrorsUseBoundedSpecificReasons() {
        XCTAssertEqual(FailureClassifier.classify(WssNativeClientError.unavailable), "wss_client_unavailable")
        XCTAssertEqual(FailureClassifier.classify(WssNativeClientError.creationFailed), "wss_client_creation_failed")
        XCTAssertEqual(
            FailureClassifier.classify(WssNativeClientError.invalidLoopbackEndpoint),
            "wss_invalid_loopback_endpoint"
        )
        XCTAssertEqual(
            FailureClassifier.classify(WssNativeClientError.connectionFailed(reason: "cancelled")),
            "cancelled"
        )
        XCTAssertEqual(
            FailureClassifier.classify(WssNativeClientError.connectionFailed(reason: "client")),
            "wss_client_failed"
        )
        XCTAssertEqual(
            FailureClassifier.classify(WssNativeClientError.connectionFailed(reason: "front")),
            "wss_invalid_front"
        )
        XCTAssertEqual(
            FailureClassifier.classify(WssNativeClientError.connectionFailed(reason: "adapter")),
            "wss_invalid_loopback_endpoint"
        )
        XCTAssertEqual(
            FailureClassifier.classify(WssNativeClientError.connectionFailed(reason: "protect")),
            "wss_socket_protection_failed"
        )
        XCTAssertEqual(
            FailureClassifier.classify(WssNativeClientError.connectionFailed(reason: "transport")),
            "wss_transport_failed"
        )
        XCTAssertEqual(
            FailureClassifier.classify(
                WssNativeClientError.connectionFailed(reason: "opaque native detail must not escape")
            ),
            "wss_transport_failed"
        )
        // Pre-classified errors never produce binding facts.
        XCTAssertNil(FailureClassifier.bindingInput(for: WssNativeClientError.unavailable))
        XCTAssertEqual(
            FailureClassifier.preClassifiedToken(for: WssNativeClientError.unavailable),
            "wss_client_unavailable"
        )
    }

    func testNativePunchErrorsUseBoundedSpecificReasonsAndDetail() {
        XCTAssertEqual(
            FailureClassifier.classify(PunchNativeClientError.unavailable),
            "punch_client_unavailable"
        )
        XCTAssertEqual(
            FailureClassifier.classify(PunchNativeClientError.creationFailed),
            "punch_client_creation_failed"
        )
        XCTAssertEqual(
            FailureClassifier.classify(PunchNativeClientError.invalidLoopbackEndpoint),
            "punch_invalid_loopback_endpoint"
        )
        let declined = PunchNativeClientError.establishmentFailed(
            reason: .declined,
            detail: "relay temporarily declined the session",
            natClass: "eim"
        )
        XCTAssertEqual(FailureClassifier.classify(declined), "punch_declined")
        XCTAssertEqual(
            FailureClassifier.detail(declined),
            "relay temporarily declined the session"
        )
        XCTAssertNil(FailureClassifier.bindingInput(for: declined))
    }

    // MARK: - failure_detail message selection (the bound lives in the binding, tested in Go)

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
