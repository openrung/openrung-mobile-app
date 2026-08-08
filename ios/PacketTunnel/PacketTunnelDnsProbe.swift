import Foundation
import Network
import NetworkExtension

/// Sends one datagram through the active tunnel and returns the first datagram received.
protocol ThroughTunnelDatagramTransport: Sendable {
    func exchange(_ datagram: Data) async throws -> Data
}

/// Fresh-DNS proof through the tunnel. Sends a raw A query for `<nonce>.probe.openrung.org` via
/// `createUDPSessionThroughTunnel`, where sing-box's hijack-dns rule intercepts it and the
/// highest-priority probe DNS rule (with `disable_cache`) forwards it to the proxied DoH
/// resolver. The per-query nonce label defeats every cache in the chain — mDNSResponder,
/// sing-box's engine cache, and upstream negative caches are all keyed by QNAME — so a response
/// can only mean the TUN → hijack → DoH → proxy → resolver path works right now. ANY well-formed
/// response counts, including NXDOMAIN: the answer's content is irrelevant, its arrival is the
/// proof. Port of Android `DnsProbe`.
struct PacketTunnelDnsProbe: Sendable {
    /// One transport attempt must outlive the emitted failover chain's worst case (the
    /// primary's evaluate timeout plus the terminal fallback's own budget) with margin for the
    /// hijack round trip — otherwise a blackholed primary consumes its full evaluate timeout
    /// and the probe aborts while the fallback is still legitimately answering, condemning a
    /// healthy transport. Both budgets are derived, never hand-tuned.
    static let defaultAttemptTimeoutMilliseconds: UInt64 =
        SingBoxConfiguration.dnsFailoverWorstCaseMilliseconds + 1_000

    /// Startup budget: two full-chain attempts plus the retry gap.
    static let defaultDeadlineMilliseconds: UInt64 = 2 * defaultAttemptTimeoutMilliseconds + 250

    private let transport: any ThroughTunnelDatagramTransport
    private let qnameSuffix: String
    private let deadlineMilliseconds: UInt64
    private let retryDelayNanoseconds: UInt64
    private let attemptTimeoutMilliseconds: UInt64

    init(tunnelProvider: NEPacketTunnelProvider) {
        self.init(transport: ProviderThroughTunnelDatagramTransport(provider: tunnelProvider))
    }

    init(
        transport: any ThroughTunnelDatagramTransport,
        qnameSuffix: String = ProbeTargets.dnsProbeQnameSuffix,
        deadlineMilliseconds: UInt64 = PacketTunnelDnsProbe.defaultDeadlineMilliseconds,
        retryDelayNanoseconds: UInt64 = 250_000_000,
        attemptTimeoutMilliseconds: UInt64 = PacketTunnelDnsProbe.defaultAttemptTimeoutMilliseconds
    ) {
        self.transport = transport
        self.qnameSuffix = qnameSuffix
        self.deadlineMilliseconds = deadlineMilliseconds
        self.retryDelayNanoseconds = retryDelayNanoseconds
        self.attemptTimeoutMilliseconds = attemptTimeoutMilliseconds
    }

