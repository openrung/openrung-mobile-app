import Foundation

struct PunchNativeConnectResult: Equatable, Sendable {
    let bridgeHost: String
    let bridgePort: Int
    let peerIP: String
    let sessionID: String
    let natClass: String
    let rttMillis: Int64
}

/// Closed taxonomy for establishment failures returned by the Go binding. Never forward the
/// binding's raw reason to telemetry: declined messages and future native values are unbounded.
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

protocol PunchNativeSession: AnyObject, Sendable {
    func establish() async throws -> PunchNativeConnectResult
    func waitForUnexpectedClose() async -> String
    func close()
}

struct PunchCoordinatorTLSConfiguration: Equatable, Sendable {
    let allowSelfSigned: Bool
    let certificateSHA256: String
}

struct PunchCoordinatorConfiguration: Equatable, Sendable {
    let baseURL: String
    let relayID: String
    let tls: PunchCoordinatorTLSConfiguration
}

/// Accepts only the explicit endpoint covered by the broker-signed relay descriptor. In
/// particular, this never derives the desktop client's legacy `http://publicHost:9444` endpoint.
enum PunchCoordinatorPolicy {
    static func configuration(for relay: RelayDescriptor) -> PunchCoordinatorConfiguration? {
        guard relay.punchCapable else { return nil }
        guard let baseURL = validatedCoordinatorURL(relay.punchEndpoint) else { return nil }
        guard let tls = tlsConfiguration(for: baseURL) else { return nil }
        return PunchCoordinatorConfiguration(baseURL: baseURL, relayID: relay.id, tls: tls)
    }

    static func validatedCoordinatorURL(_ rawValue: String) -> String? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") {
            value.removeLast()
        }
        guard value.isEmpty == false else { return nil }
        guard value.unicodeScalars.allSatisfy({
            CharacterSet.whitespacesAndNewlines.contains($0) == false &&
                CharacterSet.controlCharacters.contains($0) == false
        }) else {
            return nil
        }
        guard
            let components = URLComponents(string: value),
            components.scheme?.lowercased() == "https",
            let host = components.host?.lowercased(),
            host.isEmpty == false,
            host.contains("@") == false,
            host.contains("\\") == false,
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil,
            components.url != nil,
            hasValidExplicitPort(in: value)
        else {
            return nil
        }
        return value
    }

    /// Bare-IP HTTPS cannot use the deployed public-CA path, so an exact app pin is mandatory.
    /// Unpinned DNS hostnames retain ordinary CA and hostname verification in Go.
    static func tlsConfiguration(for coordinatorURL: String) -> PunchCoordinatorTLSConfiguration? {
        guard
            let validatedURL = validatedCoordinatorURL(coordinatorURL),
            let components = URLComponents(string: validatedURL),
            let host = components.host?.lowercased(),
            host.isEmpty == false
        else {
            return nil
        }
        if let pin = AppConfig.punchCoordinatorCertificateSHA256ByHost[host] {
            return PunchCoordinatorTLSConfiguration(
                allowSelfSigned: true,
                certificateSHA256: pin
            )
        }
        guard looksLikeIPLiteral(host) == false else { return nil }
        return PunchCoordinatorTLSConfiguration(allowSelfSigned: false, certificateSHA256: "")
    }

    private static func hasValidExplicitPort(in url: String) -> Bool {
        guard let schemeEnd = url.range(of: "://")?.upperBound else { return false }
        let remainder = url[schemeEnd...]
        let authorityEnd = remainder.firstIndex(of: "/") ?? remainder.endIndex
        let authority = remainder[..<authorityEnd]
        guard
            authority.isEmpty == false,
            authority.contains("@") == false,
            authority.contains("%") == false,
            authority.contains("\\") == false
        else {
            return false
        }

        if authority.first == "[" {
            guard let closingBracket = authority.firstIndex(of: "]") else { return false }
            let suffix = authority[authority.index(after: closingBracket)...]
            if suffix.isEmpty { return true }
            guard suffix.first == ":" else { return false }
            return isValidPort(suffix.dropFirst())
        }

        let colonCount = authority.reduce(into: 0) { count, character in
            if character == ":" { count += 1 }
        }
        if colonCount == 0 { return true }
        guard colonCount == 1, let colon = authority.lastIndex(of: ":") else { return false }
        return isValidPort(authority[authority.index(after: colon)...])
    }

    private static func isValidPort(_ value: Substring) -> Bool {
        guard
            value.isEmpty == false,
            value.allSatisfy({ $0 >= "0" && $0 <= "9" }),
            let port = Int(value)
        else {
            return false
        }
        return (1...65_535).contains(port)
    }

    private static func looksLikeIPLiteral(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let unqualified = host.hasSuffix(".") ? String(host.dropLast()) : host
        let parts = unqualified.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            part.isEmpty == false && part.allSatisfy { $0 >= "0" && $0 <= "9" }
        }
    }
}

/// Pure validation kept outside the Libbox branch so hostless tests exercise the exact boundary
/// applied to a native result. Hostnames (including `localhost`) are intentionally rejected.
enum PunchNativeResultValidator {
    static func validatedResult(
        bridgeHost: String,
        bridgePort: Int,
        peerIP: String,
        sessionID: String,
        natClass: String,
        rttMillis: Int64
    ) throws -> PunchNativeConnectResult {
        guard isLoopbackLiteral(bridgeHost), (1...65_535).contains(bridgePort) else {
            throw PunchNativeClientError.invalidLoopbackEndpoint
        }
        return PunchNativeConnectResult(
            bridgeHost: bridgeHost,
            bridgePort: bridgePort,
            peerIP: peerIP,
            sessionID: sessionID,
            natClass: natClass,
            rttMillis: rttMillis
        )
    }

