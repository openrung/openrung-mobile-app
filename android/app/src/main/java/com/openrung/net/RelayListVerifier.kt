package com.openrung.net

import com.google.crypto.tink.subtle.Ed25519Verify
import com.openrung.config.AppConfig
import com.openrung.model.RelayListResponse
import kotlinx.serialization.json.Json
import java.io.IOException
import java.security.GeneralSecurityException
import java.security.MessageDigest
import java.time.Clock
import java.time.Duration
import java.time.Instant
import java.util.Base64

/**
 * A relay-list response that is unsigned or fails verification (SPEC v1 §5.2). Extends
 * [IOException] so every existing caller treats it exactly like any other candidate failure —
 * fall through to the next broker in the discovery race, never accept the data. The message
 * deliberately leads with "unsigned/invalid relay list" (a spec requirement) so the surfaced
 * error cannot be mistaken for a generic network failure.
 */
class RelayListVerificationException(detail: String) :
    IOException("unsigned/invalid relay list: $detail")

/**
 * Verifies broker relay-list responses per SPEC v1 §5.2: an Ed25519 signature (carried in the
 * [SIGNATURE_HEADER] response header) over the EXACT raw body bytes, checked against the operator
 * keys pinned in [AppConfig.RELAY_SIGNING_PUBLIC_KEYS_HEX], followed by the in-body binding and
 * freshness checks (channel, limit echo, not_after).
 *
 * Signing defends channel integrity only: it detaches list authenticity from the transport so
 * discovery can later use non-TLS channels (direct-IP fallback, signed mirrors) without trusting
 * whoever carried the bytes. Out of scope by design: a compromised broker signs whatever it
 * likes, and a censor can still block, strip the header, or inject non-2xx responses — all of
 * which degrade to "candidate failed, fall through", never to accepting forged data.
 *
 * Tink's pure-Java [Ed25519Verify] is used because minSdk 26 predates the platform Ed25519
 * provider (API 33+); a verify costs well under a millisecond.
 */
