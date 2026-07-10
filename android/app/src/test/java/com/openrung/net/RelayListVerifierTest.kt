package com.openrung.net

import com.google.crypto.tink.subtle.Ed25519Sign
import com.google.crypto.tink.subtle.Ed25519Verify
import com.openrung.config.AppConfig
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import java.util.Base64

// Shared signing test vector (SPEC v1 §2.3) — the seed is 32 bytes of 0x42, TEST ONLY. The same
// vector is committed in every client repo (testdata/signing_vectors.json) so all four verifiers
// are pinned to identical bytes.
private const val TEST_SEED_B64 = "QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI="
private const val TEST_PUBKEY_HEX = "2152f8d19b791d24453242e15f2eab6cb7cffa7b6a5ed30097960e069881db12"
private const val TEST_KEY_ID = "3097e2dee2cb4a34"
private const val VECTOR_BODY =
    """{"count":1,"server_time":"2026-07-10T00:00:00Z","not_after":"2026-07-10T00:30:00Z","key_id":"3097e2dee2cb4a34","channel":"api","limit":1,"relays":[]}"""
private const val VECTOR_SIG_B64 =
    "K5UmJWzoEZ1YHOqZFf5E+ocNOITSe3WPvOo0GuyCRoiAxUk4eo/jcfqiuaPhrNeYrK3i8QcYI3LIv+zbVYq9Bw=="
private const val VECTOR_HEADER = "ed25519;$TEST_KEY_ID;$VECTOR_SIG_B64"

/**
 * The SPEC v1 §5.2 verification algorithm against the shared §2.3 test vector: the positive case,
 * every §12 negative (each must reject as "candidate failed", i.e. throw
 * [RelayListVerificationException]), the §4.2 advisory key_id routing, and the §11 pinned-key CI
 * guard over the production constants in [AppConfig.RELAY_SIGNING_PUBLIC_KEYS_HEX]. Plain JVM —
 * no sockets, no Robolectric; the wire-level path is covered by [BrokerClientSigningTest].
 */
class RelayListVerifierTest {

    private val json = Json { ignoreUnknownKeys = true }

    /** Fixed at the vector's server_time, well inside its 30-minute not_after window. */
    private val vectorClock = Clock.fixed(Instant.parse("2026-07-10T00:00:00Z"), ZoneOffset.UTC)
    private val verifier = RelayListVerifier(listOf(TEST_PUBKEY_HEX), vectorClock)

    /** Signs variant bodies under the TEST-ONLY seed for the dynamic negative cases. */
    private val signer = Ed25519Sign(Base64.getDecoder().decode(TEST_SEED_B64))

    private fun sign(body: String, keyId: String = TEST_KEY_ID): String =
        "ed25519;$keyId;" + Base64.getEncoder().encodeToString(signer.sign(body.toByteArray()))

    private fun assertRejected(
        body: ByteArray = VECTOR_BODY.toByteArray(),
        header: String? = VECTOR_HEADER,
        requestedLimit: Int = 1,
        verifier: RelayListVerifier = this.verifier,
    ): RelayListVerificationException {
        try {
            verifier.verifyAndDecode(body, header, requestedLimit, json)
        } catch (rejection: RelayListVerificationException) {
            // §5.2: the surfaced failure must say "unsigned/invalid relay list", never read as a
            // generic network error.
            assertTrue(
                "unexpected message: ${rejection.message}",
                rejection.message.orEmpty().startsWith("unsigned/invalid relay list"),
            )
            return rejection
        }
        fail("verification unexpectedly succeeded")
        throw AssertionError("unreachable")
    }

    @Test
    fun `shared vector verifies and decodes`() {
        val verified = verifier.verifyAndDecode(VECTOR_BODY.toByteArray(), VECTOR_HEADER, 1, json)
        assertEquals(TEST_KEY_ID, verified.keyIdUsed)
        assertEquals(1, verified.response.count)
        assertEquals("api", verified.response.channel)
        assertEquals(1, verified.response.limit)
        assertEquals("2026-07-10T00:30:00Z", verified.response.notAfter)
        // key_id derivation (§2.2): first 8 SHA-256 bytes of the raw pubkey, lowercase hex.
        assertEquals(TEST_KEY_ID, RelayListVerifier.keyId(RelayListVerifier.decodeHex(TEST_PUBKEY_HEX)))
    }

