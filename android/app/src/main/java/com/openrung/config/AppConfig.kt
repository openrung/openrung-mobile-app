package com.openrung.config

object AppConfig {
    /**
     * Discovery broker (relay-list bootstrap) default, and — since discovery is HTTPS-only — the sole
     * built-in discovery candidate. Discovery is the censorship-critical path: it runs BEFORE the VPN
     * tunnel is up, and the relay list it returns defines which server the client trusts as its exit.
     * The relay list is Ed25519-signed by the broker and verified against
     * [RELAY_SIGNING_PUBLIC_KEYS_HEX], so its authenticity no longer rests on the transport; the
     * Cloudflare-fronted HTTPS endpoint stays the default because it is hard to block and keeps the
     * client identity headers off the wire in cleartext.
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
     * Ordered discovery candidates, raced with a staggered start: the first entry starts
     * immediately, each later entry joins [DISCOVERY_STAGGER_MS] after the previous one, and the
     * first candidate to return relays wins (see [com.openrung.net.BrokerClient.firstReachable]).
     * Every response is Ed25519-verified against [RELAY_SIGNING_PUBLIC_KEYS_HEX] (see
     * [com.openrung.net.RelayListVerifier]), so a candidate's TLS cert is no longer what
     * authenticates the list — an entry that fails verification is simply a failed candidate.
     *
     * Two independent fronts are deployed — the Cloudflare Worker and an AWS CloudFront distribution
     * (different provider AND DNS zone) — so a single CDN/zone/account failure no longer fails
     * discovery CLOSED. Both proxy the one signing broker, so both serve verifiable lists. Non-TLS
     * channels (direct IP, signed mirrors) become safe to add in later phases now that the list is
     * signed. Entries stay HTTPS for now because the discovery request carries the client identity
     * headers, which must not travel in cleartext. Keep this in sync with the other clients' AppConfig.
     */
    val DEFAULT_BROKER_URLS: List<String> = listOf(
        DEFAULT_BROKER_URL,
        // Independent second front: AWS CloudFront (different provider + DNS zone).
        "https://d2r7mdpyevvs1m.cloudfront.net/",
    )

    /**
     * Ordered discovery candidates for a connection attempt: the caller-selected [primary] (a user
     * override or the persisted choice) first, then the built-in [DEFAULT_BROKER_URLS], de-duplicated
     * while preserving order. A GENUINE override (a primary that is not one of the defaults) is
     * flagged `overrideFirst`: `firstReachable` tries it strictly first with its full per-attempt
     * timeout — a user's custom broker is never silently outrun by a default front merely for being
     * slower than the stagger — and the defaults race as fallbacks only after it fails. A primary
     * that echoes a default keeps the pure staggered race, where list position is just a head start
     * of [DISCOVERY_STAGGER_MS] per position.
     */
    fun brokerCandidates(primary: String?): com.openrung.net.BrokerClient.Candidates =
        com.openrung.net.BrokerClient.candidates(primary, DEFAULT_BROKER_URLS)

    /**
     * Stagger interval of the discovery race ([com.openrung.net.BrokerClient.firstReachable]):
     * candidate N+1 is started this many milliseconds after candidate N unless an attempt has
     * already succeeded. Small enough that a blocked/blackholed primary front only delays discovery
     * by ~2.5 s per fallback position (instead of a full request timeout), large enough that a
     * healthy primary almost always answers before the first fallback is ever contacted, keeping
     * fallback-front load near zero. MUST stay in sync with desktop `DiscoveryStagger` (Go config
     * package) and the RN/Swift AppConfigs — the staggered-race semantics are identical across all
     * four clients.
     */
    const val DISCOVERY_STAGGER_MS = 2_500L

    /**
     * Ordered Ed25519 public keys (raw 32-byte keys as lowercase hex) trusted to sign the relay
     * list (SPEC v1 §4.2): the active broker key first, then the offline standby that a routine
     * rotation promotes. Signing detaches relay-list authenticity from the transport — a valid
     * signature from one of these keys, not the TLS cert of whichever front answered, is what
     * lets discovery trust a response (see [com.openrung.net.RelayListVerifier]). The `key_id`
     * in the signature header is advisory routing only: on mismatch every key here is tried, so
     * a broker-side key_id bug costs one wasted verify, not an outage. MUST stay in sync with
     * the desktop Go, RN and iOS pinned lists; the pinned-key CI guard in RelayListVerifierTest
     * verifies each entry against its committed rotation vector, so a truncated or typo'd
     * constant fails the build instead of being discovered on promotion day. A key may be
     * dropped only per the rotation runbook (broker no longer signs with it AND key_id
     * telemetry shows zero verifications under it).
     */
    val RELAY_SIGNING_PUBLIC_KEYS_HEX: List<String> = listOf(
        // Active broker signing key (key_id 627405615601c589).
        "176c03cbc70833285abcea75f2a0e137bd687629142408c22806a86308bd4974",
        // Offline standby, promoted on rotation or key loss (key_id 672f79aa99a573cd).
        "5b2698cfa7a796c671a30aabd5475d55095b91464221f051837eb8fe01f36ea2",
    )

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
