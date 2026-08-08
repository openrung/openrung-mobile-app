package com.openrung.vpn

import com.openrung.net.DnsPathUnverifiedException
import com.openrung.net.InternetProbeResult
import kotlinx.coroutines.CancellationException

internal const val STARTUP_STAGE_DNS_PROBE = "dns_probe"
internal const val STARTUP_STAGE_INTERNET_PROBE = "internet_probe"

/**
 * Runs the startup verification (fresh DNS, then HTTPS, both through the tunnel) raced against
 * the engine's stop signal, and projects a failure into the fallback taxonomy:
 *
 *  - engine stop / local evidence → [LocalTunnelException] (aborts the whole relay ladder);
 *  - DNS-stage remote failure → stage `dns_probe`, after [onDnsPathFailure] has run so the
 *    resolver rotation advances before any retry builds its configuration;
 *  - HTTPS-stage remote failure → stage `internet_probe`;
 *  - remote failures type as [WssTransportException] when [wssFrontId] is set (WSS transport),
 *    else [DirectPathException] — the only type that can unlock WSS fallback.
 *
 * Extracted from the service so startup truth-telling is hostlessly testable: CONNECTED may only
 * be published when this returns.
 */
internal suspend fun verifyStartupTunnelPath(
    probe: suspend () -> InternetProbeResult,
    awaitUnexpectedEngineStop: suspend () -> String,
    wssFrontId: String?,
    onDnsPathFailure: () -> Unit,
): InternetProbeResult = try {
    awaitStartupProbeOrEngineStop(probe, awaitUnexpectedEngineStop)
} catch (error: CancellationException) {
    throw error
} catch (error: Throwable) {
    if (error is LocalTunnelException) throw error
    val dnsStage = error is DnsPathUnverifiedException
    val stage = if (dnsStage) STARTUP_STAGE_DNS_PROBE else STARTUP_STAGE_INTERNET_PROBE
    if (!isGenuineRemoteDataPathFailure(error)) {
        throw LocalTunnelException(stage, error)
    }
    // Only a failure classified as REMOTE is evidence about the resolver path; rotating on
    // local evidence would burn a healthy resolver and emit false failover telemetry. Still
    // ahead of the typed throws, so any retry below builds its config from the rotated order.
    if (dnsStage) onDnsPathFailure()
    if (wssFrontId != null) {
        throw WssTransportException(stage, wssFrontId, error)
    }
    throw DirectPathException(stage, error)
}