    @Test
    fun `pinned production keys match their committed rotation vectors`() {
        // §11 CI guard: each pinned constant must verify the vector produced at key-generation
        // time, so a truncated or typo'd pinned key fails CI here — not on promotion day. The
        // vectors are index-aligned with the ordered ≥2-key pin (active first, then standby).
        val rotationVectors = listOf(
            Triple(
                "openrung-signing-key-vector:active",
                "627405615601c589",
                "mELBVRsBe2+aeKYMniZ2F0HEV7n+8VcokBgailoLQW7JAleX6q8RQypVOO0y0p0+g/u89Uu+aaYpVfvpIAMRBQ==",
            ),
            Triple(
                "openrung-signing-key-vector:standby",
                "672f79aa99a573cd",
                "KyYhv/R46Wmi1M4y+KPT4CUz40mVXzwG3hYG5U22v7qpxri0pj4wYCgxqjrGmh2hlFNcx8gZpIBFO1PhD7xABw==",
            ),
        )
        assertEquals(rotationVectors.size, AppConfig.RELAY_SIGNING_PUBLIC_KEYS_HEX.size)
        rotationVectors.forEachIndexed { index, (message, expectedKeyId, signatureB64) ->
            val publicKey = RelayListVerifier.decodeHex(AppConfig.RELAY_SIGNING_PUBLIC_KEYS_HEX[index])
            assertEquals(expectedKeyId, RelayListVerifier.keyId(publicKey))
            // Throws GeneralSecurityException — failing the test — if the pinned key is wrong.
            Ed25519Verify(publicKey).verify(Base64.getDecoder().decode(signatureB64), message.toByteArray())
        }
    }

    @Test
    fun `flipped body byte is rejected`() {
        val tampered = VECTOR_BODY.toByteArray().also { it[10] = (it[10].toInt() xor 0x01).toByte() }
        assertRejected(body = tampered)
    }

    @Test
    fun `flipped signature byte is rejected`() {
        val signature = Base64.getDecoder().decode(VECTOR_SIG_B64)
            .also { it[3] = (it[3].toInt() xor 0x01).toByte() }
        assertRejected(header = "ed25519;$TEST_KEY_ID;" + Base64.getEncoder().encodeToString(signature))
    }

    @Test
    fun `signature under an unpinned key is rejected`() {
        // The production pin does not contain the TEST key, so the (valid) vector signature must
        // not verify — falling through every pinned key first (§4.2).
        val productionPinned = RelayListVerifier(AppConfig.RELAY_SIGNING_PUBLIC_KEYS_HEX, vectorClock)
        assertRejected(verifier = productionPinned)
    }

    @Test
    fun `missing header is rejected`() {
        val rejection = assertRejected(header = null)
        assertTrue(rejection.message.orEmpty().contains(RelayListVerifier.SIGNATURE_HEADER))
    }

    @Test
    fun `malformed headers are rejected`() {
        val malformed = listOf(
            "", // empty
            "ed25519;$TEST_KEY_ID", // truncated: two fields
            "$VECTOR_HEADER;extra", // four fields
            "rsa;$TEST_KEY_ID;$VECTOR_SIG_B64", // wrong algorithm string
            "ED25519;$TEST_KEY_ID;$VECTOR_SIG_B64", // the algorithm literal is exact (§2.1)
            "ed25519;$TEST_KEY_ID;%%%not-base64%%%", // undecodable signature
            "ed25519;$TEST_KEY_ID;" + Base64.getEncoder().encodeToString(ByteArray(63)), // short sig
        )
        malformed.forEach { header -> assertRejected(header = header) }
    }

