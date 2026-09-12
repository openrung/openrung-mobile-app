import Foundation
import Network
import NetworkExtension
#if canImport(Libbox)
import Libbox
#endif

/// Platform adapter for the shared failure classifier: translates an iOS error into the input
/// facts of the libbox binding's `OpenRungClassifyFailure`, whose token comes from the one Go
/// classifier every OpenRung client runs (`connectcore/clienttelemetry` in the sibling `openrung`
/// repo — the ladder this file used to hand-copy). This file no longer chooses tokens or orders
/// rungs; it only says which platform error types express which facts, and unwraps the wrappers
/// that carry the real cause.
///
/// `PacketTunnelError.allRelaysFailed` / `.relayUnreachable` carry the underlying `Error`, so the
/// real root cause is unwrapped and described on its merits instead of being reported as the
/// generic wrapper type (which is why the dashboard used to show generic Swift type names).
///
/// Two error families short-circuit before the binding: `WssNativeClientError` and
/// `PunchNativeClientError` already carry their own bounded, mobile-owned telemetry taxonomy
/// (`failureReason`), assigned where the native reason string still existed — re-deriving them
/// from facts would lose that specificity.
///
/// The extraction (`bindingInput(for:)`, `detailDescription`) is engine-free so the pod-free test
/// bundle can pin it; the facts→token half runs in `android/punchbridge`'s Go tests against the
/// same checked-in inputs (`testdata/classification-binding-inputs.json`).
enum FailureClassifier {

    /// The reason token for `error`.
    static func classify(_ error: Error) -> String {
        switch resolve(error) {
        case .token(let token):
            return token
        case .facts(let facts):
            return nativeClassify(serialize(facts))
        }
    }

    /// The binding input `classify` sends for `error`, or nil when `error` resolves to a
    /// pre-classified native token instead. Exposed for the contract-vector and unit suites.
    static func bindingInput(for error: Error) -> [String: Any]? {
        if case .facts(let facts) = resolve(error) { return facts }
        return nil
    }

    /// The pre-classified token `classify` returns for `error` without calling the binding, or
    /// nil when `error` describes binding facts instead. Exposed for the unit suite.
    static func preClassifiedToken(for error: Error) -> String? {
        if case .token(let token) = resolve(error) { return token }
        return nil
    }

    /// One resolved error: either a token a native transport already classified, or the facts the
    /// shared classifier decides on.
    private enum Resolution {
        case token(String)
        case facts([String: Any])
    }

    private static func resolve(_ error: Error) -> Resolution {
        // Local intent: the enclosing task was cancelled.
        if error is CancellationError { return .facts(["cancelled": true]) }

        // Wrappers that exist to carry the real cause are transparent.
        if let direct = error as? DirectPathError { return resolve(direct.underlying) }
        if let local = error as? LocalTunnelError { return resolve(local.underlying) }
        if let wss = error as? WssTransportError { return resolve(wss.underlying) }
        if let dnsPath = error as? DnsPathUnverifiedError { return resolve(dnsPath.underlying) }
        if let probe = error as? InternetProbeError {
            if let underlying = probe.underlyingError { return resolve(underlying) }
            // The probe reports an unreachable network without an errno; the platform's own errno
            // vocabulary expresses that condition for the shared ladder.
            return .facts(["errno": Int(POSIXErrorCode.ENETUNREACH.rawValue)])
        }
        if let ticketStatus = error as? WssTicketStatusError {
            return .facts(["http_status": ticketStatus.status])
        }
        if let brokerNative = error as? BrokerNativeFailure {
            // The bounded binding kind passes through verbatim; the shared classifier owns the
            // kind→token projection that BrokerNativeFailure.failureReason used to hand-copy.
            var facts: [String: Any] = ["broker_kind": brokerNative.kind.rawValue]
            if let status = brokerNative.httpStatus { facts["http_status"] = status }
            return .facts(facts)
        }
        if let recorded = error as? RelayFailureAlreadyRecordedError {
            if let lastWssFailure = recorded.wssFailures.last {
                return resolve(lastWssFailure)
            }
            return resolve(recorded.directFailure)
        }
        if let nativeWssError = error as? WssNativeClientError {
            return .token(nativeWssError.failureReason)
        }
        if let nativePunchError = error as? PunchNativeClientError {
            return .token(nativePunchError.failureReason)
        }

        // Relay-selection sentinels; unwrap the wrappers that carry the real cause.
        if let tunnelError = error as? PacketTunnelError {
            switch tunnelError {
            case .noUsableRelay:
                return .facts(["selection": "no_usable_relay"])
            case .noRelayInCountry:
                return .facts(["selection": "no_relay_in_country"])
            case .relayNotAvailable:
                return .facts(["selection": "relay_not_in_list"])
            case .relayUnreachable(_, _, let underlying):
                if let underlying { return resolve(underlying) }
                return .facts(["errno": Int(POSIXErrorCode.ENETUNREACH.rawValue)])
            case .allRelaysFailed(let underlying):
                if let underlying { return resolve(underlying) }
                return .facts(["selection": "no_usable_relay"])
            }
        }

        // Broker HTTP status; the shared ladder folds 429 into rate_limited.
        if let brokerError = error as? BrokerClientError {
            switch brokerError {
            case .httpStatus(let code):
                return .facts(["http_status": code])
            }
        }

        // App reachability timeout (raised by the NWConnection probe's own deadline).
        if let reachabilityError = error as? RelayReachabilityError {
            switch reachabilityError {
            case .timeout: return .facts(["timeout": true])
            case .invalidPort: return .facts([:])
            }
        }

        // System errors: a single URLError/NWError/POSIXError expresses exactly one fact.
        if let facts = systemErrorFacts(error) { return .facts(facts) }

        // Embedded proxy engine failed to start / stopped unexpectedly. It carries no nested
        // Error, so it never coexists with a system error above.
        if error is PacketTunnelProxyEngineError { return .facts(["process_exited": true]) }

        // No facts: the shared classifier keeps the residual in its bounded "unknown" bucket.
        return .facts([:])
    }

