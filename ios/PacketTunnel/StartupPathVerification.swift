import Foundation

let startupStageDnsProbe = "dns_probe"
let startupStageInternetProbe = "internet_probe"

private enum VerifiedStartupPathEvent {
    case probe(InternetProbeResult)
    case engineStopped(String?)
}

/// Runs the startup verification (fresh DNS, then HTTPS, both through the tunnel) raced against
/// the engine's stop signal, and projects a failure into the fallback taxonomy:
///
///  - engine stop / local evidence → `LocalTunnelError` (aborts the whole relay ladder);
///  - DNS-stage remote failure → stage `dns_probe`, after `onDnsPathFailure` has run so the
///    resolver rotation advances before any retry builds its configuration;
///  - HTTPS-stage remote failure → stage `internet_probe`;
///  - remote failures type as `WssTransportError` when `wssFrontID` is set (WSS transport),
///    else `DirectPathError` — the only type that can unlock WSS fallback.
///
/// The engine is threaded in as closures so the seam stays hostlessly testable (the concrete
/// engine imports Libbox). `prepareForExpectedStop` linearizes remote classification against
/// libbox's stop callback exactly as before the extraction: if the callback already won, this is
/// a local engine failure; if teardown wins, a later callback is expected because the failed
/// candidate is about to be replaced. Extracted from the provider so startup truth-telling is
/// hostlessly testable: CONNECTED may only be published when this returns.
func verifyStartupTunnelPath(
    probe: @escaping @Sendable () async throws -> InternetProbeResult,
    waitForUnexpectedStop: @escaping @Sendable () async -> String?,
    hasUnexpectedStop: () -> Bool,
    prepareForExpectedStop: () -> Bool,
    wssFrontID: String?,
    onDnsPathFailure: () -> Void
) async throws -> InternetProbeResult {
    do {
        let result = try await withThrowingTaskGroup(of: VerifiedStartupPathEvent.self) { group in
            group.addTask { .probe(try await probe()) }
            group.addTask { .engineStopped(await waitForUnexpectedStop()) }
            defer { group.cancelAll() }
            while let event = try await group.next() {
                switch event {
                case .probe(let result):
                    return result
                case .engineStopped(let reason):
                    if let reason {
                        throw LocalTunnelError(
                            stage: "active_tunnel_engine",
                            underlying: PacketTunnelProxyEngineError.engineStartFailed(reason)
                        )
                    }
                    try Task.checkCancellation()
                }
            }
            throw CancellationError()
        }
        guard hasUnexpectedStop() == false else {
            throw LocalTunnelError(
                stage: "active_tunnel_engine",
                underlying: PacketTunnelProxyEngineError.engineStartFailed(
                    "libbox stopped during startup verification"
                )
            )
        }
        return result
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        if hasUnexpectedStop() {
            throw LocalTunnelError(
                stage: "active_tunnel_engine",
                underlying: PacketTunnelProxyEngineError.engineStartFailed(
                    "libbox stopped during startup verification"
                )
            )
        }
        let dnsStage = error is DnsPathUnverifiedError
        let stage = dnsStage ? startupStageDnsProbe : startupStageInternetProbe
        guard isGenuineRemoteDataPathFailure(error) else {
            throw LocalTunnelError(stage: stage, underlying: error)
        }
        guard prepareForExpectedStop() else {
            throw LocalTunnelError(
                stage: "active_tunnel_engine",
                underlying: PacketTunnelProxyEngineError.engineStartFailed(
                    "libbox stopped while classifying the startup path failure"
                )
            )
        }
        // Only a failure classified as REMOTE (and not one the engine-stop callback just
        // claimed) is evidence about the resolver path; rotating on local evidence would burn a
        // healthy resolver and emit false failover telemetry. Still ahead of the typed throws,
        // so any retry below builds its config from the rotated order.
        if dnsStage { onDnsPathFailure() }
        if let wssFrontID {
            throw WssTransportError(stage: stage, frontID: wssFrontID, underlying: error)
        }
        throw DirectPathError(stage: stage, underlying: error)
    }
}
