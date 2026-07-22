import Foundation

struct WssNativeConnectResult: Equatable, Sendable {
    let bridgeHost: String
    let bridgePort: Int
}

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

protocol WssNativeSession: AnyObject, Sendable {
    func connect() async throws -> WssNativeConnectResult
    func waitForUnexpectedClose() async -> String
    func close()
}

#if canImport(Libbox)
import Libbox

struct NativeWssFrontValidator: WssFrontSetValidating {
    func validateExact(_ fronts: [WssFrontDescriptor]) throws {
        let data = try JSONEncoder().encode(fronts)
        guard
            let json = String(data: data, encoding: .utf8),
            LibboxOpenRungValidateWSSFronts(json)
        else {
            throw WssNativeClientError.unavailable
        }
    }
}

enum NativeWssSessionFactory {
    static func make(frontURL: String, ticket: String) throws -> any WssNativeSession {
        let listener = NativeWssCloseListener()
        guard let client = LibboxNewOpenRungWSSClientForIOS(frontURL, ticket, listener) else {
            throw WssNativeClientError.creationFailed
        }
        return LibboxWssNativeSession(client: client, listener: listener)
    }
}

private final class NativeWssCloseListener: NSObject, LibboxOpenRungWSSListenerProtocol, @unchecked Sendable {
    let events: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation

    override init() {
        var captured: AsyncStream<String>.Continuation?
        events = AsyncStream { captured = $0 }
        continuation = captured!
        super.init()
    }

    func closed(_ reason: String?) {
        continuation.yield(reason?.isEmpty == false ? reason! : "WSS session stopped unexpectedly")
        continuation.finish()
    }

    func finish() {
        continuation.finish()
    }
}

private final class LibboxWssNativeSession: WssNativeSession, @unchecked Sendable {
    private let client: LibboxOpenRungWSSClient
    private let listener: NativeWssCloseListener

    init(client: LibboxOpenRungWSSClient, listener: NativeWssCloseListener) {
        self.client = client
        self.listener = listener
    }

    func connect() async throws -> WssNativeConnectResult {
        do {
            let result: LibboxOpenRungWSSResult? = await withTaskCancellationHandler {
                await Task.detached { self.client.connect() }.value
            } onCancel: {
                self.client.close()
            }
            try Task.checkCancellation()
            guard let result else { throw WssNativeClientError.connectionFailed(reason: "transport") }
            guard result.succeeded() else {
                let reason = result.reason().isEmpty ? "transport" : result.reason()
                if reason == "cancelled" { throw CancellationError() }
                throw WssNativeClientError.connectionFailed(reason: reason)
            }
            let host = result.bridgeHost()
            let port = Int(result.bridgePort())
            guard Self.isLoopbackLiteral(host), (1...65_535).contains(port) else {
                throw WssNativeClientError.invalidLoopbackEndpoint
            }
            return WssNativeConnectResult(bridgeHost: host, bridgePort: port)
        } catch {
            // Failed dials never own a reusable ticket or adapter. Close also cancels a blocking
            // native call, and the Go wrapper is explicitly idempotent.
            client.close()
            listener.finish()
            throw error
        }
    }

    func waitForUnexpectedClose() async -> String {
        for await reason in listener.events { return reason }
        return "WSS session closed"
    }

    func close() {
        client.close()
        listener.finish()
    }

    private static func isLoopbackLiteral(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if normalized == "::1" { return true }
        let octets = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets.first == "127" else { return false }
        return octets.allSatisfy { UInt8($0) != nil }
    }
}

#else

struct NativeWssFrontValidator: WssFrontSetValidating {
    func validateExact(_: [WssFrontDescriptor]) throws {
        throw WssNativeClientError.unavailable
    }
}

enum NativeWssSessionFactory {
    static func make(frontURL _: String, ticket _: String) throws -> any WssNativeSession {
        throw WssNativeClientError.unavailable
    }
}

#endif
