// Frozen error shapes for ADR-001 classification vectors, never compiled into a shipping target.
import Foundation

struct DirectPathError: LocalizedError {
    let stage: String
    let underlying: Error

    var errorDescription: String? {
        "Direct Reality path failed at \(stage): \(underlying.localizedDescription)"
    }
}

struct LocalTunnelError: LocalizedError {
    let stage: String
    let underlying: Error

    var errorDescription: String? {
        "Local tunnel setup failed at \(stage): \(underlying.localizedDescription)"
    }
}

struct WssTransportError: LocalizedError {
    let stage: String
    let frontID: String
    let underlying: Error

    var errorDescription: String? {
        "WSS front \(frontID) failed at \(stage): \(underlying.localizedDescription)"
    }
}

struct RelayFailureAlreadyRecordedError: LocalizedError {
    let directFailure: DirectPathError
    let wssFailures: [WssTransportError]

    var errorDescription: String? {
        wssFailures.last?.localizedDescription ?? directFailure.localizedDescription
    }
}

/// The native implementation delegates strict URL/version/order validation to wsscore. Swift never
/// reproduces those rules and never rewrites signed input.

enum WssNativeClientError: LocalizedError {
    case unavailable
    case creationFailed
    case connectionFailed(reason: String)
    case invalidLoopbackEndpoint

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The native WSS transport is unavailable."
        case .creationFailed:
            return "The native WSS client could not be created."
        case .connectionFailed(let reason):
            return "The WSS transport failed (\(reason))."
        case .invalidLoopbackEndpoint:
            return "The native WSS transport returned an invalid loopback endpoint."
        }
    }

    /// Reasons produced before a remote WSS data path exists are local/native failures. They must
    /// abort the ladder instead of consuming another ticket or affecting relay health.
    var isLocalFailure: Bool {
        switch self {
        case .unavailable, .creationFailed, .invalidLoopbackEndpoint:
            return true
        case .connectionFailed(let reason):
            return ["client", "front", "adapter", "protect"].contains(reason)
        }
    }

    /// Stable, bounded telemetry taxonomy. Native reason strings are deliberately matched against
    /// the binding's closed enum instead of being interpolated into telemetry; an unfamiliar value
    /// is a generic WSS transport failure, not an unbounded/high-cardinality reason.
    var failureReason: String {
        switch self {
        case .unavailable:
            return "wss_client_unavailable"
        case .creationFailed:
            return "wss_client_creation_failed"
        case .invalidLoopbackEndpoint:
            return "wss_invalid_loopback_endpoint"
        case .connectionFailed(let reason):
            switch reason {
            case "cancelled": return "cancelled"
            case "client": return "wss_client_failed"
            case "front": return "wss_invalid_front"
            case "adapter": return "wss_invalid_loopback_endpoint"
            case "protect": return "wss_socket_protection_failed"
            case "transport": return "wss_transport_failed"
            default: return "wss_transport_failed"
            }
        }
    }
}

/// How a native WSS transport session ended. `graceful` means the transport ended in an orderly
/// way — the relay closed the session, or its bounded lifetime elapsed — rather than the path
/// breaking. The transport reports it; it is never inferred from a session simply stopping,
/// because an orderly close and a censored path both stop the session.

enum PunchNativeFailureReason: String, Equatable, Sendable {
    case client
    case configuration = "config"
    case socket
    case socketProtection = "protect"
    case nonce
    case discovery
    case request
    case declined
    case session
    case token
    case certificate
    case punch
    case quic
    case bridge
    case transport
    case cancelled

    init(nativeReason: String) {
        let normalized = nativeReason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("declined:") {
            self = .declined
            return
        }
        switch normalized {
        case "client":
            self = .client
        case "config":
            self = .configuration
        case "socket":
            self = .socket
        case "protect":
            self = .socketProtection
        case "nonce":
            self = .nonce
        case "discovery":
            self = .discovery
        case "request":
            self = .request
        case "session":
            self = .session
        case "token":
            self = .token
        case "certificate":
            self = .certificate
        case "punch":
            self = .punch
        case "quic":
            self = .quic
        case "bridge", "adapter":
            self = .bridge
        case "cancelled":
            self = .cancelled
        default:
            self = .transport
        }
    }
}

enum PunchNativeClientError: LocalizedError, Equatable {
    case unavailable
    case creationFailed
    case establishmentFailed(
        reason: PunchNativeFailureReason,
        detail: String,
        natClass: String
    )
    case invalidLoopbackEndpoint

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The native NAT-punch transport is unavailable."
        case .creationFailed:
            return "The native NAT-punch client could not be created."
        case .establishmentFailed(let reason, _, _):
            return "The native NAT-punch transport failed (\(reason.rawValue))."
        case .invalidLoopbackEndpoint:
            return "The native NAT-punch transport returned an invalid loopback endpoint."
        }
    }

    /// Stable, bounded telemetry taxonomy. Raw native detail remains available on the error for
    /// bounded diagnostics, but can never create high-cardinality failure-reason attributes.
    var failureReason: String {
        switch self {
        case .unavailable:
            return "punch_client_unavailable"
        case .creationFailed:
            return "punch_client_creation_failed"
        case .invalidLoopbackEndpoint:
            return "punch_invalid_loopback_endpoint"
        case .establishmentFailed(let reason, _, _):
            switch reason {
            case .client: return "punch_client_failed"
            case .configuration: return "punch_configuration_failed"
            case .socket: return "punch_socket_failed"
            case .socketProtection: return "punch_socket_protection_failed"
            case .nonce: return "punch_nonce_failed"
            case .discovery: return "punch_discovery_failed"
            case .request: return "punch_request_failed"
            case .declined: return "punch_declined"
            case .session: return "punch_invalid_session"
            case .token: return "punch_invalid_token"
            case .certificate: return "punch_invalid_certificate"
            case .punch: return "punch_udp_failed"
            case .quic: return "punch_quic_failed"
            case .bridge: return "punch_bridge_failed"
            case .transport: return "punch_transport_failed"
            case .cancelled: return "cancelled"
            }
        }
    }
}


struct WssTicketStatusError: Error, Equatable { let status: Int; let retryAfterMilliseconds: Int64? }

let startupStageDnsProbe = "dns_probe"
