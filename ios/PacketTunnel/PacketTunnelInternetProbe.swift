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

protocol ThroughTunnelProbeTransport: Sendable {
    /// Performs an uncached A lookup through the TUN's DNS listener. This is intentionally
    /// separate from the HTTPS connection so a cached/system resolution cannot satisfy health.
    func resolveFreshA(host: String) async throws
    func responseHead(for endpoint: TunnelProbeEndpoint) async throws -> Data
}

/// The production handoff from a verified startup to visible CONNECTED state. Keeping this
/// boundary explicit makes it impossible for a failed DNS/HTTPS proof to invoke the publisher,
/// and lets the China-bypass regression exercise the same ordering without a live extension.
enum StartupConnectionPublicationGate {
    @discardableResult
    static func run<Value>(
        establishAndVerify: () async throws -> Value,
        publishConnected: (Value) -> Void
    ) async rethrows -> Value {
        let verified = try await establishAndVerify()
        publishConnected(verified)
        return verified
    }
}

/// Minimal DNS wire encoder/parser for the explicit through-TUN health lookup. Parsing is strict:
/// a reply must match the transaction, be a complete successful response, and contain an IPv4
/// address answer. A syntactically valid but empty response is not proof of working DNS.
enum TunnelDNSAProbe {
    static func makeQuery(host: String, transactionID: UInt16) throws -> Data {
        let normalizedHost = host.hasSuffix(".") ? String(host.dropLast()) : host
        guard normalizedHost.isEmpty == false, normalizedHost.utf8.count <= 253 else {
            throw URLError(.badURL)
        }

        var bytes: [UInt8] = [
            UInt8(transactionID >> 8), UInt8(transactionID & 0xff),
            0x01, 0x00, // Recursion desired.
            0x00, 0x01, // One question.
            0x00, 0x00, // No answers.
            0x00, 0x00, // No authority records.
            0x00, 0x00, // No additional records.
        ]
        for label in normalizedHost.split(separator: ".", omittingEmptySubsequences: false) {
            let labelBytes = Array(label.utf8)
            guard labelBytes.isEmpty == false, labelBytes.count <= 63 else {
                throw URLError(.badURL)
            }
            bytes.append(UInt8(labelBytes.count))
            bytes.append(contentsOf: labelBytes)
        }
        bytes.append(0)
        bytes.append(contentsOf: [0x00, 0x01, 0x00, 0x01]) // A, IN.
        guard bytes.count <= 512 else { throw URLError(.badURL) }
        return Data(bytes)
    }

    static func validateResponse(_ response: Data, transactionID: UInt16) throws {
        let bytes = [UInt8](response)
        guard bytes.count >= 12 else { throw URLError(.cannotParseResponse) }
        guard readUInt16(bytes, at: 0) == transactionID else {
            throw URLError(.cannotParseResponse)
        }

        let flags = readUInt16(bytes, at: 2)
        guard flags & 0x8000 != 0, flags & 0x0200 == 0 else {
            throw URLError(.cannotParseResponse)
        }
        guard flags & 0x000f == 0 else { throw URLError(.dnsLookupFailed) }
        let questionCount = Int(readUInt16(bytes, at: 4))
        let answerCount = Int(readUInt16(bytes, at: 6))
        guard questionCount == 1 else { throw URLError(.cannotParseResponse) }

        var offset = 12
        try skipName(bytes, offset: &offset)
        guard offset <= bytes.count - 4 else { throw URLError(.cannotParseResponse) }
        guard readUInt16(bytes, at: offset) == 1, readUInt16(bytes, at: offset + 2) == 1 else {
            throw URLError(.cannotParseResponse)
        }
        offset += 4

        for _ in 0..<answerCount {
            try skipName(bytes, offset: &offset)
            guard offset <= bytes.count - 10 else { throw URLError(.cannotParseResponse) }
            let recordType = readUInt16(bytes, at: offset)
            let recordClass = readUInt16(bytes, at: offset + 2)
            let dataLength = Int(readUInt16(bytes, at: offset + 8))
            offset += 10
            guard dataLength <= bytes.count - offset else {
                throw URLError(.cannotParseResponse)
            }
            if recordType == 1, recordClass == 1, dataLength == 4 {
                return
            }
            offset += dataLength
        }
        throw URLError(.dnsLookupFailed)
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    private static func skipName(
        _ bytes: [UInt8],
        offset: inout Int,
        compressionDepth: Int = 0
    ) throws {
        var labels = 0
        while true {
            guard offset < bytes.count, labels <= 127, compressionDepth <= 127 else {
                throw URLError(.cannotParseResponse)
            }
            let length = Int(bytes[offset])
            if length & 0xc0 == 0xc0 {
                guard offset <= bytes.count - 2 else { throw URLError(.cannotParseResponse) }
                let pointer = (length & 0x3f) << 8 | Int(bytes[offset + 1])
                // RFC 1035 compression points to an earlier occurrence. Requiring a backwards
                // pointer also makes cycles impossible before validating the pointed-to name.
                guard pointer >= 12, pointer < offset else {
                    throw URLError(.cannotParseResponse)
                }
                var pointedOffset = pointer
                try skipName(
                    bytes,
                    offset: &pointedOffset,
                    compressionDepth: compressionDepth + 1
                )
                offset += 2
                return
            }
            guard length & 0xc0 == 0 else { throw URLError(.cannotParseResponse) }
            offset += 1
            if length == 0 { return }
            guard length <= 63, length <= bytes.count - offset else {
                throw URLError(.cannotParseResponse)
            }
            offset += length
            labels += 1
        }
    }
}

/// A provider/API state failure is local evidence and must never be converted into WSS fallback.
enum PacketTunnelProbeTransportError: Error {
    case invalidConnectionState
}

/// Explicit Apple through-TUN transport. A URLSession created by the extension is intentionally
/// excluded from its own packet tunnel; this API is the iOS 16/17 guarantee that the probe traverses
/// the active Reality/libbox path instead of escaping on the hardware interface.
private final class ProviderThroughTunnelProbeTransport: ThroughTunnelProbeTransport, @unchecked Sendable {
    static let defaultTunnelDNSServerAddress = "172.19.0.2"

