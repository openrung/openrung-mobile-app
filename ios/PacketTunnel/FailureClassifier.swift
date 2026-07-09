import Foundation
import Network
import NetworkExtension

/// Classifies a connection failure into a stable, lowercase snake_case reason token shared with the
/// OpenRung Go clients (desktop/CLI) and honored by the broker's "Failure reasons" dashboard.
///
/// The token set and precedence mirror the Go classifier (`internal/clienttelemetry/classify.go` in
/// the sibling `openrung` repo): cancellation → relay-selection sentinels → broker HTTP status →
/// socket errno → DNS (before generic timeout, the more actionable signal) → TLS → permission →
/// engine-exit → generic timeout → `unknown`.
///
/// `PacketTunnelError.allRelaysFailed` / `.relayUnreachable` carry the underlying `Error`, so the
/// real root cause is unwrapped and classified on its merits instead of being reported as the
/// generic wrapper type (which is why the dashboard used to show generic Swift type names).
enum FailureClassifier {
    private static let maxDetailBytes = 256

    /// The reason token for `error`.
    static func classify(_ error: Error) -> String {
        // (1) cancellation (user stop / task cancellation)
        if error is CancellationError { return "cancelled" }

        // (2) app relay-selection sentinels; unwrap the wrappers that carry the real cause.
        if let tunnelError = error as? PacketTunnelError {
            switch tunnelError {
            case .noUsableRelay:
                return "no_usable_relay"
            case .noRelayInCountry:
                return "no_relay_in_country"
            case .relayNotAvailable:
                return "relay_not_in_list"
            case .relayUnreachable(_, _, let underlying):
                if let underlying { return classify(underlying) }
                return "network_unreachable"
            case .allRelaysFailed(let underlying):
                if let underlying { return classify(underlying) }
                return "no_usable_relay"
            }
        }

        // (3) broker HTTP status (429 → rate_limited, else http_<code>)
        if let brokerError = error as? BrokerClientError {
            switch brokerError {
            case .httpStatus(let code):
                return code == 429 ? "rate_limited" : "http_\(code)"
            case .invalidResponse:
                return "unknown"
            }
        }

        // App reachability timeout (raised by the NWConnection probe's own deadline).
        if let reachabilityError = error as? RelayReachabilityError {
            switch reachabilityError {
            case .timeout: return "timeout"
            case .invalidPort: return "unknown"
            }
        }

        // (4)–(9) system errors: socket errno → DNS → TLS → permission → timeout. A single
        // URLError/NWError/POSIXError maps to exactly one of these, so DNS-before-timeout holds
        // naturally (distinct codes) without a chain walk.
        if let token = classifySystemError(error) { return token }

        // (8) embedded proxy engine failed to start / stopped unexpectedly. It carries no nested
        // Error, so it never coexists with a higher-precedence system error above.
        if error is PacketTunnelProxyEngineError { return "process_exited" }

        return "unknown"
    }

    private static func classifySystemError(_ error: Error) -> String? {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return "cancelled"
            case .cannotFindHost, .dnsLookupFailed:
                return "dns_failure"
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                 .clientCertificateRejected, .clientCertificateRequired:
                return "tls_handshake"
            case .cannotConnectToHost:
                return "connection_refused"
            case .notConnectedToInternet, .networkConnectionLost:
                return "network_unreachable"
            case .timedOut:
                return "timeout"
            default:
                break
            }
        }

        if let nwError = error as? NWError {
            switch nwError {
            case .posix(let code):
                if let token = classifyPOSIX(code) { return token }
            case .dns:
                return "dns_failure"
            case .tls:
                return "tls_handshake"
            @unknown default:
                break
            }
        }

        if let posixError = error as? POSIXError, let token = classifyPOSIX(posixError.code) {
            return token
        }

        // Fallbacks for errors bridged as NSError (raw POSIX-domain errno, NEVPN/permission errors).
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain,
           let code = POSIXErrorCode(rawValue: Int32(nsError.code)),
           let token = classifyPOSIX(code) {
            return token
        }
        if nsError.domain == NEVPNErrorDomain {
            return "permission_denied"
        }

        return nil
    }

    private static func classifyPOSIX(_ code: POSIXErrorCode) -> String? {
        switch code {
        case .ECONNREFUSED: return "connection_refused"
        case .ECONNRESET: return "connection_reset"
        case .ENETUNREACH, .EHOSTUNREACH: return "network_unreachable"
        case .ETIMEDOUT: return "timeout"
        case .EACCES, .EPERM: return "permission_denied"
        default: return nil
        }
    }

    /// The human-readable message for `error` — the source for `failure_detail`.
    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// The error's type name — kept as the `error_type` attribute for dashboard continuity.
    static func errorType(_ error: Error) -> String {
        String(describing: type(of: error))
    }

    /// `describe(error)` truncated to fit the broker's 256-UTF-8-byte attribute limit.
    static func detail(_ error: Error) -> String {
        truncate(describe(error))
    }

    /// Truncates `value` to at most `maxBytes` UTF-8 bytes without splitting a multi-byte character:
    /// the boundary is backed off past any UTF-8 continuation byte (`0b10xxxxxx`). The broker rejects
    /// attribute values whose UTF-8 encoding exceeds 256 bytes.
    static func truncate(_ value: String, maxBytes: Int = maxDetailBytes) -> String {
        let bytes = Array(value.utf8)
        if bytes.count <= maxBytes { return value }
        var end = maxBytes
        while end > 0 && (bytes[end] & 0xC0) == 0x80 { end -= 1 }
        return String(decoding: bytes[0..<end], as: UTF8.self)
    }
}
