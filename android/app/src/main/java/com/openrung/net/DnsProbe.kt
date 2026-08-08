package com.openrung.net

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.SystemClock
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import java.io.IOException
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ProtocolException
import kotlin.random.Random

/** Sends one datagram through the active tunnel and returns the first datagram received. */
fun interface TunnelDnsTransport {
    suspend fun exchange(query: ByteArray): ByteArray
}

/**
 * Fresh-DNS proof through the tunnel. Sends a raw A query for `<nonce>.probe.openrung.org` at the
 * TUN, where sing-box's hijack-dns rule intercepts it and the highest-priority probe DNS rule
 * (with `disable_cache`) forwards it to the proxied DoH resolver. The per-query nonce label
 * defeats every cache in the chain — netd's per-network resolver cache, sing-box's engine cache,
 * and upstream negative caches are all keyed by QNAME — so a response can only mean the
 * TUN → hijack → DoH → proxy → resolver path works right now. ANY well-formed response counts,
 * including NXDOMAIN: the answer's content is irrelevant, its arrival is the proof.
 */
class DnsProbe(
    private val transport: TunnelDnsTransport,
    private val qnameSuffix: String = ProbeTargets.DNS_PROBE_QNAME_SUFFIX,
    // Injected so hostless JVM tests can drive the deadline (SystemClock is a stub off-device).
    private val elapsedRealtime: () -> Long = SystemClock::elapsedRealtime,
) {
    constructor(context: Context) : this(VpnNetworkDnsTransport(context))

    /** Bounded-retry verification used at startup. */
    suspend fun verify(): DnsProbeResult {
        val started = elapsedRealtime()
        val deadline = started + PROBE_DEADLINE_MS
        var lastError: Throwable? = null
        while (elapsedRealtime() < deadline) {
            try {
                return attempt(started)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                lastError = error
            }
            delay(RETRY_DELAY_MS)
        }
        throw IOException(
            "tunnel DNS probe failed" + (lastError?.message?.let { ": $it" } ?: ""),
            lastError,
        )
    }

    /** One no-retry attempt used by the long-lived tunnel health monitor. */
    suspend fun verifyOnce(): DnsProbeResult = attempt(elapsedRealtime())

    private suspend fun attempt(startedAt: Long): DnsProbeResult {
        val transactionId = Random.nextInt(0x10000)
        val qname = "${nonceLabel()}.$qnameSuffix"
        val response = transport.exchange(DnsProbeMessage.encodeQuery(transactionId, qname))
        if (!DnsProbeMessage.isResponseFor(response, transactionId)) {
            // ProtocolException (not a bare IOException) so the remote-failure allow-list
            // recognizes a garbled in-tunnel answer as remote evidence, matching iOS's
            // URLError(.cannotParseResponse). A bare IOException would fail local and abort the
            // whole relay ladder instead of falling back.
            throw ProtocolException("tunnel DNS probe received a malformed or mismatched response")
        }
        return DnsProbeResult(
            qname = qname,
            durationMs = elapsedRealtime() - startedAt,
        )
    }

    private fun nonceLabel(): String {
        val builder = StringBuilder(NONCE_LENGTH)
        repeat(NONCE_LENGTH) { builder.append(NONCE_ALPHABET[Random.nextInt(NONCE_ALPHABET.length)]) }
        return builder.toString()
    }

    companion object {
        /**
         * One transport attempt must outlive the emitted failover chain's worst case (the
         * primary's evaluate timeout plus the terminal fallback's own budget) with margin for
         * the hijack round trip — otherwise a blackholed primary consumes its full evaluate
         * timeout and the probe aborts while the fallback is still legitimately answering,
         * condemning a healthy transport. Both budgets are derived, never hand-tuned.
         */
        internal val ATTEMPT_TIMEOUT_MS =
            SingBoxConfiguration.DNS_FAILOVER_WORST_CASE_MS + CHAIN_MARGIN_MS

        /** Startup budget: two full-chain attempts plus the retry gap. */
        internal val PROBE_DEADLINE_MS = 2 * ATTEMPT_TIMEOUT_MS + RETRY_DELAY_MS

        private const val CHAIN_MARGIN_MS = 1_000L
        private const val RETRY_DELAY_MS = 250L
        private const val NONCE_LENGTH = 16
        private const val NONCE_ALPHABET = "abcdefghijklmnopqrstuvwxyz0123456789"
    }
}

