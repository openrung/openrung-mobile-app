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
 *  - DNS-stage remote failure → stage `dns_probe`. The emitted resolver chain already fell
 *    over in-engine, so this stage failing means NO configured resolver answered through this
 *    transport — evidence against the path, not one resolver;
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
): InternetProbeResult = try {
    awaitStartupProbeOrEngineStop(probe, awaitUnexpectedEngineStop)
} catch (error: CancellationException) {
    throw error
} catch (error: Throwable) {
    if (error is LocalTunnelException) throw error
    val stage = if (error is DnsPathUnverifiedException) {
        STARTUP_STAGE_DNS_PROBE
    } else {
        STARTUP_STAGE_INTERNET_PROBE
    }
    if (!isGenuineRemoteDataPathFailure(error)) {
        throw LocalTunnelException(stage, error)
    }
    if (wssFrontId != null) {
        throw WssTransportException(stage, wssFrontId, error)
    }
    throw DirectPathException(stage, error)
}
