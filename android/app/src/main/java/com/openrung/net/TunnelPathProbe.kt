package com.openrung.net

import android.content.Context
import kotlinx.coroutines.CancellationException
import java.io.IOException

/** HTTPS reachability seam so orchestration tests can run without Android networking. */
interface TunnelHttpProbe {
    suspend fun verify(): InternetProbeResult
    suspend fun verifyOnce(): InternetProbeResult
}

/**
 * Marks a failure of the fresh-DNS stage of tunnel verification. The [cause] carries the real
 * network error for classification/allow-listing; this wrapper only tells the caller that the
 * resolver path (not the HTTP path) is what failed, so it can rotate the DoH resolver before
 * the next attempt.
 */
class DnsPathUnverifiedException(cause: Throwable) :
    IOException("tunnel DNS path verification failed", cause)

/**
 * Startup/health verification of the full tunnel path: fresh DNS first (nonce query through the
 * proxied DoH resolver), then HTTPS to the probe endpoints. Passing both is the only proof that
 * the tunnel carries new sessions end to end; either failure alone must fail the check.
 */
class TunnelPathProbe(
    private val dnsProbe: DnsProbe,
    private val httpProbe: TunnelHttpProbe,
) {
    constructor(context: Context) : this(DnsProbe(context), InternetProbe(context))

    suspend fun verify(): InternetProbeResult {
        runDnsStage { dnsProbe.verify() }
        return httpProbe.verify()
    }

    suspend fun verifyOnce(): InternetProbeResult {
        runDnsStage { dnsProbe.verifyOnce() }
        return httpProbe.verifyOnce()
    }

    private inline fun runDnsStage(stage: () -> DnsProbeResult) {
        try {
            stage()
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            throw DnsPathUnverifiedException(error)
        }
    }
}
