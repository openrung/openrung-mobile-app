package com.openrung.net

import android.os.Build
import android.os.SystemClock
import com.openrung.BuildConfig
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.SocketTimeoutException
import java.net.URI
import java.net.URL
import java.time.Duration
import java.time.Instant
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.time.format.DateTimeParseException
import java.util.Locale
import kotlin.math.min

/** One short-lived credential bound by the broker to an exact relay and signed WSS front. */
data class WssSessionTicket(
    /** Opaque bearer value. It must never be logged or placed in a URL. */
    val ticket: String,
    val expiresAt: Instant,
    /** Exact front URL echoed by the broker; the caller must compare it to the signed descriptor. */
    val url: String,
) {
    /** Never let Kotlin's generated data-class representation expose the bearer credential. */
    override fun toString(): String =
        "WssSessionTicket(ticket=<redacted>, expiresAt=$expiresAt, url=$url)"
}

/**
 * A non-success response from a WSS ticket endpoint. The body is deliberately neither read nor
 * retained, so an origin response can never inject ticket material or attacker text into logs.
 */
class WssTicketStatusException(
    val status: Int,
    val retryAfterMillis: Long?,
) : IOException("broker WSS ticket request failed with HTTP status $status")

/** Bounds one complete broker-front failover attempt, including its optional retry round. */
internal data class WssTicketPolicy(
    val totalDeadlineMillis: Long = 15_000,
    val perAttemptMillis: Long = 5_000,
    val defaultRetryAfterMillis: Long = 10_000,
    val maxRetryAfterMillis: Long = 30_000,
) {
    init {
        require(totalDeadlineMillis > 0) { "WSS ticket total deadline must be positive" }
        require(perAttemptMillis > 0) { "WSS ticket attempt deadline must be positive" }
        require(defaultRetryAfterMillis > 0) { "WSS ticket default retry delay must be positive" }
        require(maxRetryAfterMillis > 0) { "WSS ticket maximum retry delay must be positive" }
    }
}

internal typealias WssTicketAttempt = suspend (
    brokerUrl: String,
    relayId: String,
    frontId: String,
    clientId: String?,
    sessionId: String?,
    timeoutMillis: Long,
) -> WssSessionTicket

/** HTTPS control-plane client for relay/front-bound WSS tickets. */
object WssTicketClient {
    private const val TICKET_PATH = "api/v1/wss/tickets"
    private const val MAX_RESPONSE_BYTES = 64 * 1024
    private const val MAX_TICKET_BYTES = 4_096
    private val json = Json { ignoreUnknownKeys = true }

    /**
     * Tries [brokerUrls] sequentially under one deadline. A 429/503 response permits at most one
     * additional round after a bounded Retry-After wait. Every other failure only advances to the
     * next broker front. If every attempt fails, the first broker's original diagnostic is thrown.
     */
    suspend fun requestWithFailover(
        brokerUrls: List<String>,
        relayId: String,
        frontId: String,
        clientId: String? = null,
        sessionId: String? = null,
    ): WssSessionTicket = requestWithFailover(
        brokerUrls = brokerUrls,
        relayId = relayId,
        frontId = frontId,
        clientId = clientId,
        sessionId = sessionId,
        policy = WssTicketPolicy(),
        elapsedRealtimeMillis = SystemClock::elapsedRealtime,
        wait = { delay(it) },
        attempt = { brokerUrl, requestedRelayId, requestedFrontId, requestedClientId, requestedSessionId, timeout ->
            requestOnce(
                brokerUrl = brokerUrl,
                relayId = requestedRelayId,
                frontId = requestedFrontId,
                clientId = requestedClientId,
                sessionId = requestedSessionId,
                timeoutMillis = timeout,
            )
        },
    )

