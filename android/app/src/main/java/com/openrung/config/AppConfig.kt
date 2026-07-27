package com.openrung.config

object AppConfig {
    /**
     * Primary relay-discovery URL passed to brokerapi. The native Go client owns built-in
     * candidates, override policy, racing, relay verification, and transport selection; Kotlin
     * receives only the winning URL and a verified relay-list snapshot.
     */
    const val DEFAULT_BROKER_URL = "https://broker.openrung.org/"

    /**
     * Telemetry / heartbeat / speed-test target. Uses the same Cloudflare-fronted HTTPS broker as
     * discovery, so this traffic is TLS-protected — the app never sends anything in cleartext. Kept as
     * a separate constant from [DEFAULT_BROKER_URL] because telemetry is high-volume (heartbeats fire
     * ~once/minute per connected user), so it consumes the Cloudflare Worker free-tier request quota
     * (100k/day). If that quota becomes a constraint, the planned fix is to send telemetry
     * direct-to-origin over TLS via a dedicated unproxied hostname — "Option A" in
     * docs/ARCHITECTURE.md § "Network transport". Never revert to a raw-IP HTTP endpoint: that leaked
     * the user's real pre-VPN IP, geo and stable client ID in cleartext.
     */
    const val TELEMETRY_BROKER_URL = "https://broker.openrung.org/"

    /**
     * Stable broker-front order retained for native WSS-ticket failover. Native relay discovery
     * passes only the configured primary to brokerapi; Go owns its default candidates, override
     * detection, racing, URL policy, ECH transport selection, and relay verification.
     */
    val DEFAULT_BROKER_URLS: List<String> = listOf(
        DEFAULT_BROKER_URL,
        // Independent second front: AWS CloudFront (different provider + DNS zone).
        "https://d2r7mdpyevvs1m.cloudfront.net/",
    )

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

    const val RELAY_LIMIT = 5
    const val VPN_SESSION_NAME = "OpenRung VPN"
    const val STATUS_PREFS = "openrung_status"

    /**
     * Relay fetch used to populate the exit-node map directory (the connect path still uses
     * [RELAY_LIMIT]). This is the broker's maximum allowed page size — the broker rejects anything
     * larger with HTTP 400 — so it captures the full set of currently-advertised relays.
     */
    const val DIRECTORY_RELAY_LIMIT = 20

    /** Most-recently connected locations kept for the main-screen "Recents" row. */
    const val MAX_RECENTS = 8

    /**
     * Public source repository. Surfaced in the in-app open-source licenses screen and used as the
     * GPL-3.0 corresponding-source offer for the (GPL-licensed) app.
     */
    const val SOURCE_URL = "https://github.com/openrung/openrung"

    /**
     * Vector tiles + glyphs for the exit-node map. We build our own flat style (blue ocean / grey
     * land) around these MapLibre demo tiles rather than using the demo *style*, which colour-codes
     * every country. An operator can point these at a self-hosted source to avoid third-party tiles.
     */
    const val MAP_TILES_URL = "https://demotiles.maplibre.org/tiles/tiles.json"
    const val MAP_GLYPHS_URL = "https://demotiles.maplibre.org/font/{fontstack}/{range}.pbf"
}