    @Test
    fun `not_after is enforced with the 5-minute slow-clock allowance`() {
        // Vector not_after is 00:30:00Z; the §5.2 rule is not_after >= now - 5 min.
        val justInside = RelayListVerifier(
            listOf(TEST_PUBKEY_HEX),
            Clock.fixed(Instant.parse("2026-07-10T00:34:59Z"), ZoneOffset.UTC),
        )
        justInside.verifyAndDecode(VECTOR_BODY.toByteArray(), VECTOR_HEADER, 1, json)
        val justPast = RelayListVerifier(
            listOf(TEST_PUBKEY_HEX),
            Clock.fixed(Instant.parse("2026-07-10T00:35:01Z"), ZoneOffset.UTC),
        )
        val rejection = assertRejected(verifier = justPast)
        assertTrue(rejection.message.orEmpty().contains("expired"))
    }

    @Test
    fun `limit echo mismatch is rejected`() {
        // The vector body echoes limit=1; a client that asked for 5 must not accept it — this is
        // what turns a replayed same-URL variant into a verification failure (§2.2).
        assertRejected(requestedLimit = 5)
    }

    @Test
    fun `missing limit echo is rejected on the api channel`() {
        val body =
            """{"count":0,"server_time":"2026-07-10T00:00:00Z","not_after":"2026-07-10T00:30:00Z","key_id":"$TEST_KEY_ID","channel":"api","relays":[]}"""
        assertRejected(body = body.toByteArray(), header = sign(body))
    }

    @Test
    fun `channel mismatch is rejected`() {
        // A validly signed MIRROR artifact must never be accepted in an API-channel slot (§2.2).
        val body =
            """{"count":0,"server_time":"2026-07-10T00:00:00Z","not_after":"2026-07-10T00:30:00Z","key_id":"$TEST_KEY_ID","channel":"mirror","limit":1,"relays":[]}"""
        assertRejected(body = body.toByteArray(), header = sign(body))
    }

    @Test
    fun `unparseable not_after is rejected`() {
        val body =
            """{"count":0,"server_time":"2026-07-10T00:00:00Z","not_after":"soonish","key_id":"$TEST_KEY_ID","channel":"api","limit":1,"relays":[]}"""
        assertRejected(body = body.toByteArray(), header = sign(body))
    }

    @Test
    fun `signed body that is not a relay list is rejected`() {
        val body = """{"ok":true}"""
        assertRejected(body = body.toByteArray(), header = sign(body))
    }

    @Test
    fun `wrong advisory key_id still verifies via pinned-key fallback`() {
        // §4.2: key_id is routing only — a broker-side key_id bug must cost one wasted verify,
        // not an outage. The signature is valid under the pinned TEST key.
        val verified = verifier.verifyAndDecode(
            VECTOR_BODY.toByteArray(),
            sign(VECTOR_BODY, keyId = "ffffffffffffffff"),
            1,
            json,
        )
        assertEquals(TEST_KEY_ID, verified.keyIdUsed)
    }

    @Test
    fun `advisory routing works with multiple pinned keys`() {
        // Active production key pinned first, TEST key second: the advisory key_id routes to the
        // matching second slot and reports it as the key that verified.
        val multiKey = RelayListVerifier(
            listOf(AppConfig.RELAY_SIGNING_PUBLIC_KEYS_HEX.first(), TEST_PUBKEY_HEX),
            vectorClock,
        )
        val verified = multiKey.verifyAndDecode(VECTOR_BODY.toByteArray(), VECTOR_HEADER, 1, json)
        assertEquals(TEST_KEY_ID, verified.keyIdUsed)
    }

    @Test
    fun `signature header lookup is case-insensitive`() {
        // HTTP/2/3 lowercase header names on the wire (§2.1); HttpURLConnection also maps the
        // status line under a null key, which must be skipped, not crash the scan.
        val headers = mapOf<String?, List<String>>(
            null to listOf("HTTP/1.1 200 OK"),
            "content-type" to listOf("application/json"),
            "x-openrung-relays-signature" to listOf(VECTOR_HEADER),
        )
        assertEquals(VECTOR_HEADER, RelayListVerifier.signatureHeader(headers))
        assertNull(
            RelayListVerifier.signatureHeader(
                mapOf<String?, List<String>>("Content-Type" to listOf("application/json")),
            ),
        )
    }
}