    private static func systemErrorFacts(_ error: Error) -> [String: Any]? {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return ["cancelled": true]
            case .cannotFindHost, .dnsLookupFailed:
                return ["dns": true]
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                 .clientCertificateRejected, .clientCertificateRequired:
                return ["tls": true]
            case .cannotConnectToHost:
                // URLSession abstracts the refused connect; the errno is its honest fact form.
                return ["errno": Int(POSIXErrorCode.ECONNREFUSED.rawValue)]
            case .notConnectedToInternet, .networkConnectionLost:
                return ["errno": Int(POSIXErrorCode.ENETUNREACH.rawValue)]
            case .timedOut:
                return ["timeout": true]
            default:
                break
            }
        }

        if let nwError = error as? NWError {
            switch nwError {
            case .posix(let code):
                return ["errno": Int(code.rawValue)]
            case .dns:
                return ["dns": true]
            case .tls:
                return ["tls": true]
            default:
                break
            }
        }

        // POSIXError and raw POSIX-domain NSErrors take the same validated path: casting an
        // arbitrary NSPOSIXErrorDomain error to POSIXError first would trap inside Foundation's
        // bridged `.code` getter when the code is no POSIXErrorCode, and the round-trip keeps
        // such codes from being presented to the shared ladder as errnos at all. NEVPN errors are
        // the OS refusing the tunnel (revoked consent).
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain,
           let rawValue = Int32(exactly: nsError.code),
           let code = POSIXErrorCode(rawValue: rawValue) {
            return ["errno": Int(code.rawValue)]
        }
        if nsError.domain == NEVPNErrorDomain {
            return ["permission_denied": true]
        }

        return nil
    }

    private static func serialize(_ facts: [String: Any]) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: facts),
            let json = String(data: data, encoding: .utf8)
        else {
            // Unrepresentable input degrades to the classifier's bounded residual.
            return "{}"
        }
        return json
    }

    private static func nativeClassify(_ inputJSON: String) -> String {
        #if canImport(Libbox)
        return LibboxOpenRungClassifyFailure(inputJSON)
        #else
        // Only the engine-free test bundle compiles this branch (see project.yml). The suites pin
        // the facts this file extracts and the Go suite pins facts→token, so no token may be
        // decided here; the bounded residual keeps an accidental call harmless.
        return "unknown"
        #endif
    }

    /// The human-readable message for `error` — the source for `failure_detail`.
    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// The error's type name — kept as the `error_type` attribute for dashboard continuity.
    static func errorType(_ error: Error) -> String {
        String(describing: type(of: error))
    }

    /// The underlying/root error's description, bounded by the binding to the broker's
    /// 256-UTF-8-byte attribute limit. This keeps `failure_detail` aligned with `failure_reason`:
    /// wrapper errors like `allRelaysFailed` classify on their underlying cause, so their detail
    /// should too.
    static func detail(_ error: Error) -> String {
        truncate(detailDescription(error))
    }

    private static func detailDescription(_ error: Error, depth: Int = 0) -> String {
        if depth < 8, let underlying = underlyingDetailError(error) {
            return detailDescription(underlying, depth: depth + 1)
        }
        if let ticketStatus = error as? WssTicketStatusError {
            return "WSS ticket HTTP status \(ticketStatus.status)"
        }
        return describe(error)
    }

    private static func underlyingDetailError(_ error: Error) -> Error? {
        if let direct = error as? DirectPathError { return direct.underlying }
        if let local = error as? LocalTunnelError { return local.underlying }
        if let wss = error as? WssTransportError { return wss.underlying }
        if let dnsPath = error as? DnsPathUnverifiedError { return dnsPath.underlying }
        if let probe = error as? InternetProbeError { return probe.underlyingError }
        if let recorded = error as? RelayFailureAlreadyRecordedError {
            if let lastWssFailure = recorded.wssFailures.last {
                return lastWssFailure.underlying
            }
            return recorded.directFailure.underlying
        }
        if case let PunchNativeClientError.establishmentFailed(_, detail, _) = error,
           detail.isEmpty == false {
            return NSError(
                domain: "OpenRungPunch",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
        }
        if let tunnelError = error as? PacketTunnelError {
            switch tunnelError {
            case .relayUnreachable(_, _, let underlying), .allRelaysFailed(let underlying):
                return underlying
            default:
                return nil
            }
        }

        return (error as NSError).userInfo[NSUnderlyingErrorKey] as? Error
    }

    /// Bounds `value` to the broker's per-attribute limit (256 UTF-8 bytes, cut on a rune
    /// boundary) through the binding, whose policy it is (`connectcore`'s ErrorDetail).
    static func truncate(_ value: String) -> String {
        #if canImport(Libbox)
        return LibboxOpenRungFailureDetail(value)
        #else
        // Only the engine-free test bundle compiles this branch; it exercises message selection,
        // never the bound. Every shipping build routes through the binding.
        return value
        #endif
    }
}
