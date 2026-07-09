package com.openrung.config

object AppConfig {
    /**
     * Discovery broker (relay-list bootstrap) default, and — since discovery is HTTPS-only — the sole
     * built-in discovery candidate. Discovery is the censorship-critical path: it runs BEFORE the VPN
     * tunnel is up, and the relay list it returns defines which server the client trusts as its exit.
     * The relay list is NOT signed, so it must only be fetched over a TLS-authenticated channel; the
     * Cloudflare-fronted HTTPS endpoint (TLS + CDN edge IPs) is both hard to block and unforgeable.
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
     * Ordered discovery candidates, tried in order until one returns relays (see
     * [com.openrung.net.BrokerClient.firstReachable]). Every entry MUST be HTTPS: the relay list is
     * not yet signed, so it is authenticated only by the TLS cert of the serving host — a
     * cleartext/bare-IP entry would let an on-path censor inject a malicious relay set.
     *
     * Only one front is deployed today, so a censor who blocks it fails discovery CLOSED (offline).
     * Closing that single point of failure is the front-diversity layer: adding more *HTTPS* fronts on
     * independent CDNs/domains is safe now (still TLS-authenticated) and just needs the extra fronts
     * deployed. Non-TLS / out-of-band channels (raw IP, cached blobs) stay off this list until the
     * broker signs the relay list. Keep this in sync with the other clients' AppConfig.
     */
    val DEFAULT_BROKER_URLS: List<String> = listOf(
        DEFAULT_BROKER_URL,
        // Additional HTTPS fronts once deployed (second domain / second CDN), e.g.:
        //   "https://broker2.openrung.org/",
    )

    /**
     * Ordered discovery candidates for a connection attempt: the caller-selected [primary] (a user
     * override or the persisted choice) first, then the built-in [DEFAULT_BROKER_URLS], de-duplicated
     * while preserving order. The primary is never discarded, so a user's custom broker is always
     * tried first and the defaults only act as a fallback.
     */
    fun brokerCandidates(primary: String?): List<String> =
        com.openrung.net.BrokerClient.candidates(primary, DEFAULT_BROKER_URLS)

    const val RELAY_LIMIT = 5
    const val VPN_SESSION_NAME = "OpenRung Volunteer VPN"
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
