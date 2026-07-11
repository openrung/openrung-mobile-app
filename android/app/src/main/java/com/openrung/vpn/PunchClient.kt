package com.openrung.vpn

import android.net.VpnService
import android.util.Log
import com.openrung.config.AppConfig
import com.openrung.model.RelayDescriptor
import com.openrung.telemetry.TelemetryManager
import io.nekohasekai.orpunch.Config
import io.nekohasekai.orpunch.Orpunch
import io.nekohasekai.orpunch.Session
import io.nekohasekai.orpunch.SocketProtector
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * A live direct NAT-punched path to a volunteer. [session] owns the punched QUIC connection and the
 * loopback bridge goroutine; sing-box dials [bridgeHost]:[bridgePort] in place of the relay hub, and
 * [peerIp] must be excluded from the TUN routes. Close it (via [PunchClient] teardown) to release the
 * socket when the tunnel is torn down.
 */
class PunchOutcome(
    val session: Session,
    val bridgeHost: String,
    val bridgePort: Int,
    val peerIp: String,
    val natClass: String,
) {
    fun close() {
        runCatching { session.close() }
    }
}

/**
 * Kotlin front door to the gomobile-bound punch client (io.nekohasekai.orpunch, bundled in
 * libbox.aar). It runs the desktop client's exact punch flow — hub coordination, reflector
 * discovery, UDP hole punch, QUIC, loopback bridge — and hands back a [PunchOutcome] whose loopback
 * bridge sing-box uses instead of the relay hub. Any failure (not punch-capable, symmetric NAT, hub
 * declined, timeout, or the AAR lacking orpunch) resolves to null and the caller falls back to the
 * relay hub path: the outcome is never worse than not punching.
 */
object PunchClient {
    private const val LOG_TAG = "OpenRungPunch"

    /**
     * Whether the orpunch classes are actually linked. A checkout or build variant without the AAR
     * must degrade to the relay path rather than crash, exactly like ProxyEngineFactory guards the
     * libbox classes.
     */
    private val linked: Boolean = try {
        Orpunch::class.java.name
        true
    } catch (error: Throwable) {
        false
    }

    /**
     * Attempts a direct NAT-punched path to [relay]. Returns a live [PunchOutcome] on success or null
     * on any failure. Records punch telemetry mirroring the desktop client
     * (punch_skipped/attempted/succeeded/failed). The blocking hub/punch/QUIC work runs on
     * Dispatchers.IO; cancellation propagates so a racing disconnect tears the attempt down.
     */
    suspend fun maybePunch(relay: RelayDescriptor, vpnService: VpnService): PunchOutcome? {
        if (!relay.punchCapable) return null
        if (!AppConfig.PUNCH_ENABLED) {
            TelemetryManager.record("punch_skipped", relayId = relay.id, attributes = mapOf("reason" to "disabled"))
            return null
        }
        if (!linked) return null

        TelemetryManager.record("punch_attempted", relayId = relay.id)
        // Orpunch.dial is a blocking JNI call that runs to completion even if this coroutine is
        // cancelled meanwhile — producing a LIVE session (open UDP socket + bridge goroutine + QUIC
        // conn). If the dispatch back to the caller's context then finds it cancelled, withContext
        // DISCARDS the returned value and throws CancellationException, so `activePunch = ...` never
        // runs and nothing closes the session. Capture it in an outer var and close it on
        // cancellation so a disconnect mid-punch cannot leak the socket/goroutine.
        var outcome: PunchOutcome? = null
        try {
            return withContext(Dispatchers.IO) {
                val session = try {
                    val config = Config().apply {
                        setHubBaseURL(relay.punchBaseUrl())
                        setRelayID(relay.id)
                        setInsecure(AppConfig.PUNCH_HUB_INSECURE)
                    }
                    Orpunch.dial(config, VpnSocketProtector(vpnService))
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Throwable) {
                    Log.w(LOG_TAG, "punch dial failed", error)
                    TelemetryManager.record(
                        "punch_failed",
                        relayId = relay.id,
                        attributes = mapOf("reason" to "wrapper", "nat_class" to ""),
                    )
                    return@withContext null
                }

                if (!session.ok()) {
                    TelemetryManager.record(
                        "punch_failed",
                        relayId = relay.id,
                        // Both keys always present, matching the desktop client's telemetry shape.
                        attributes = mapOf("reason" to session.reason(), "nat_class" to session.natClass()),
                    )
                    runCatching { session.close() }
                    return@withContext null
                }

                TelemetryManager.record(
                    "punch_succeeded",
                    relayId = relay.id,
                    attributes = mapOf("nat_class" to session.natClass()),
                    measurements = mapOf("punch_rtt_ms" to session.rttMillis()),
                )
                PunchOutcome(
                    session = session,
                    bridgeHost = session.bridgeHost(),
                    bridgePort = session.bridgePort().toInt(),
                    peerIp = session.peerIP(),
                    natClass = session.natClass(),
                ).also { outcome = it }
            }
        } catch (error: CancellationException) {
            runCatching { outcome?.close() }
            throw error
        }
    }
}

/**
 * Bridges the Go punch socket's fd to VpnService.protect() so the reflector, hole-punch, and QUIC
 * datagrams reach the underlying network instead of looping back through the app's own TUN — the
 * same seam libbox uses via PlatformInterface.autoDetectInterfaceControl. gomobile marshals Go's
 * `int` fd as a Java `long`; VpnService.protect takes an `int`.
 */
private class VpnSocketProtector(private val vpn: VpnService) : SocketProtector {
    override fun protect(fd: Long) {
        vpn.protect(fd.toInt())
    }
}
