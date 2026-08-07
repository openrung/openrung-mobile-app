package com.openrung.net

import android.content.Context
import android.net.ConnectivityManager
import android.net.DnsResolver
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.os.CancellationSignal
import android.os.SystemClock
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asExecutor
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.HttpURLConnection
import java.net.Inet4Address
import java.net.InetAddress
import java.net.UnknownHostException
import java.net.URL
import kotlin.random.Random
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

data class InternetProbeResult(
    val endpoint: String,
    val durationMs: Long,
)

/** A remote endpoint answered, but did not provide a usable through-tunnel response. */
class InternetProbeHttpStatusException(
    val status: Int,
) : IOException("internet probe returned HTTP $status")

/** Ordering seam shared by startup and health probes: HTTPS can never mask a DNS failure. */
internal suspend fun runFreshDnsHttpsProbe(
    resolveFreshDns: suspend () -> Unit,
    probeHttps: suspend () -> Unit,
) {
    resolveFreshDns()
    probeHttps()
}

/** Minimal DNS wire codec for the API 26-28 cache-bypass path. */
internal object TunnelDnsAProbe {
    fun makeQuery(hostname: String, transactionId: Int): ByteArray {
        require(transactionId in 0..0xffff) { "DNS transaction ID is out of range" }
        val normalizedHostname = hostname.removeSuffix(".")
        require(normalizedHostname.isNotEmpty() && normalizedHostname.length <= MAX_HOSTNAME_LENGTH) {
            "invalid DNS hostname"
        }

        val labels = normalizedHostname.split('.')
        val output = ByteArrayOutputStream(DNS_HEADER_LENGTH + normalizedHostname.length + 6)
        output.write(transactionId ushr 8)
        output.write(transactionId)
        output.write(0x01)
        output.write(0x00) // Recursion desired.
        output.write(0x00)
        output.write(0x01) // One question.
        repeat(6) { output.write(0x00) }
        labels.forEach { label ->
            require(
                label.isNotEmpty() &&
                    label.length <= MAX_LABEL_LENGTH &&
                    label.all { it.code in 1..0x7f },
            ) { "invalid DNS hostname" }
            output.write(label.length)
            output.write(label.toByteArray(Charsets.US_ASCII))
        }
        output.write(0x00)
        output.write(0x00)
        output.write(0x01) // A.
        output.write(0x00)
        output.write(0x01) // IN.
        return output.toByteArray()
    }

    /** Requires a complete NOERROR reply containing at least one IPv4 address answer. */
    fun validateResponse(
        response: ByteArray,
        transactionId: Int,
        length: Int = response.size,
    ) {
        if (length !in DNS_HEADER_LENGTH..response.size) invalidResponse("truncated header")
        if (readUInt16(response, 0) != transactionId) invalidResponse("transaction mismatch")

        val flags = readUInt16(response, 2)
        if (flags and RESPONSE_FLAG == 0) invalidResponse("query packet received")
        if (flags and OPCODE_MASK != 0) invalidResponse("unexpected opcode")
        if (flags and TRUNCATED_FLAG != 0) invalidResponse("truncated reply")
        if (flags and RESPONSE_CODE_MASK != 0) invalidResponse("resolver returned an error")
        val questionCount = readUInt16(response, 4)
        val answerCount = readUInt16(response, 6)
        if (questionCount != 1) invalidResponse("unexpected question count")

        var offset = skipName(response, length, DNS_HEADER_LENGTH)
        if (offset > length - QUESTION_TRAILER_LENGTH) invalidResponse("truncated question")
        if (
            readUInt16(response, offset) != RECORD_TYPE_A ||
            readUInt16(response, offset + 2) != RECORD_CLASS_IN
        ) {
            invalidResponse("unexpected question type")
        }
        offset += QUESTION_TRAILER_LENGTH

        repeat(answerCount) {
            offset = skipName(response, length, offset)
            if (offset > length - RESOURCE_RECORD_HEADER_LENGTH) {
                invalidResponse("truncated answer")
            }
            val recordType = readUInt16(response, offset)
            val recordClass = readUInt16(response, offset + 2)
            val dataLength = readUInt16(response, offset + 8)
            offset += RESOURCE_RECORD_HEADER_LENGTH
            if (dataLength > length - offset) invalidResponse("truncated answer data")
            if (
                recordType == RECORD_TYPE_A &&
                recordClass == RECORD_CLASS_IN &&
                dataLength == IPV4_ADDRESS_LENGTH
            ) {
                return
            }
            offset += dataLength
        }
        invalidResponse("reply contained no IPv4 address")
    }

