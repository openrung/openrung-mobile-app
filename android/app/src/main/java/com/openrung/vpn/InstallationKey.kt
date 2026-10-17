package com.openrung.vpn

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.PublicKey
import java.security.Signature
import java.security.spec.ECGenParameterSpec

/**
 * The installation's ADR-006 identity key: one P-256 key in the Android Keystore, generated on
 * first use, never exportable, and kept across app upgrades (it goes with the app's data; there is
 * no recovery, so a new key means a new enrollment). The broker derives the user ID from it; it is
 * unrelated to the telemetry install ID ([com.openrung.telemetry.ClientIdentity]).
 *
 * Methods run on Go workers, possibly concurrently. Failures are thrown and reach connectcore as
 * errors, which logs the reason and keeps the session on the public relay list.
 */
internal class InstallationKey(private val source: () -> KeyPair) {
    @Volatile private var cached: KeyPair? = null

    private fun keyPair(): KeyPair =
        cached ?: synchronized(this) { cached ?: source().also { cached = it } }

    /** DER SubjectPublicKeyInfo of the P-256 public key. */
    fun publicKey(): ByteArray = EcdsaP256.subjectPublicKeyInfo(keyPair().public)

    /** Raw 64-byte r‖s signature over [digest], which is already a SHA-256 digest. */
    fun sign(digest: ByteArray): ByteArray {
        require(digest.size == EcdsaP256.DIGEST_BYTES) { "digest must be ${EcdsaP256.DIGEST_BYTES} bytes" }
        // NONEwithECDSA signs the digest as given; the Keystore returns ASN.1 DER.
        val der = Signature.getInstance("NONEwithECDSA").run {
            initSign(keyPair().private)
            update(digest)
            sign()
        }
        return EcdsaP256.rawSignature(der)
    }

    companion object {
        private const val KEYSTORE = "AndroidKeyStore"
        // Versioned so a future key policy can live beside this one instead of replacing it.
        private const val ALIAS = "openrung_installation_key_v1"

        fun androidKeystore(): InstallationKey = InstallationKey(::loadOrCreate)

        private fun loadOrCreate(): KeyPair {
            val store = KeyStore.getInstance(KEYSTORE).apply { load(null) }
            // Only a missing key is created; any other failure throws, because replacing an
            // existing key would silently make this installation a new user.
            val private = store.getKey(ALIAS, null) as? PrivateKey
            if (private != null) {
                val public = store.getCertificate(ALIAS)?.publicKey
                    ?: throw IllegalStateException("installation key has no public key")
                return KeyPair(public, private)
            }
            val generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, KEYSTORE)
            generator.initialize(
                KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN)
                    .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                    .setDigests(KeyProperties.DIGEST_NONE)
                    .build(),
            )
            return generator.generateKeyPair()
        }
    }
}

/** P-256 encodings between JCA/Keystore output and what the Go binding expects. */
internal object EcdsaP256 {
    const val DIGEST_BYTES = 32
    private const val COORDINATE_BYTES = 32

    // SEQUENCE { SEQUENCE { id-ecPublicKey, prime256v1 }, BIT STRING (0 unused bits) }
    private val SPKI_PREFIX = byteArrayOf(
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86.toByte(), 0x48, 0xce.toByte(), 0x3d, 0x02,
        0x01, 0x06, 0x08, 0x2a, 0x86.toByte(), 0x48, 0xce.toByte(), 0x3d, 0x03, 0x01, 0x07, 0x03,
        0x42, 0x00,
    )
    private const val SPKI_BYTES = 91 // prefix + 0x04 ‖ X ‖ Y

    /** The key's X.509 encoding, checked to be an uncompressed P-256 SubjectPublicKeyInfo. */
    fun subjectPublicKeyInfo(key: PublicKey): ByteArray {
        val encoded = key.encoded ?: throw IllegalStateException("public key has no encoding")
        if (key.format != "X.509" || encoded.size != SPKI_BYTES ||
            !encoded.copyOfRange(0, SPKI_PREFIX.size).contentEquals(SPKI_PREFIX) ||
            encoded[SPKI_PREFIX.size] != 0x04.toByte()
        ) {
            throw IllegalStateException("public key is not an uncompressed P-256 key")
        }
        return encoded
    }

    /**
     * Converts an ASN.1 DER ECDSA signature (SEQUENCE of two positive INTEGERs) to the fixed-width
     * r‖s form, left-padding each half to 32 bytes. Rejects anything that is not exactly one
     * well-formed P-256 signature.
     */
    fun rawSignature(der: ByteArray): ByteArray {
        var offset = 0
        fun invalid(): Nothing = throw IllegalArgumentException("malformed ECDSA signature")
        fun next(): Int = if (offset < der.size) der[offset++].toInt() and 0xff else invalid()
        // A P-256 signature is at most 72 bytes, so every length is short-form.
        fun length(): Int = next().also { if (it >= 0x80) invalid() }
        fun integer(): ByteArray {
            if (next() != 0x02) invalid()
            val size = length()
            if (size == 0 || offset + size > der.size) invalid()
            val value = der.copyOfRange(offset, offset + size)
            offset += size
            if (value[0] < 0) invalid() // negative
            val start = value.indexOfFirst { it != 0.toByte() }
            if (start < 0 || value.size - start > COORDINATE_BYTES) invalid()
            return ByteArray(COORDINATE_BYTES - (value.size - start)) + value.copyOfRange(start, value.size)
        }
        if (next() != 0x30) invalid()
        val sequence = length()
        if (offset + sequence != der.size) invalid()
        val raw = integer() + integer()
        if (offset != der.size) invalid()
        return raw
    }
}