    /** Injectable core used by focused virtual-time tests and by no other transport policy. */
    internal suspend fun requestWithFailover(
        brokerUrls: List<String>,
        relayId: String,
        frontId: String,
        clientId: String?,
        sessionId: String?,
        policy: WssTicketPolicy,
        elapsedRealtimeMillis: () -> Long,
        wait: suspend (Long) -> Unit,
        attempt: WssTicketAttempt,
    ): WssSessionTicket {
        require(relayId.isNotBlank()) { "WSS ticket relay_id is required" }
        require(frontId.isNotBlank()) { "WSS ticket front_id is required" }
        val fronts = brokerUrls.map(String::trim).filter(String::isNotEmpty).distinct()
        require(fronts.isNotEmpty()) { "no broker fronts configured for WSS ticket" }

        val startedAt = elapsedRealtimeMillis()
        val deadline = saturatedAdd(startedAt, policy.totalDeadlineMillis)
        var firstFailure: Throwable? = null
        var retryDelayMillis: Long? = null

        for (round in 0..1) {
            for (brokerUrl in fronts) {
                currentCoroutineContext().ensureActive()
                val remainingMillis = remainingMillis(deadline, elapsedRealtimeMillis())
                if (remainingMillis <= 0) throw firstFailure ?: ticketDeadlineExceeded()
                val attemptMillis = min(policy.perAttemptMillis, remainingMillis)

                val failure = try {
                    return withTimeout(attemptMillis) {
                        attempt(
                            brokerUrl,
                            relayId,
                            frontId,
                            clientId,
                            sessionId,
                            attemptMillis,
                        )
                    }
                } catch (_: TimeoutCancellationException) {
                    SocketTimeoutException("WSS ticket broker attempt timed out")
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Throwable) {
                    error
                }

                if (firstFailure == null) firstFailure = failure
                if (round == 0) {
                    retryDelayFor(failure, policy)?.let { candidateDelay ->
                        retryDelayMillis = maxOf(retryDelayMillis ?: 0, candidateDelay)
                    }
                }
            }

            if (round == 1) break
            val retryDelay = retryDelayMillis ?: throw checkNotNull(firstFailure)
            val remainingMillis = remainingMillis(deadline, elapsedRealtimeMillis())
            // A wait that consumes the whole remaining budget cannot leave time for another request.
            if (retryDelay >= remainingMillis) throw checkNotNull(firstFailure)
            wait(retryDelay)
            currentCoroutineContext().ensureActive()
            if (remainingMillis(deadline, elapsedRealtimeMillis()) <= 0) {
                throw checkNotNull(firstFailure)
            }
        }

        throw firstFailure ?: ticketDeadlineExceeded()
    }

    /** Performs one cancellable POST. Multi-front and Retry-After policy stays above this layer. */
    internal suspend fun requestOnce(
        brokerUrl: String,
        relayId: String,
        frontId: String,
        clientId: String? = null,
        sessionId: String? = null,
        timeoutMillis: Long = WssTicketPolicy().perAttemptMillis,
        now: () -> Instant = Instant::now,
        openConnection: (URL) -> HttpURLConnection = { it.openConnection() as HttpURLConnection },
    ): WssSessionTicket {
        require(relayId.isNotBlank()) { "WSS ticket relay_id is required" }
        require(frontId.isNotBlank()) { "WSS ticket front_id is required" }
        require(timeoutMillis in 1..Int.MAX_VALUE.toLong()) { "WSS ticket timeout is out of range" }
        val endpoint = ticketEndpoint(brokerUrl)
        val payload = json.encodeToString(
            WssTicketRequest(relayId = relayId, frontId = frontId),
        ).toByteArray(Charsets.UTF_8)

        return withContext(Dispatchers.IO) {
            val connection = openConnection(endpoint)
            connection.apply {
                requestMethod = "POST"
                connectTimeout = timeoutMillis.toInt()
                readTimeout = timeoutMillis.toInt()
                instanceFollowRedirects = false
                useCaches = false
                doOutput = true
                setFixedLengthStreamingMode(payload.size)
                setRequestProperty("Accept", "application/json")
                setRequestProperty("Content-Type", "application/json")
                setRequestProperty("Cache-Control", "no-store")
                setRequestProperty("Pragma", "no-cache")
                setRequestProperty("X-OpenRung-App-Version", BuildConfig.VERSION_NAME)
                setRequestProperty("X-OpenRung-Android-API", Build.VERSION.SDK_INT.toString())
                if (!clientId.isNullOrBlank() && !sessionId.isNullOrBlank()) {
                    setRequestProperty("X-OpenRung-Client-ID", clientId)
                    setRequestProperty("X-OpenRung-Session-ID", sessionId)
                }
            }

            // HttpURLConnection's blocking connect/read calls do not observe coroutine cancellation.
            // A sibling child runs disconnect() as soon as this request is cancelled or times out.
            val disconnectOnCancel = launch {
                try {
                    awaitCancellation()
                } finally {
                    runCatching { connection.disconnect() }
                }
            }
            try {
                connection.outputStream.use { it.write(payload) }
                val status = connection.responseCode
                val responseNow = now()
                if (status !in 200..299) {
                    throw WssTicketStatusException(
                        status = status,
                        retryAfterMillis = parseRetryAfterMillis(
                            connection.getHeaderField("Retry-After"),
                            responseNow,
                        ),
                    )
                }
                decodeTicket(connection.inputStream.readBounded(MAX_RESPONSE_BYTES), responseNow)
            } finally {
                disconnectOnCancel.cancel()
                runCatching { connection.disconnect() }
            }
        }
    }