    /// Bounded-retry verification used at startup.
    func verify() async throws {
        let started = DispatchTime.now().uptimeNanoseconds
        let deadline = started + deadlineMilliseconds * 1_000_000
        var lastError: Error?
        while DispatchTime.now().uptimeNanoseconds < deadline {
            do {
                try await verifyOnce()
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
            try await Task.sleep(nanoseconds: retryDelayNanoseconds)
        }
        throw lastError ?? URLError(.timedOut)
    }

    /// One no-retry attempt used by the long-lived tunnel health monitor.
    func verifyOnce() async throws {
        let transactionID = UInt16.random(in: .min ... .max)
        let qname = "\(DnsProbeMessage.nonceLabel()).\(qnameSuffix)"
        let query = DnsProbeMessage.query(transactionID: transactionID, name: qname)
        let response = try await withTimeout(milliseconds: attemptTimeoutMilliseconds) {
            try await transport.exchange(query)
        }
        guard DnsProbeMessage.isResponse(response, transactionID: transactionID) else {
            throw URLError(.cannotParseResponse)
        }
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

/// Startup/health verification of the full tunnel path: fresh DNS first (nonce query through
/// the proxied DoH resolver), then HTTPS to the probe endpoints. Passing both is the only proof
/// that the tunnel carries new sessions end to end; either failure alone must fail the check.
/// Port of Android `TunnelPathProbe`.
struct PacketTunnelPathProbe: Sendable {
    private let dnsProbe: PacketTunnelDnsProbe
    private let httpProbe: PacketTunnelInternetProbe

    init(dnsProbe: PacketTunnelDnsProbe, httpProbe: PacketTunnelInternetProbe) {
        self.dnsProbe = dnsProbe
        self.httpProbe = httpProbe
    }

    func verify() async throws -> InternetProbeResult {
        do {
            try await dnsProbe.verify()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DnsPathUnverifiedError(underlying: error)
        }
        return try await httpProbe.verify()
    }

    func verifyOnce() async throws -> InternetProbeResult {
        do {
            try await dnsProbe.verifyOnce()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DnsPathUnverifiedError(underlying: error)
        }
        return try await httpProbe.verifyOnce()
    }
}

/// Production transport: a UDP session created through the tunnel, addressed to the TUN's own DNS
/// address — the ONLY destination sing-box tags as DNS and hijacks into its DNS module (see
/// `SingBoxConfiguration.defaultTunnelDnsAddress`; it is also the resolver advertised through
/// `NEDNSSettings`, so this is the exact path system lookups take). A public-resolver address
/// would match no route rule and die on the TCP-only proxy outbound.
private final class ProviderThroughTunnelDatagramTransport: ThroughTunnelDatagramTransport,
    @unchecked Sendable {
    private weak var provider: NEPacketTunnelProvider?

    init(provider: NEPacketTunnelProvider) {
        self.provider = provider
    }

    func exchange(_ datagram: Data) async throws -> Data {
        guard let provider else { throw URLError(.cancelled) }
        let session = provider.createUDPSessionThroughTunnel(
            to: NWHostEndpoint(
                hostname: SingBoxConfiguration.defaultTunnelDnsAddress,
                port: "53"
            ),
            from: nil
        )
        defer { session.cancel() }
        return try await withTaskCancellationHandler {
            try await waitUntilReady(session)
            return try await sendAndReceive(datagram, over: session)
        } onCancel: {
            session.cancel()
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
                case .failed, .invalid:
                    gate.resume(throwing: URLError(.cannotConnectToHost))
                case .cancelled:
                    gate.resume(throwing: CancellationError())
                case .preparing, .waiting:
                    break
                @unknown default:
                    gate.resume(throwing: URLError(.unknown))
                }
            }
            observation.set(token)
        }
    }

    private func sendAndReceive(_ datagram: Data, over session: NWUDPSession) async throws -> Data {
        let observation = ObservationBox()
        defer { observation.invalidate() }
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data, Error>) in
            let gate = ContinuationGate<Data>(continuation)
            // A dead path never delivers a datagram, and the timeout/cancellation path only
            // cancels the session — without this observation the continuation would never
            // resume and the probe (and the startup ladder behind it) would hang forever.
            // ContinuationGate is one-shot, so the extra resumption source is race-safe.
            let token = session.observe(\.state, options: [.new]) { observed, _ in
                switch observed.state {
                case .cancelled:
                    gate.resume(throwing: CancellationError())
                case .failed, .invalid:
                    gate.resume(throwing: URLError(.cannotConnectToHost))
                default:
                    break
                }
            }
            observation.set(token)
            session.setReadHandler({ datagrams, error in
                if let error {
                    gate.resume(throwing: error)
                } else if let first = datagrams?.first {
                    gate.resume(returning: first)
                } else {
                    gate.resume(throwing: URLError(.zeroByteResource))
                }
            }, maxDatagrams: 1)
            session.writeDatagram(datagram) { error in
                if let error { gate.resume(throwing: error) }
            }
        }
    }
}