    private weak var provider: NEPacketTunnelProvider?
    private let tunnelDNSServerAddress: String

    init(
        provider: NEPacketTunnelProvider,
        tunnelDNSServerAddress: String = defaultTunnelDNSServerAddress
    ) {
        self.provider = provider
        self.tunnelDNSServerAddress = tunnelDNSServerAddress
    }

    func resolveFreshA(host: String) async throws {
        guard let provider else { throw URLError(.cancelled) }
        let transactionID = UInt16.random(in: UInt16.min...UInt16.max)
        let query = try TunnelDNSAProbe.makeQuery(host: host, transactionID: transactionID)
        let remote = NWHostEndpoint(hostname: tunnelDNSServerAddress, port: "53")
        let session = provider.createUDPSessionThroughTunnel(to: remote, from: nil)
        defer { session.cancel() }
        try await withTaskCancellationHandler {
            try await waitUntilReady(session)
            let response = try await exchange(query, using: session)
            try TunnelDNSAProbe.validateResponse(response, transactionID: transactionID)
        } onCancel: {
            session.cancel()
        }
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

    private func waitUntilReady(_ session: NWUDPSession) async throws {
        let observation = ObservationBox()
        defer { observation.invalidate() }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let gate = ContinuationGate<Void>(continuation)
            let token = session.observe(\.state, options: [.initial, .new]) { observed, _ in
                switch observed.state {
                case .ready:
                    gate.resume(returning: ())
                case .failed:
                    gate.resume(throwing: URLError(.cannotConnectToHost))
                case .cancelled:
                    gate.resume(throwing: CancellationError())
                case .invalid:
                    gate.resume(throwing: PacketTunnelProbeTransportError.invalidConnectionState)
                case .waiting, .preparing:
                    break
                @unknown default:
                    gate.resume(throwing: URLError(.unknown))
                }
            }
            observation.set(token)
        }
    }

    private func exchange(_ query: Data, using session: NWUDPSession) async throws -> Data {
        let observation = ObservationBox()
        let gate = DeferredContinuationGate<Data>()
        defer { observation.invalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Data, Error>) in
                guard gate.install(continuation) else { return }
                let token = session.observe(\.state, options: [.new]) { observed, _ in
                    switch observed.state {
                    case .failed:
                        gate.resume(throwing: URLError(.networkConnectionLost))
                    case .cancelled:
                        gate.resume(throwing: CancellationError())
                    case .invalid:
                        gate.resume(throwing: PacketTunnelProbeTransportError.invalidConnectionState)
                    case .waiting, .preparing, .ready:
                        break
                    @unknown default:
                        gate.resume(throwing: URLError(.unknown))
                    }
                }
                observation.set(token)
                session.setReadHandler({ datagrams, error in
                    if let error {
                        gate.resume(throwing: error)
                    } else if let response = datagrams?.first, response.isEmpty == false {
                        gate.resume(returning: response)
                    } else {
                        gate.resume(throwing: URLError(.zeroByteResource))
                    }
                }, maxDatagrams: 1)
                session.writeDatagram(query) { error in
                    if let error { gate.resume(throwing: error) }
                }
            }
        } onCancel: {
            session.cancel()
            gate.resume(throwing: CancellationError())
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
        "https://\(SingBoxConfiguration.connectivityProbeHost)/generate_204",
    ]

    private let endpoints: [TunnelProbeEndpoint]
    private let transport: any ThroughTunnelProbeTransport
    private let deadlineMilliseconds: UInt64
    private let retryDelayNanoseconds: UInt64
    private let requestTimeoutMilliseconds: UInt64

    init(
        tunnelProvider: NEPacketTunnelProvider,
        endpoints: [String] = Self.defaultEndpointStrings
    ) throws {
        try self.init(
            endpoints: endpoints,
            transport: ProviderThroughTunnelProbeTransport(provider: tunnelProvider)
        )
    }

    init(
        endpoints: [String] = Self.defaultEndpointStrings,
        transport: any ThroughTunnelProbeTransport,
        deadlineMilliseconds: UInt64 = 14_000,
        retryDelayNanoseconds: UInt64 = 500_000_000,
        // A primary DNS exchange may consume its two-second timeout before the secondary DoH
        // resolver is tried. Leave enough room for that failover plus the HTTPS/TLS exchange.
        requestTimeoutMilliseconds: UInt64 = 7_000
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
                    try await transport.resolveFreshA(host: endpoint.host)
                    return try await transport.responseHead(for: endpoint)
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

/// Allows cancellation to win even in the small interval before a continuation is installed.
private final class DeferredContinuationGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var completedResult: Result<Value, Error>?

    @discardableResult
    func install(_ value: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        if let result = completedResult {
            lock.unlock()
            value.resume(with: result)
            return false
        }
        continuation = value
        lock.unlock()
        return true
    }

    func resume(returning value: Value) {
        finish(.success(value))
    }

    func resume(throwing error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard completedResult == nil else {
            lock.unlock()
            return
        }
        completedResult = result
        let value = continuation
        continuation = nil
        lock.unlock()
        value?.resume(with: result)
    }
}
