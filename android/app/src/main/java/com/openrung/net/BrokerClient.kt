package com.openrung.net

import android.os.Build
import com.openrung.BuildConfig
import com.openrung.config.AppConfig
import com.openrung.model.ErrorResponse
import com.openrung.model.RelayListResponse
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import java.io.IOException
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.URI
import java.net.URL
import java.net.URLEncoder
import java.util.concurrent.atomic.AtomicInteger

/**
 * A non-2xx HTTP response from the broker. Carries the status [code] so a failure can be classified
 * (429 → `rate_limited`, otherwise `http_<code>`) instead of being flattened into a generic
 * [IOException] message where the code is lost. Extends [IOException] so existing callers — which
 * already treat broker failures as `IOException` — are unaffected.
 */
class BrokerHttpException(val status: Int, message: String) : IOException(message)

class BrokerClient(
    private val baseUrl: String,
    private val json: Json = Json { ignoreUnknownKeys = true },
    private val verifier: RelayListVerifier = RelayListVerifier(),
    /**
     * When true, loopback brokers are signature-verified like any other candidate. Production
     * leaves this false: loopback (the adb-reverse dev flow) is the ONE signature-exempt channel,
     * mirroring the desktop client's `EnforceSecureBrokerURL` loopback-http allowance (SPEC v1
     * §5.2). Internal so the HTTP-level signing tests can force verification against a 127.0.0.1
     * fixture server.
     */
    internal val requireSignatureOnLoopback: Boolean = false,
) {
    suspend fun listRelays(
        limit: Int = 5,
        clientId: String? = null,
        sessionId: String? = null,
    ): RelayListResponse = withContext(Dispatchers.IO) {
        // What the query string will actually ask for — a signed response must echo it (§2.2).
        val requestedLimit = effectiveLimit(limit)
        val url = URL(relayListUrl(baseUrl, limit))
        val connection = (url.openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 10_000
            readTimeout = 15_000
            // Real-time data served with a long max-age by the broker edge — never let any
            // installed HTTP response cache replay a stale relay list.
            useCaches = false
            setRequestProperty("Cache-Control", "no-cache, no-store")
            if (!url.protocol.equals("https", ignoreCase = true)) {
                // Non-TLS candidate discipline (SPEC v1 §5.2/§6): no transparent gzip —
                // HttpURLConnection silently adds it otherwise, and a middlebox recompressing
                // cleartext would change the exact bytes the relay-list signature covers — and
                // no redirect-following, so an on-path attacker's 3xx is just a failed candidate.
                // TLS candidates are untouched: edge compression decodes back to origin bytes.
                setRequestProperty("Accept-Encoding", "identity")
                instanceFollowRedirects = false
            }
            clientId?.let { setRequestProperty("X-OpenRung-Client-ID", it) }
            sessionId?.let { setRequestProperty("X-OpenRung-Session-ID", it) }
            setRequestProperty("X-OpenRung-App-Version", BuildConfig.VERSION_NAME)
            setRequestProperty("X-OpenRung-Android-API", Build.VERSION.SDK_INT.toString())
        }

        // HttpURLConnection I/O is blocking and never observes coroutine cancellation on its own.
        // When this attempt is cancelled — it lost the discovery race in [firstReachable], or the
        // caller went away — disconnect() makes the blocked connect/read fail immediately, so the
        // losing socket is freed right away instead of running out its 10 s / 15 s timeouts
        // (which would also stall the race winner: structured concurrency waits for cancelled
        // attempts to finish).
        val disconnectOnCancel = launch {
            try {
                awaitCancellation()
            } finally {
                runCatching { connection.disconnect() }
            }
        }

        try {
            val status = connection.responseCode
            val stream = if (status in 200..299) {
                connection.inputStream
            } else {
                connection.errorStream ?: connection.inputStream
            }
            // Raw bytes straight off the connection stream, BEFORE any charset decoding: the
            // relay-list signature covers the exact bytes the broker sent (SPEC v1 §5.1), so a
            // readText() decode + re-encode has no place on this path.
            val bodyBytes = stream.use { it.readBytes() }
            if (status !in 200..299) {
                // Non-2xx responses are unsigned by design and always mean "candidate failed" —
                // never authenticated broker state (SPEC v1 §5.2 step 1).
                val body = String(bodyBytes, Charsets.UTF_8)
                val apiError = runCatching { json.decodeFromString<ErrorResponse>(body).error }.getOrNull()
                throw BrokerHttpException(
                    status,
                    "broker list relays: ${apiError?.ifBlank { null } ?: body.ifBlank { connection.responseMessage }}",
                )
            }
            if (requireSignatureOnLoopback || !hostIsLoopback(url.host)) {
                verifier.verifyAndDecode(
                    bodyBytes = bodyBytes,
                    signatureHeader = RelayListVerifier.signatureHeader(connection.headerFields),
                    requestedLimit = requestedLimit,
                    json = json,
                ).response
            } else {
                // Loopback dev brokers (adb reverse) stay usable unsigned — the one exemption.
                json.decodeFromString<RelayListResponse>(String(bodyBytes, Charsets.UTF_8))
            }
        } finally {
            disconnectOnCancel.cancel()
            connection.disconnect()
        }
    }

    /** A successful relay fetch together with the broker endpoint that served it. */
    data class Fetch(val brokerUrl: String, val response: RelayListResponse)

    companion object {
        /**
         * Builds the ordered broker candidate list, de-duplicated while preserving order. A non-blank
         * [primary] is tried FIRST only when it is a genuine override — i.e. not already one of the
         * [fallbacks]. A persisted value that merely echoes a built-in default must NOT reorder the
         * defaults' preferred (HTTPS-first) ordering, otherwise an upgrader whose last-used default was
         * the raw IP would keep hitting the IP before the Cloudflare-fronted endpoint. Pure and
         * side-effect free so it is unit-testable.
         */
        fun candidates(primary: String?, fallbacks: List<String>): List<String> {
            val ordered = LinkedHashSet<String>()
            val trimmedPrimary = primary?.trim()?.takeIf { it.isNotEmpty() }
            if (trimmedPrimary != null && fallbacks.none { it.trim() == trimmedPrimary }) {
                ordered.add(trimmedPrimary)
            }
            fallbacks.forEach { fallback ->
                fallback.trim().takeIf { it.isNotEmpty() }?.let { ordered.add(it) }
            }
            return ordered.toList()
        }

        /**
         * Staggered-race discovery (happy-eyeballs style) across the candidate brokers, returning
         * the first success along with the endpoint that served it. A blocked or blackholed
         * primary front therefore costs one [AppConfig.DISCOVERY_STAGGER_MS] of extra latency —
         * not a full request timeout — before a fallback front is contacted, and never takes
         * discovery offline as long as one candidate is reachable.
         *
         * Race semantics — MUST stay identical across the desktop Go client, the reference
         * TypeScript implementation (`src/net/brokerClient.ts`), this Kotlin port and the iOS
         * Swift port:
         *
         *  1. candidate[0] starts immediately; while no attempt has succeeded yet, every
         *     [AppConfig.DISCOVERY_STAGGER_MS] the next not-yet-started candidate joins the race.
         *     An early FAILURE does not accelerate the schedule — starts are driven purely by
         *     the stagger cadence.
         *  2. The first SUCCESS wins and returns immediately, cancelling every other in-flight
         *     attempt for real ([listRelays] disconnects on cancellation, freeing the socket).
         *     A later candidate that succeeds first wins even while an earlier-priority attempt
         *     is still pending: candidate order buys a head start in the race, nothing more.
         *  3. The per-attempt timeout is unchanged (connect 10 s / read 15 s in [listRelays]).
         *  4. If EVERY candidate fails, the FIRST candidate's (the primary's) error is rethrown —
         *     the primary's failure is the meaningful diagnostic; later fallbacks' errors are
         *     secondary.
         *  5. With a single candidate the observable behavior equals the old sequential loop:
         *     one attempt, no stagger timers, its error propagated unchanged.
         *
         * Cancelling the caller cancels the whole race, including every in-flight attempt.
         */
        suspend fun firstReachable(
            candidates: List<String>,
            limit: Int = 5,
            clientId: String? = null,
            sessionId: String? = null,
            json: Json = Json { ignoreUnknownKeys = true },
        ): Fetch = firstReachable(candidates) { url ->
            BrokerClient(url, json).listRelays(limit, clientId, sessionId)
        }

        /**
         * Race core behind [firstReachable] with the per-candidate fetch injectable, so the
         * stagger / first-success / all-fail semantics are unit-testable on the JVM under
         * virtual time (see `BrokerClientTest`) without real sockets.
         */
        internal suspend fun firstReachable(
            candidates: List<String>,
            attempt: suspend (String) -> RelayListResponse,
        ): Fetch {
            require(candidates.isNotEmpty()) { "no broker endpoints configured" }
            // Failure of each settled attempt, index-aligned with [candidates]; errors[0] is the
            // surfaced diagnostic (spec point 4). Attempts fail on arbitrary threads, but every
            // slot is written before its incrementAndGet below, so the increment that completes
            // the count publishes all slots (happens-before via the atomic) to whoever reads
            // them after observing the final count.
            val errors = arrayOfNulls<Throwable>(candidates.size)
            val failures = AtomicInteger(0)
            return coroutineScope {
                // Completed with the winning fetch, or with null once EVERY candidate failed.
                val winner = CompletableDeferred<Fetch?>()
                fun recordFailure(index: Int, error: Throwable) {
                    errors[index] = error
                    // Spec point 4: the race is lost only once ALL candidates have started and
                    // failed; null-completion routes the primary's error to the caller below. A
                    // failure never starts the next candidate early (spec point 1).
                    if (failures.incrementAndGet() == candidates.size) {
                        winner.complete(null)
                    }
                }
                candidates.forEachIndexed { index, candidateUrl ->
                    launch {
                        // Spec point 1: the stagger cadence alone drives starts — candidate N
                        // joins the race N staggers after candidate 0, never earlier.
                        delay(index * AppConfig.DISCOVERY_STAGGER_MS)
                        if (winner.isCompleted) return@launch // a winner emerged while we slept
                        try {
                            // First success wins (spec point 2); a success arriving after the
                            // race settled is dropped by the already-completed deferred.
                            winner.complete(Fetch(candidateUrl, attempt(candidateUrl)))
                        } catch (cancellation: CancellationException) {
                            // Normal loser path: this attempt was cancelled because another one
                            // won (or the caller went away). Only a still-live attempt that threw
                            // CancellationException of its own accord is recorded as a failure,
                            // so a pathological attempt cannot leave the race unsettled.
                            if (!isActive) throw cancellation
                            recordFailure(index, cancellation)
                        } catch (error: Throwable) {
                            recordFailure(index, error)
                        }
                    }
                }
                val first = winner.await()
                // Spec point 2: settle immediately — cancel the still-sleeping and in-flight
                // losers (their sockets are torn down by listRelays' cancellation handling).
                coroutineContext.cancelChildren()
                first ?: throw (errors[0] ?: IOException("no broker endpoints reachable"))
            }
        }

        /**
         * The limit actually requested from the broker: non-positive values fall back to the
         * broker's default page size of 5. This is also the value a signed response must echo
         * back in its `limit` field (SPEC v1 §2.2), so [listRelays] and [relayListUrl] MUST
         * derive it identically — hence the shared helper.
         */
        internal fun effectiveLimit(limit: Int): Int = if (limit < 1) 5 else limit

        /**
         * Whether [host] (as returned by [URL.getHost], so IPv6 literals keep their brackets) is
         * localhost or a loopback IP literal — the one signature-exempt broker channel, mirroring
         * the desktop client's `hostIsLoopback` (internal/client/broker.go). The literal check
         * gates the [InetAddress] call so a plain hostname never triggers a DNS lookup here (a
         * DNS answer must never decide whether verification is skipped).
         */
        internal fun hostIsLoopback(host: String): Boolean {
            val bare = host.trim().removePrefix("[").removeSuffix("]")
            if (bare.equals("localhost", ignoreCase = true)) return true
            val isLiteral = bare.isNotEmpty() && (bare.all { it.isDigit() || it == '.' } || bare.contains(':'))
            return isLiteral && runCatching { InetAddress.getByName(bare).isLoopbackAddress }.getOrDefault(false)
        }

        fun relayListUrl(baseUrl: String, limit: Int): String {
            val trimmed = baseUrl.trim()
            require(trimmed.isNotBlank()) { "broker URL is required" }

            val uri = URI(trimmed)
            require(!uri.scheme.isNullOrBlank() && !uri.host.isNullOrBlank()) {
                "broker URL must include scheme and host"
            }

            val basePath = uri.rawPath.orEmpty().trim('/')
            val relayPath = listOf(basePath, "api/v1/relays")
                .filter { it.isNotBlank() }
                .joinToString(separator = "/", prefix = "/")
            val query = appendLimit(uri.rawQuery, effectiveLimit(limit))
            return URI(uri.scheme, uri.userInfo, uri.host, uri.port, relayPath, query, null).toString()
        }

        private fun appendLimit(rawQuery: String?, limit: Int): String {
            val encodedLimit = URLEncoder.encode(limit.toString(), Charsets.UTF_8.name())
            val existing = rawQuery
                ?.split("&")
                ?.filter { it.isNotBlank() }
                ?.filterNot { it.substringBefore("=") == "limit" }
                .orEmpty()
            return (existing + "limit=$encodedLimit")
                .joinToString("&")
        }
    }
}
