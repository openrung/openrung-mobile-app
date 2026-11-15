package com.openrung.config

object AppConfig {
    /**
     * Primary relay-discovery URL passed to brokerapi. The native Go client owns built-in
     * candidates, override policy, racing, relay verification, and transport selection; Kotlin
     * receives only the winning URL and a verified relay-list snapshot.
     */
    const val DEFAULT_BROKER_URL = "https://broker.openrung.org/"

    /**
     * SHA-256 pins for self-signed punch-coordinator leaf certificates, keyed by the exact host in
     * the signed relay descriptor. A bare-IP coordinator is accepted only when it appears here;
     * hostname coordinators not listed here use Android/Go's normal public CA validation. The pin
     * authenticates the response that supplies UDP targets, the punch token, and the ephemeral QUIC
     * certificate fingerprint. It is deliberately scoped to the embedded punch HTTP transport.
     *
     * Rotation: deploy a second certificate/endpoint and app pin before switching descriptors. This
     * certificate is valid through 2036-06-29 and covers both current RelayHub IPv4 addresses.
     */
    val PUNCH_COORDINATOR_CERT_SHA256_BY_HOST: Map<String, String> = mapOf(
        "43.201.124.63" to "70c3a26b9ac7315d1975f417eb9eabbecc98ec0e2d5baadb6c224e87fd99c8b5",
        "43.201.172.102" to "70c3a26b9ac7315d1975f417eb9eabbecc98ec0e2d5baadb6c224e87fd99c8b5",
    )

    const val STATUS_PREFS = "openrung_status"

    /** Most-recently connected locations kept for the main-screen "Recents" row. */
    const val MAX_RECENTS = 8
}