    private fun skipName(
        response: ByteArray,
        length: Int,
        startingOffset: Int,
        compressionDepth: Int = 0,
    ): Int {
        if (compressionDepth > MAX_COMPRESSION_DEPTH) invalidResponse("compression loop")
        var offset = startingOffset
        var labels = 0
        while (true) {
            if (offset >= length || labels > MAX_NAME_LABELS) invalidResponse("truncated name")
            val labelLength = response[offset].toInt() and 0xff
            when {
                labelLength and COMPRESSION_MASK == COMPRESSION_MASK -> {
                    if (offset >= length - 1) invalidResponse("truncated compression pointer")
                    val pointer =
                        ((labelLength and COMPRESSION_POINTER_MASK) shl 8) or
                            (response[offset + 1].toInt() and 0xff)
                    if (pointer < DNS_HEADER_LENGTH || pointer >= offset) {
                        invalidResponse("invalid compression pointer")
                    }
                    skipName(response, length, pointer, compressionDepth + 1)
                    return offset + 2
                }

                labelLength and COMPRESSION_MASK != 0 -> invalidResponse("invalid label")
                labelLength == 0 -> return offset + 1
                labelLength > MAX_LABEL_LENGTH -> invalidResponse("invalid label length")
                else -> {
                    offset += 1
                    if (labelLength > length - offset) invalidResponse("truncated label")
                    offset += labelLength
                    labels += 1
                }
            }
        }
    }

    private fun readUInt16(bytes: ByteArray, offset: Int): Int =
        ((bytes[offset].toInt() and 0xff) shl 8) or
            (bytes[offset + 1].toInt() and 0xff)

    private fun invalidResponse(detail: String): Nothing =
        throw IOException("invalid DNS response: $detail")

    private const val DNS_HEADER_LENGTH = 12
    private const val QUESTION_TRAILER_LENGTH = 4
    private const val RESOURCE_RECORD_HEADER_LENGTH = 10
    private const val RECORD_TYPE_A = 1
    private const val RECORD_CLASS_IN = 1
    private const val IPV4_ADDRESS_LENGTH = 4
    private const val RESPONSE_FLAG = 0x8000
    private const val OPCODE_MASK = 0x7800
    private const val TRUNCATED_FLAG = 0x0200
    private const val RESPONSE_CODE_MASK = 0x000f
    private const val COMPRESSION_MASK = 0xc0
    private const val COMPRESSION_POINTER_MASK = 0x3f
    private const val MAX_HOSTNAME_LENGTH = 253
    private const val MAX_LABEL_LENGTH = 63
    private const val MAX_NAME_LABELS = 127
    private const val MAX_COMPRESSION_DEPTH = 127
}

class InternetProbe(context: Context) {
    private val connectivityManager = context.getSystemService(ConnectivityManager::class.java)