    static func isLoopbackLiteral(_ host: String) -> Bool {
        let normalized = host.lowercased()
        if normalized == "::1" || normalized == "[::1]" { return true }
        let octets = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets.first == "127" else { return false }
        return octets.allSatisfy { octet in
            octet.isEmpty == false &&
                octet.allSatisfy { $0 >= "0" && $0 <= "9" } &&
                UInt8(octet) != nil
        }
    }
}

/// AsyncStream continuation and NSLock are both thread-safe. This small adapter gives the native
/// callback one terminal event, bounds native text, and lets explicit close finish waiters.
final class PunchNativeCloseSignal: @unchecked Sendable {
    let events: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation

    init() {
        var captured: AsyncStream<String>.Continuation?
        events = AsyncStream { captured = $0 }
        continuation = captured!
    }

    func reportUnexpectedClose(_ reason: String?) {
        let cleaned = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let bounded = cleaned.isEmpty
            ? "direct QUIC path closed"
            : String(cleaned.prefix(256))
        continuation.yield(bounded)
        continuation.finish()
    }

    func finish() {
        continuation.finish()
    }
}

/// Claims the close transition before running the action, making close safe under cancellation,
/// explicit disconnect, and establishment failure races.
final class PunchNativeCloseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isClosed = false

    @discardableResult
    func runOnce(_ action: () -> Void) -> Bool {
        lock.lock()
        guard isClosed == false else {
            lock.unlock()
            return false
        }
        isClosed = true
        lock.unlock()
        action()
        return true
    }
}

#if canImport(Libbox)
import Libbox

enum NativePunchSessionFactory {
    static func make(relay: RelayDescriptor) throws -> (any PunchNativeSession)? {
        guard let configuration = PunchCoordinatorPolicy.configuration(for: relay) else {
            return nil
        }
        let signal = PunchNativeCloseSignal()
        let listener = NativePunchCloseListener(signal: signal)
        guard let client = LibboxNewOpenRungPunchClientForIOS(
            configuration.baseURL,
            configuration.relayID,
            configuration.tls.allowSelfSigned,
            configuration.tls.certificateSHA256,
            listener
        ) else {
            throw PunchNativeClientError.creationFailed
        }
        return LibboxPunchNativeSession(client: client, listener: listener, signal: signal)
    }
}

private final class NativePunchCloseListener: NSObject,
    LibboxOpenRungPunchListenerProtocol,
    @unchecked Sendable
{
    private let signal: PunchNativeCloseSignal

    init(signal: PunchNativeCloseSignal) {
        self.signal = signal
        super.init()
    }

    func closed(_ reason: String?) {
        signal.reportUnexpectedClose(reason)
    }
}

private final class LibboxPunchNativeSession: PunchNativeSession, @unchecked Sendable {
    private let client: LibboxOpenRungPunchClient
    // Retain the interface object for as long as Go may call it.
    private let listener: NativePunchCloseListener
    private let signal: PunchNativeCloseSignal
    private let closeGate = PunchNativeCloseGate()

    init(
        client: LibboxOpenRungPunchClient,
        listener: NativePunchCloseListener,
        signal: PunchNativeCloseSignal
    ) {
        self.client = client
        self.listener = listener
        self.signal = signal
    }

    func establish() async throws -> PunchNativeConnectResult {
        do {
            let result: LibboxOpenRungPunchResult? = await withTaskCancellationHandler {
                await Task.detached { self.client.establish() }.value
            } onCancel: {
                self.close()
            }
            try Task.checkCancellation()
            guard let result else {
                throw PunchNativeClientError.establishmentFailed(
                    reason: .transport,
                    detail: "",
                    natClass: ""
                )
            }
            guard result.succeeded() else {
                let nativeReason = result.reason()
                let reason = PunchNativeFailureReason(nativeReason: nativeReason)
                if reason == .cancelled { throw CancellationError() }
                throw PunchNativeClientError.establishmentFailed(
                    reason: reason,
                    detail: String(result.errorText().prefix(256)),
                    natClass: String(result.natClass().prefix(64))
                )
            }
            return try PunchNativeResultValidator.validatedResult(
                bridgeHost: result.bridgeHost(),
                bridgePort: Int(result.bridgePort()),
                peerIP: result.peerIP(),
                sessionID: result.sessionID(),
                natClass: result.natClass(),
                rttMillis: result.rttMillis()
            )
        } catch {
            // A failed attempt owns no reusable adapter. Close is also the cancellation path for
            // blocking HTTP, UDP, and QUIC work and is explicitly idempotent.
            close()
            throw error
        }
    }

    func waitForUnexpectedClose() async -> String {
        // Touch the retained listener here so future refactors cannot accidentally drop it while
        // Go still owns the interface reference.
        _ = listener
        for await reason in signal.events { return reason }
        return "NAT-punch session closed"
    }

    func close() {
        closeGate.runOnce {
            client.close()
            signal.finish()
        }
    }
}

#else

enum NativePunchSessionFactory {
    static func make(relay: RelayDescriptor) throws -> (any PunchNativeSession)? {
        guard PunchCoordinatorPolicy.configuration(for: relay) != nil else { return nil }
        throw PunchNativeClientError.unavailable
    }
}

#endif
