import Foundation
import Network
import NetworkExtension

struct TunnelProbeEndpoint: Equatable, Sendable {
    let url: URL
    let host: String
    let port: Int
    let requestTarget: String

    init(_ value: String) throws {
        guard
            let url = URL(string: value),
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == "https",
            let host = components.host,
            host.isEmpty == false,
            components.user == nil,
            components.password == nil
        else {
            throw URLError(.badURL)
        }
        let port = components.port ?? 443
        guard (1...65_535).contains(port) else { throw URLError(.badURL) }
        var target = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery, query.isEmpty == false { target += "?\(query)" }
        self.url = url
        self.host = host
        self.port = port
        requestTarget = target
    }

    var httpRequest: Data {
        let authority = port == 443 ? host : "\(host):\(port)"
        let request = [
            "GET \(requestTarget) HTTP/1.1",
            "Host: \(authority)",
            "Connection: close",
            "Cache-Control: no-cache",
            "User-Agent: OpenRung-PacketTunnel-Probe",
            "",
            "",
        ].joined(separator: "\r\n")
        return Data(request.utf8)
    }
}

protocol ThroughTunnelHTTPTransport: Sendable {
    func responseHead(for endpoint: TunnelProbeEndpoint) async throws -> Data
}

/// A provider/API state failure is local evidence and must never be converted into WSS fallback.
enum PacketTunnelProbeTransportError: Error {
    case invalidConnectionState
}

/// Explicit Apple through-TUN transport. A URLSession created by the extension is intentionally
/// excluded from its own packet tunnel; this API is the iOS 16/17 guarantee that the probe traverses
/// the active Reality/libbox path instead of escaping on the hardware interface.
private final class ProviderThroughTunnelHTTPTransport: ThroughTunnelHTTPTransport, @unchecked Sendable {
    private weak var provider: NEPacketTunnelProvider?

    init(provider: NEPacketTunnelProvider) {
        self.provider = provider
    }

    func responseHead(for endpoint: TunnelProbeEndpoint) async throws -> Data {
        guard let provider else { throw URLError(.cancelled) }
        let remote = NWHostEndpoint(hostname: endpoint.host, port: String(endpoint.port))
        let connection = provider.createTCPConnectionThroughTunnel(
            to: remote,
            enableTLS: true,
            tlsParameters: nil,
            delegate: nil
        )
        defer { connection.cancel() }
        return try await withTaskCancellationHandler {
            try await waitUntilConnected(connection)
            try await write(endpoint.httpRequest, to: connection)
            return try await readResponseHead(from: connection)
        } onCancel: {
            connection.cancel()
        }
    }

    private func waitUntilConnected(_ connection: NWTCPConnection) async throws {
        let observation = ObservationBox()
        defer { observation.invalidate() }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let gate = ContinuationGate<Void>(continuation)
            let token = connection.observe(\.state, options: [.initial, .new]) { observed, _ in
                switch observed.state {
                case .connected:
                    gate.resume(returning: ())
                case .waiting, .disconnected:
                    gate.resume(throwing: observed.error ?? URLError(.cannotConnectToHost))
                case .cancelled:
                    gate.resume(throwing: CancellationError())
                case .invalid:
                    gate.resume(throwing: PacketTunnelProbeTransportError.invalidConnectionState)
                case .connecting:
                    break
                @unknown default:
                    gate.resume(throwing: URLError(.unknown))
                }
            }
            observation.set(token)
        }
    }

    private func write(_ data: Data, to connection: NWTCPConnection) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.write(data) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
    }

    private func readResponseHead(from connection: NWTCPConnection) async throws -> Data {
        var received = Data()
        while received.count < 16 * 1_024 {
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                connection.readMinimumLength(1, maximumLength: 4 * 1_024) { data, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, data.isEmpty == false { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: URLError(.zeroByteResource)) }
                }
            }
            received.append(chunk)
            if let boundary = received.range(of: Data("\r\n\r\n".utf8)) {
                return Data(received[..<boundary.upperBound])
            }
        }
        throw URLError(.dataLengthExceedsMaximum)
    }
}