data class DnsProbeResult(
    val qname: String,
    val durationMs: Long,
)

/**
 * Minimal RFC 1035 codec for the probe. Only what the probe needs: encode one A/IN question and
 * recognize a well-formed response to it.
 */
internal object DnsProbeMessage {
    fun encodeQuery(transactionId: Int, qname: String): ByteArray {
        require(transactionId in 0..0xFFFF) { "transaction id must fit in 16 bits" }
        val labels = qname.split('.')
        require(labels.isNotEmpty() && labels.all { it.length in 1..63 }) {
            "invalid probe QNAME: $qname"
        }
        val out = ArrayList<Byte>(HEADER_LENGTH + qname.length + 6)
        out.addShort(transactionId)
        out.addShort(0x0100) // flags: standard query, recursion desired
        out.addShort(1) // QDCOUNT
        out.addShort(0) // ANCOUNT
        out.addShort(0) // NSCOUNT
        out.addShort(0) // ARCOUNT
        labels.forEach { label ->
            out.add(label.length.toByte())
            label.forEach { char -> out.add(char.code.toByte()) }
        }
        out.add(0) // root label
        out.addShort(1) // QTYPE A
        out.addShort(1) // QCLASS IN
        return out.toByteArray()
    }

    /** True when [response] is a DNS response (QR set) matching [transactionId]. Any RCODE. */
    fun isResponseFor(response: ByteArray, transactionId: Int): Boolean {
        if (response.size < HEADER_LENGTH) return false
        val responseId = ((response[0].toInt() and 0xFF) shl 8) or (response[1].toInt() and 0xFF)
        if (responseId != transactionId) return false
        return (response[2].toInt() and 0x80) != 0
    }

    private const val HEADER_LENGTH = 12

    private fun ArrayList<Byte>.addShort(value: Int) {
        add(((value ushr 8) and 0xFF).toByte())
        add((value and 0xFF).toByte())
    }
}

/**
 * Production transport: a UDP socket bound to the VPN [android.net.Network], addressed to the
 * TUN's own DNS address — the ONLY destination sing-box tags as DNS and hijacks into its DNS
 * module. That address is read from the VPN network's [android.net.LinkProperties] (it is the
 * resolver the OS advertises, so this is the exact path app lookups take), falling back to the
 * derivation in [SingBoxConfiguration.DEFAULT_TUNNEL_DNS_ADDRESS] if the platform reports none.
 * Timeouts are socket-level ([DatagramSocket.setSoTimeout]) and surface as
 * [java.net.SocketTimeoutException], which the remote-failure allow-list already recognizes.
 */
class VpnNetworkDnsTransport(context: Context) : TunnelDnsTransport {
    private val connectivityManager = context.getSystemService(ConnectivityManager::class.java)

    override suspend fun exchange(query: ByteArray): ByteArray = withContext(Dispatchers.IO) {
        val vpnNetwork = connectivityManager.allNetworks.firstOrNull { network ->
            connectivityManager.getNetworkCapabilities(network)
                ?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
        } ?: throw IOException("VPN network is unavailable")

        // A public-resolver address here would match no hijack tag, fall to the TCP-only proxy
        // outbound, and be dropped — failing the probe on every healthy tunnel.
        val hijackedResolver = connectivityManager.getLinkProperties(vpnNetwork)
            ?.dnsServers?.firstOrNull { it is Inet4Address }
            ?: InetAddress.getByName(SingBoxConfiguration.DEFAULT_TUNNEL_DNS_ADDRESS)

        DatagramSocket().use { socket ->
            vpnNetwork.bindSocket(socket)
            socket.soTimeout = DnsProbe.ATTEMPT_TIMEOUT_MS.toInt()
            socket.connect(InetSocketAddress(hijackedResolver, DNS_PORT))
            socket.send(DatagramPacket(query, query.size))
            val buffer = ByteArray(MAX_RESPONSE_BYTES)
            val packet = DatagramPacket(buffer, buffer.size)
            socket.receive(packet)
            buffer.copyOf(packet.length)
        }
    }

    private companion object {
        const val DNS_PORT = 53
        const val MAX_RESPONSE_BYTES = 1_024
    }
}