    suspend fun verify(): InternetProbeResult {
        val started = SystemClock.elapsedRealtime()
        val deadline = started + PROBE_DEADLINE_MS
        var lastError: Throwable? = null

        while (SystemClock.elapsedRealtime() < deadline) {
            val vpnNetwork = currentVpnNetwork()
            if (vpnNetwork == null) {
                // Do not retain an earlier remote-looking endpoint error after Android has lost
                // the local VPN Network. The final observation controls classification, so a TUN
                // publication/teardown problem can never authorize WSS.
                lastError = IOException("VPN network is unavailable")
                delay(RETRY_DELAY_MS)
                continue
            }

            for (endpoint in ENDPOINTS) {
                try {
                    probe(vpnNetwork, endpoint)
                    return InternetProbeResult(
                        endpoint = endpoint,
                        durationMs = SystemClock.elapsedRealtime() - started,
                    )
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Throwable) {
                    lastError = error
                }
            }
            delay(RETRY_DELAY_MS)
        }

        throw IOException(
            "VPN started, but the internet probe failed" +
                (lastError?.message?.let { ": $it" } ?: ""),
            lastError,
        )
    }

    /** One no-retry sweep used by the long-lived tunnel health monitor. */
    suspend fun verifyOnce(): InternetProbeResult {
        val started = SystemClock.elapsedRealtime()
        val vpnNetwork = currentVpnNetwork() ?: throw IOException("VPN network is unavailable")
        var lastError: Throwable? = null
        for (endpoint in ENDPOINTS) {
            try {
                probe(vpnNetwork, endpoint)
                return InternetProbeResult(
                    endpoint = endpoint,
                    durationMs = SystemClock.elapsedRealtime() - started,
                )
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                lastError = error
            }
        }
        throw IOException(
            "tunnel health probe failed" + (lastError?.message?.let { ": $it" } ?: ""),
            lastError,
        )
    }

    private fun currentVpnNetwork(): Network? =
        connectivityManager.allNetworks.firstOrNull { network ->
            connectivityManager.getNetworkCapabilities(network)
                ?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
        }

    private suspend fun probe(network: Network, endpoint: String) {
        val url = URL(endpoint)
        // An HTTPS-only check can reuse a cached address and say nothing about the tunnel's DNS
        // path. Force a resolution on this exact VPN Network first. The matching sing-box rule
        // also disables its own cache, so every supported API reaches proxied DoH per attempt.
        runFreshDnsHttpsProbe(
            resolveFreshDns = { resolveFreshDns(network, url.host) },
            probeHttps = { probeHttps(network, url) },
        )
    }

    private suspend fun probeHttps(network: Network, url: URL) = withContext(Dispatchers.IO) {
        val connection = (network.openConnection(url) as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = REQUEST_TIMEOUT_MS
            readTimeout = REQUEST_TIMEOUT_MS
            instanceFollowRedirects = false
            useCaches = false
            setRequestProperty("Cache-Control", "no-cache")
        }

        try {
            val status = connection.responseCode
            if (!acceptsHttpStatus(status)) {
                throw InternetProbeHttpStatusException(status)
            }
            connection.inputStream.use { input -> input.read() }
        } finally {
            connection.disconnect()
        }
    }

    private suspend fun resolveFreshDns(network: Network, hostname: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            // Network.getAllByName() can reuse netd's cache on API 26-28. Address the VPN's own
            // DNS listener with a raw query instead: bindSocket keeps the datagram in this VPN,
            // while the exact sing-box probe rule disables its upstream cache.
            return resolveFreshDnsLegacy(network, hostname)
        }