/// Internet proof that is guaranteed to traverse the packet tunnel. The injected transport keeps
/// endpoint/status/retry policy hostlessly testable without opening sockets.
struct PacketTunnelInternetProbe: Sendable {
    static let defaultEndpointStrings = [
        "https://www.gstatic.com/generate_204",
        "https://cp.cloudflare.com/generate_204",
    ]

    private let endpoints: [TunnelProbeEndpoint]
    private let transport: any ThroughTunnelHTTPTransport
    private let deadlineMilliseconds: UInt64
    private let retryDelayNanoseconds: UInt64
    private let requestTimeoutMilliseconds: UInt64

    init(
        tunnelProvider: NEPacketTunnelProvider,
        endpoints: [String] = Self.defaultEndpointStrings
    ) throws {
        try self.init(
            endpoints: endpoints,
            transport: ProviderThroughTunnelHTTPTransport(provider: tunnelProvider)
        )
    }

    init(
        endpoints: [String] = Self.defaultEndpointStrings,
        transport: any ThroughTunnelHTTPTransport,
        deadlineMilliseconds: UInt64 = 12_000,
        retryDelayNanoseconds: UInt64 = 500_000_000,
        requestTimeoutMilliseconds: UInt64 = 3_000
    ) throws {
        self.endpoints = try endpoints.map(TunnelProbeEndpoint.init)
        guard self.endpoints.isEmpty == false else { throw URLError(.badURL) }
        self.transport = transport
        self.deadlineMilliseconds = deadlineMilliseconds
        self.retryDelayNanoseconds = retryDelayNanoseconds
        self.requestTimeoutMilliseconds = requestTimeoutMilliseconds
    }

    func verify() async throws -> InternetProbeResult {
        let started = DispatchTime.now().uptimeNanoseconds
        let deadline = started + deadlineMilliseconds * 1_000_000
        var lastError: Error?
        while DispatchTime.now().uptimeNanoseconds < deadline {
            do {
                return try await verifyOnce(startedNanoseconds: started)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
            try await Task.sleep(nanoseconds: retryDelayNanoseconds)
        }
        throw InternetProbeError.unreachable(lastError)
    }

    func verifyOnce() async throws -> InternetProbeResult {
        try await verifyOnce(startedNanoseconds: DispatchTime.now().uptimeNanoseconds)
    }

    private func verifyOnce(startedNanoseconds: UInt64) async throws -> InternetProbeResult {
        var lastError: Error?
        for endpoint in endpoints {
            do {
                let head = try await withTimeout(milliseconds: requestTimeoutMilliseconds) {
                    try await transport.responseHead(for: endpoint)
                }
                let status = try Self.parseHTTPStatus(head)
                guard InternetProbe.acceptsHTTPStatus(status) else { throw URLError(.badServerResponse) }
                return InternetProbeResult(
                    endpoint: endpoint.url.absoluteString,
                    durationMs: Int64(
                        (DispatchTime.now().uptimeNanoseconds - startedNanoseconds) / 1_000_000
                    )
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw InternetProbeError.unreachable(lastError)
    }

    static func parseHTTPStatus(_ head: Data) throws -> Int {
        guard
            head.count <= 16 * 1_024,
            let text = String(data: head, encoding: .utf8),
            let firstLine = text.components(separatedBy: "\r\n").first
        else { throw URLError(.cannotParseResponse) }
        let parts = firstLine.split(separator: " ", omittingEmptySubsequences: true)
        guard
            parts.count >= 2,
            parts[0].hasPrefix("HTTP/"),
            let status = Int(parts[1]),
            (100...599).contains(status)
        else { throw URLError(.cannotParseResponse) }
        return status
    }

    private func withTimeout<T: Sendable>(
        milliseconds: UInt64,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw URLError(.timedOut) }
            return result
        }
    }
}

private final class ObservationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var observation: NSKeyValueObservation?

    func set(_ value: NSKeyValueObservation) {
        lock.lock()
        observation = value
        lock.unlock()
    }

    func invalidate() {
        lock.lock()
        let value = observation
        observation = nil
        lock.unlock()
        value?.invalidate()
    }
}

private final class ContinuationGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Value) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let value = continuation
        continuation = nil
        return value
    }
}