class RelayListVerifier(
    pinnedPublicKeysHex: List<String> = AppConfig.RELAY_SIGNING_PUBLIC_KEYS_HEX,
    private val clock: Clock = Clock.systemUTC(),
) {

    private class PinnedKey(val keyId: String, val verifier: Ed25519Verify)

    private val pinnedKeys: List<PinnedKey> = pinnedPublicKeysHex.map { hex ->
        val raw = decodeHex(hex)
        require(raw.size == Ed25519Verify.PUBLIC_KEY_LEN) {
            "pinned Ed25519 public key must be ${Ed25519Verify.PUBLIC_KEY_LEN} bytes"
        }
        PinnedKey(keyId(raw), Ed25519Verify(raw))
    }

    init {
        require(pinnedKeys.isNotEmpty()) { "at least one pinned signing key is required" }
    }

    /** A verified relay list plus the pinned key that verified it (the §5.2 telemetry signal). */
    data class Verified(val response: RelayListResponse, val keyIdUsed: String)

    /**
     * Runs the full §5.2 verification over [bodyBytes] exactly as read off the wire — BEFORE any
     * charset decoding, because the signature covers the precise bytes the broker sent — and
     * returns the parsed response. [requestedLimit] is the limit the client put in the query
     * string; the signed body must echo it, which turns a replayed variant (a `limit=1` body
     * answering a `limit=20` request) into a verification failure. Every rejection throws
     * [RelayListVerificationException]: "candidate failed", nothing more.
     */
    fun verifyAndDecode(
        bodyBytes: ByteArray,
        signatureHeader: String?,
        requestedLimit: Int,
        json: Json,
    ): Verified {
        // §5.2 step 2: the signature header is required; missing or malformed fails the candidate.
        val header = signatureHeader?.trim() ?: fail("missing $SIGNATURE_HEADER header")
        val (advisoryKeyId, signature) = parseHeader(header)
        // §5.2 step 3: the signature must verify over the raw bytes under a pinned key.
        val keyIdUsed = verifySignature(bodyBytes, signature, advisoryKeyId)
        // §5.2 step 4: parse the SAME buffer the signature covered, then run the in-body checks.
        val response = try {
            json.decodeFromString<RelayListResponse>(String(bodyBytes, Charsets.UTF_8))
        } catch (error: Exception) {
            fail("signed body is not a relay list (${error.message})")
        }
        // `channel` binds the body to the channel it was fetched from: a (validly signed) mirror
        // artifact must never be accepted in an API-channel slot, and vice versa.
        if (response.channel != EXPECTED_CHANNEL) {
            fail("channel \"${response.channel}\" is not \"$EXPECTED_CHANNEL\"")
        }
        if (response.limit != requestedLimit) {
            fail("echoed limit ${response.limit} does not match requested $requestedLimit")
        }
        // Freshness: not_after (server_time + 30 min on the API channel) against the device
        // clock, with the 5-min slow-clock allowance. Bounds replay of a captured signed body.
        val notAfter = runCatching { Instant.parse(response.notAfter) }.getOrNull()
            ?: fail("not_after \"${response.notAfter}\" is not a valid RFC3339 timestamp")
        if (notAfter < clock.instant().minus(CLOCK_SKEW_ALLOWANCE)) {
            fail("response expired at ${response.notAfter}")
        }
        return Verified(response, keyIdUsed)
    }

    /**
     * §4.2: the header's key_id is ADVISORY routing only — the matching pinned key is tried
     * first, but on mismatch or failure every pinned key is tried, so a broker-side key_id bug
     * costs one wasted ~50 µs verify instead of a discovery outage.
     */
    private fun verifySignature(body: ByteArray, signature: ByteArray, advisoryKeyId: String): String {
        // Stable sort: the advisory match moves to the front, pinned order is kept otherwise.
        val routed = pinnedKeys.sortedByDescending { it.keyId == advisoryKeyId }
        for (pinned in routed) {
            try {
                pinned.verifier.verify(signature, body)
                return pinned.keyId
            } catch (_: GeneralSecurityException) {
                // Not this key — fall through to the next pinned key.
            }
        }
        fail("signature does not verify under any pinned key")
    }

    /**
     * §2.1: exactly three `;`-separated fields — the literal algorithm string "ed25519", the
     * advisory key_id, and the standard-base64 64-byte signature.
     */
    private fun parseHeader(header: String): Pair<String, ByteArray> {
        val fields = header.split(";")
        if (fields.size != 3 || fields[0] != ALGORITHM) {
            fail("malformed signature header")
        }
        val signature = runCatching { Base64.getDecoder().decode(fields[2]) }.getOrNull()
            ?: fail("signature is not valid base64")
        if (signature.size != Ed25519Verify.SIGNATURE_LEN) {
            fail("signature is ${signature.size} bytes, expected ${Ed25519Verify.SIGNATURE_LEN}")
        }
        return fields[1] to signature
    }

    private fun fail(detail: String): Nothing = throw RelayListVerificationException(detail)

    companion object {
        /** Signature response header (§2.1). Matched case-insensitively — HTTP/2 lowercases it. */
        const val SIGNATURE_HEADER = "X-OpenRung-Relays-Signature"

        private const val ALGORITHM = "ed25519"

        /**
         * Every Android candidate today belongs to the API channel; mirror artifacts (channel
         * "mirror", 24 h not_after, no limit echo) join the candidate list in a later phase.
         */
        private const val EXPECTED_CHANNEL = "api"

        /** §5.2: allowance for a slow device clock when checking not_after (resolved at 5 min). */
        private val CLOCK_SKEW_ALLOWANCE: Duration = Duration.ofMinutes(5)

        /**
         * Extracts the signature header from [java.net.HttpURLConnection.getHeaderFields],
         * matching the name case-insensitively: HTTP/2/3 lowercase header names on the wire, and
         * intermediaries may re-case them (§2.1). The map's null key (the status line) is skipped.
         */
        fun signatureHeader(headers: Map<String?, List<String>>): String? = headers.entries
            .firstOrNull { it.key?.equals(SIGNATURE_HEADER, ignoreCase = true) == true }
            ?.value
            ?.firstOrNull()

        /** key_id derivation (§2.2): lowercase hex of the first 8 bytes of SHA-256(raw pubkey). */
        internal fun keyId(publicKey: ByteArray): String =
            MessageDigest.getInstance("SHA-256").digest(publicKey)
                .take(8)
                .joinToString("") { "%02x".format(it) }

        internal fun decodeHex(hex: String): ByteArray {
            require(hex.length % 2 == 0) { "hex string must have even length" }
            return ByteArray(hex.length / 2) { index ->
                hex.substring(2 * index, 2 * index + 2).toInt(16).toByte()
            }
        }
    }
}
