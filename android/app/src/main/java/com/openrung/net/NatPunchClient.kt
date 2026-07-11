package com.openrung.net

import android.net.VpnService
import com.openrung.config.AppConfig
import com.openrung.model.RelayDescriptor
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.OpenRungPunchClient
import io.nekohasekai.libbox.OpenRungPunchListener
import io.nekohasekai.libbox.OpenRungPunchProtector
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.net.URI

data class NatPunchResult(
    val succeeded: Boolean,
    val reason: String,
    val errorText: String,
    val bridgeHost: String,
    val bridgePort: Int,
    val peerIp: String,
    val sessionId: String,
    val natClass: String,
    val rttMillis: Long,
)

/** A two-phase handle so disconnect can cancel a blocking native establishment attempt. */
interface NatPunchSession {
    suspend fun establish(): NatPunchResult
    suspend fun awaitFailure(): String
    fun close()
}

object NatPunchClient {
    /**
     * Returns a session only for a signed, explicitly advertised HTTPS endpoint. The desktop
     * client's legacy cleartext `http://publicHost:9444` derivation is intentionally not inherited:
     * Go's HTTP stack is outside Android's Network Security Config and could bypass its cleartext
     * prohibition. An absent/invalid endpoint simply preserves the RelayHub fallback.
     */
    fun create(vpnService: VpnService, relay: RelayDescriptor): NatPunchSession? {
        if (!relay.punchCapable) return null
        val coordinatorUrl = validatedCoordinatorUrl(relay.punchEndpoint) ?: return null
        val tls = coordinatorTls(coordinatorUrl) ?: return null
        val protector = OpenRungPunchProtector { fd ->
            fd in 0..Int.MAX_VALUE.toLong() && vpnService.protect(fd.toInt())
        }
        val failure = CompletableDeferred<String>()
        val listener = OpenRungPunchListener { reason ->
            failure.complete(reason.ifBlank { "direct QUIC path closed" })
        }
        val client = Libbox.newOpenRungPunchClient(
            coordinatorUrl,
            relay.id,
            tls.allowSelfSigned,
            tls.certificateSha256,
            protector,
            listener,
        )
        return LibboxNatPunchSession(client, failure)
    }

    internal fun validatedCoordinatorUrl(rawValue: String): String? {
        val value = rawValue.trim().trimEnd('/')
        if (value.isEmpty()) return null
        val uri = runCatching { URI(value) }.getOrNull() ?: return null
        if (!uri.scheme.equals("https", ignoreCase = true)) return null
        if (uri.host.isNullOrBlank() || uri.rawUserInfo != null) return null
        if (uri.rawQuery != null || uri.rawFragment != null) return null
        if (uri.port != -1 && uri.port !in 1..65535) return null
        return value
    }

    /**
     * Bare-IP HTTPS cannot rely on a public CA in the deployed configuration, so it must have an
     * exact app pin. A hostname is allowed without a pin and uses ordinary CA/hostname validation.
     */
    internal fun coordinatorTls(coordinatorUrl: String): CoordinatorTls? {
        val host = runCatching { URI(coordinatorUrl).host?.lowercase() }.getOrNull() ?: return null
        val pin = AppConfig.PUNCH_COORDINATOR_CERT_SHA256_BY_HOST[host]
        if (pin != null) return CoordinatorTls(allowSelfSigned = true, certificateSha256 = pin)
        if (looksLikeIpLiteral(host)) return null
        return CoordinatorTls(allowSelfSigned = false, certificateSha256 = "")
    }

    private fun looksLikeIpLiteral(host: String): Boolean =
        ':' in host || host.split('.').let { parts ->
            parts.size == 4 && parts.all { part ->
                part.isNotEmpty() && part.all(Char::isDigit)
            }
        }
}

internal data class CoordinatorTls(
    val allowSelfSigned: Boolean,
    val certificateSha256: String,
)

private class LibboxNatPunchSession(
    private val client: OpenRungPunchClient,
    private val failure: CompletableDeferred<String>,
) : NatPunchSession {
    override suspend fun establish(): NatPunchResult = withContext(Dispatchers.IO) {
        val native = client.establish()
        NatPunchResult(
            succeeded = native.succeeded(),
            reason = native.reason(),
            errorText = native.errorText(),
            bridgeHost = native.bridgeHost(),
            bridgePort = native.bridgePort(),
            peerIp = native.peerIP(),
            sessionId = native.sessionID(),
            natClass = native.natClass(),
            rttMillis = native.rttMillis(),
        ).also {
            if (!it.succeeded) client.close()
        }
    }

    override suspend fun awaitFailure(): String = failure.await()

    override fun close() {
        client.close()
        failure.cancel()
    }
}