    /** Resolves the fixed endpoint without carrying query, fragment, credentials, or a downgrade. */
    internal fun ticketEndpoint(baseUrl: String): URL {
        val value = baseUrl.trim()
        require(value.isNotEmpty()) { "WSS ticket broker URL is required" }
        val uri = runCatching { URI(value) }.getOrElse {
            throw IllegalArgumentException("invalid WSS ticket broker URL")
        }
        require(!uri.isOpaque && !uri.host.isNullOrBlank() && uri.rawUserInfo == null) {
            "WSS ticket broker URL must have a host and no userinfo"
        }
        require(uri.port == -1 || uri.port in 1..65_535) { "WSS ticket broker URL has an invalid port" }
        val scheme = uri.scheme?.lowercase(Locale.ROOT)
        val secure = scheme == "https"
        val loopbackDevelopment = scheme == "http" && hostIsLoopback(uri.host)
        require(secure || loopbackDevelopment) {
            "WSS ticket broker URL must use HTTPS (HTTP is allowed only on loopback)"
        }

        val basePath = uri.path.orEmpty().trim('/')
        val path = listOf(basePath, TICKET_PATH)
            .filter(String::isNotEmpty)
            .joinToString(separator = "/", prefix = "/")
        return URI(scheme, null, uri.host, uri.port, path, null, null).toURL()
    }

    /** Parses delta-seconds or one of the three HTTP-date forms accepted by RFC 9110. */
    internal fun parseRetryAfterMillis(value: String?, now: Instant): Long? {
        val trimmed = value?.trim().orEmpty()
        if (trimmed.isEmpty()) return null
        if (trimmed.all { it in '0'..'9' }) {
            // A syntactically valid but enormous delta is not an invalid hint. Saturating it lets
            // policy clamp it to maxRetryAfterMillis instead of replacing it with the default.
            val significantDigits = trimmed.dropWhile { it == '0' }
            if (significantDigits.isEmpty()) return 0
            val seconds = significantDigits.toLongOrNull() ?: return Long.MAX_VALUE
            return if (seconds > Long.MAX_VALUE / 1_000) Long.MAX_VALUE else seconds * 1_000
        }

        val retryAt = HTTP_DATE_FORMATTERS.firstNotNullOfOrNull { formatter ->
            try {
                ZonedDateTime.parse(trimmed, formatter).toInstant()
            } catch (_: DateTimeParseException) {
                null
            }
        } ?: return null
        if (!retryAt.isAfter(now)) return null
        return runCatching { Duration.between(now, retryAt).toMillis() }
            .getOrNull()
            ?.takeIf { it >= 0 }
    }

