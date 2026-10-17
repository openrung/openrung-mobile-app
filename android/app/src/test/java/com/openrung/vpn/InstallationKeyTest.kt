package com.openrung.vpn

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.security.spec.X509EncodedKeySpec

/**
 * The Kotlin half of testdata/installation-key-vectors.json: the Go suite proves the raw signatures
 * and SPKI there verify with brokerapi exactly as the broker checks them; this suite proves the
 * Keystore-format conversions land on those bytes. The Keystore itself is not available on the
 * JVM, so the round trip uses a software P-256 key through the same JCA calls.
 */
class InstallationKeyTest {
    private val vectors: JsonObject = Json.parseToJsonElement(
        File(
            requireNotNull(System.getProperty("openrung.contractVectors")) {
                "openrung.contractVectors is unset; the Gradle unit-test task should supply it"
            },
        ).parentFile.resolve("installation-key-vectors.json").readText(),
    ).jsonObject

    private fun JsonObject.hex(key: String): ByteArray =
        this[key]!!.jsonPrimitive.content.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    @Test
    fun `DER signatures convert to the vectors' raw r and s`() {
        val cases = vectors["signatures"]!!.jsonArray.map { it.jsonObject }
        assertTrue(cases.size >= 4)
        cases.forEach { case ->
            val name = case["name"]!!.jsonPrimitive.content
            assertArrayEquals(name, case.hex("raw_signature_hex"), EcdsaP256.rawSignature(case.hex("der_signature_hex")))
        }
    }

    @Test
    fun `malformed DER signatures are rejected`() {
        val cases = vectors["invalid_der"]!!.jsonArray.map { it.jsonObject }
        assertTrue(cases.size >= 4)
        cases.forEach { case ->
            assertThrows(case["name"]!!.jsonPrimitive.content, IllegalArgumentException::class.java) {
                EcdsaP256.rawSignature(case.hex("der_hex"))
            }
        }
    }

    @Test
    fun `public key encodes as the P-256 SubjectPublicKeyInfo`() {
        val spki = vectors.hex("spki_der_hex")
        val key = KeyFactory.getInstance("EC").generatePublic(X509EncodedKeySpec(spki))
        assertArrayEquals(spki, EcdsaP256.subjectPublicKeyInfo(key))
        val rsa = KeyPairGenerator.getInstance("RSA").apply { initialize(1024) }.generateKeyPair().public
        assertThrows(IllegalStateException::class.java) { EcdsaP256.subjectPublicKeyInfo(rsa) }
    }

    @Test
    fun `native signatures verify as raw r and s over the given digest`() {
        val pair = softwareKey()
        val key = InstallationKey { pair }
        val digest = MessageDigest.getInstance("SHA-256").digest("openrung-user-auth-v1".toByteArray())
        val raw = key.sign(digest)
        assertEquals(64, raw.size)
        // P1363 is exactly r‖s; NONE means the digest is not hashed again.
        val verifier = Signature.getInstance("NONEwithECDSAinP1363Format").apply {
            initVerify(KeyFactory.getInstance("EC").generatePublic(X509EncodedKeySpec(key.publicKey())))
            update(digest)
        }
        assertTrue(verifier.verify(raw))
        assertThrows(IllegalArgumentException::class.java) { key.sign(ByteArray(31)) }
    }

    @Test
    fun `key loads once and a failed load is retried`() {
        val pair = softwareKey()
        var calls = 0
        val key = InstallationKey {
            calls++
            if (calls == 1) throw IllegalStateException("keystore locked") else pair
        }
        assertThrows(IllegalStateException::class.java) { key.publicKey() }
        val first = key.publicKey()
        key.sign(ByteArray(32))
        assertArrayEquals(first, key.publicKey())
        assertEquals(2, calls)
    }

    private fun softwareKey(): KeyPair = KeyPairGenerator.getInstance("EC")
        .apply { initialize(ECGenParameterSpec("secp256r1")) }
        .generateKeyPair()
}