        resolveFreshDnsApi29(network, hostname)
    }

    private suspend fun resolveFreshDnsLegacy(network: Network, hostname: String) {
        val tunnelDnsServers = connectivityManager.getLinkProperties(network)?.dnsServers.orEmpty()
        val tunnelDnsServer = tunnelDnsServers.firstOrNull { it is Inet4Address }
            ?: tunnelDnsServers.firstOrNull()
            ?: throw UnknownHostException("VPN DNS listener is unavailable")
        val transactionId = Random.nextInt(0x10000)
        val query = try {
            TunnelDnsAProbe.makeQuery(hostname, transactionId)
        } catch (error: IllegalArgumentException) {
            throw UnknownHostException("invalid DNS probe hostname: $hostname").apply {
                initCause(error)
            }
        }

        suspendCancellableCoroutine { continuation ->
            val socket = try {
                DatagramSocket()
            } catch (error: IOException) {
                continuation.resumeWithException(
                    UnknownHostException("fresh DNS lookup failed for $hostname").apply {
                        initCause(error)
                    },
                )
                return@suspendCancellableCoroutine
            }
            continuation.invokeOnCancellation { socket.close() }
            Dispatchers.IO.asExecutor().execute {
                try {
                    // bindSocket must run before connect; do not protect this socket, because its
                    // purpose is specifically to enter the TUN and exercise proxied DoH.
                    network.bindSocket(socket)
                    // The generated resolver chain permits a 2s primary evaluation followed by
                    // a 3s secondary attempt. Leave enough room for the secondary response.
                    socket.soTimeout = LEGACY_DNS_TIMEOUT_MS
                    socket.connect(tunnelDnsServer, DNS_PORT)
                    socket.send(DatagramPacket(query, query.size))

                    val response = ByteArray(MAX_DNS_RESPONSE_SIZE)
                    val packet = DatagramPacket(response, response.size)
                    socket.receive(packet)
                    TunnelDnsAProbe.validateResponse(
                        response = packet.data,
                        transactionId = transactionId,
                        length = packet.length,
                    )
                    if (continuation.isActive) continuation.resume(Unit)
                } catch (error: Exception) {
                    if (continuation.isActive) {
                        // Only wire/transport failures are remote DNS evidence. Preserve local
                        // permission and programming failures for FailureClassifier.
                        val failure = if (error is IOException) {
                            UnknownHostException("fresh DNS lookup failed for $hostname").apply {
                                initCause(error)
                            }
                        } else {
                            error
                        }
                        continuation.resumeWithException(failure)
                    }
                } finally {
                    socket.close()
                }
            }
        }
    }

    @Suppress("NewApi")
    private suspend fun resolveFreshDnsApi29(network: Network, hostname: String) =
        suspendCancellableCoroutine { continuation ->
            val cancellationSignal = CancellationSignal()
            continuation.invokeOnCancellation { cancellationSignal.cancel() }
            DnsResolver.getInstance().query(
                network,
                hostname,
                // Bypass Android/netd's lookup cache. Allow storing the fresh answer so the
                // immediately-following HTTPS request can reuse precisely what was just proved.
                DnsResolver.FLAG_NO_CACHE_LOOKUP,
                Dispatchers.IO.asExecutor(),
                cancellationSignal,
                object : DnsResolver.Callback<List<InetAddress>> {
                    override fun onAnswer(answer: List<InetAddress>, rcode: Int) {
                        if (!continuation.isActive) return
                        if (rcode != 0 || answer.isEmpty()) {
                            continuation.resumeWithException(
                                UnknownHostException(
                                    "fresh DNS lookup failed for $hostname (rcode=$rcode)",
                                ),
                            )
                        } else {
                            continuation.resume(Unit)
                        }
                    }

                    override fun onError(error: DnsResolver.DnsException) {
                        if (!continuation.isActive) return
                        continuation.resumeWithException(
                            UnknownHostException("fresh DNS lookup failed for $hostname").apply {
                                initCause(error)
                            },
                        )
                    }
                },
            )
        }

    companion object {
        private const val PROBE_DEADLINE_MS = 12_000L
        private const val RETRY_DELAY_MS = 500L
        private const val REQUEST_TIMEOUT_MS = 3_000
        private const val LEGACY_DNS_TIMEOUT_MS = 6_000
        private const val DNS_PORT = 53
        private const val MAX_DNS_RESPONSE_SIZE = 4_096

        internal val ENDPOINTS = listOf(
            "https://${SingBoxConfiguration.CONNECTIVITY_PROBE_HOST}/generate_204",
        )

        internal fun acceptsHttpStatus(status: Int): Boolean = status in 200..299
    }
}