    private fun retryDelayFor(error: Throwable, policy: WssTicketPolicy): Long? {
        val statusError = error as? WssTicketStatusException ?: return null
        if (statusError.status != 429 && statusError.status != 503) return null
        // Match desktop policy: a zero delta is treated as absent rather than permitting a hot loop.
        val requested = statusError.retryAfterMillis?.takeIf { it > 0 }
            ?: policy.defaultRetryAfterMillis
        return requested.coerceAtMost(policy.maxRetryAfterMillis)
    }

    private fun decodeTicket(body: ByteArray, now: Instant): WssSessionTicket {
        val decoded = runCatching {
            json.decodeFromString<WssTicketResponse>(String(body, Charsets.UTF_8))
        }.getOrElse {
            // Do not retain the parser exception: it can quote attacker-controlled response bytes.
            throw IOException("decode WSS ticket response")
        }
        val ticketBytes = decoded.ticket.toByteArray(Charsets.UTF_8).size
        if (ticketBytes !in 1..MAX_TICKET_BYTES || decoded.ticket.contains('\r') || decoded.ticket.contains('\n')) {
            throw IOException("WSS ticket response has a missing or oversized ticket")
        }
        if (decoded.url.isBlank()) throw IOException("WSS ticket response has no URL")
        val expiresAt = runCatching { Instant.parse(decoded.expiresAt) }.getOrNull()
            ?: throw IOException("WSS ticket response has an invalid expires_at")
        if (!expiresAt.isAfter(now)) throw IOException("WSS ticket response is already expired")
        return WssSessionTicket(ticket = decoded.ticket, expiresAt = expiresAt, url = decoded.url)
    }

    private fun InputStream.readBounded(maxBytes: Int): ByteArray {
        val output = ByteArrayOutputStream(min(maxBytes, 8 * 1_024))
        val buffer = ByteArray(8 * 1_024)
        while (true) {
            val count = read(buffer)
            if (count < 0) break
            if (count == 0) continue
            if (output.size() > maxBytes - count) {
                throw IOException("WSS ticket response exceeds $maxBytes bytes")
            }
            output.write(buffer, 0, count)
        }
        return output.toByteArray()
    }

    private fun saturatedAdd(value: Long, increment: Long): Long =
        if (value > Long.MAX_VALUE - increment) Long.MAX_VALUE else value + increment

    private fun remainingMillis(deadline: Long, now: Long): Long =
        if (now >= deadline) 0 else deadline - now

    private fun ticketDeadlineExceeded(): SocketTimeoutException =
        SocketTimeoutException("WSS ticket request deadline exceeded")

    /** Literal-only check: whether HTTP is permitted must never depend on an attacker-controlled DNS answer. */
    private fun hostIsLoopback(host: String): Boolean {
        val bare = host.trim().removePrefix("[").removeSuffix("]")
        if (bare.equals("localhost", ignoreCase = true)) return true
        val isLiteral = bare.isNotEmpty() &&
            (bare.all { it.isDigit() || it == '.' } || bare.contains(':'))
        return isLiteral && runCatching { InetAddress.getByName(bare).isLoopbackAddress }
            .getOrDefault(false)
    }

    @Serializable
    private data class WssTicketRequest(
        @SerialName("relay_id") val relayId: String,
        @SerialName("front_id") val frontId: String,
    )

    @Serializable
    private data class WssTicketResponse(
        val ticket: String = "",
        @SerialName("expires_at") val expiresAt: String = "",
        val url: String = "",
    )

    private val HTTP_DATE_FORMATTERS = listOf(
        DateTimeFormatter.RFC_1123_DATE_TIME,
        DateTimeFormatter.ofPattern("EEEE, dd-MMM-yy HH:mm:ss zzz", Locale.US),
        DateTimeFormatter.ofPattern("EEE MMM d HH:mm:ss yyyy", Locale.US),
    )
}
