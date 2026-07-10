import { candidates, type BrokerCandidates } from './net/brokerClient';
// The app version string lives in exactly ONE place — package.json — and every other
// surface (Android versionName, iOS MARKETING_VERSION, this constant) derives from it so
// they cannot drift. scripts/check-versions.mjs enforces this in CI.
import { version } from '../package.json';

/**
 * App configuration, ported 1:1 from the production `config/AppConfig.kt`
 * (same constant names and values).
 */
export const AppConfig = {
  /**
   * Discovery broker (relay-list bootstrap) default. Discovery is the censorship-critical path: it
   * runs BEFORE the VPN tunnel is up, and the relay list it returns defines which server the client
   * trusts as its exit. The relay list is Ed25519-signed by the broker (SPEC v1) and verified
   * against RELAY_SIGNING_KEYS below, so its authenticity no longer depends on the transport; the
   * Cloudflare-fronted HTTPS endpoint remains the default because TLS + CDN edge IPs are also hard
   * to block.
   */
  DEFAULT_BROKER_URL: 'https://broker.openrung.org/',

  /**
   * Telemetry / heartbeat / speed-test target. Uses the same Cloudflare-fronted HTTPS broker as
   * discovery, so this traffic is TLS-protected — the app never sends anything in cleartext. Kept as
   * a separate constant from DEFAULT_BROKER_URL because telemetry is high-volume (heartbeats fire
   * ~once/minute per connected user), so it consumes the Cloudflare Worker free-tier request quota
   * (100k/day). If that quota becomes a constraint, the planned fix is to send telemetry
   * direct-to-origin over TLS via a dedicated unproxied hostname — "Option A" in
   * docs/ARCHITECTURE.md § "Network transport". Never revert to a raw-IP HTTP endpoint: that leaked
   * the user's real pre-VPN IP, geo and stable client ID in cleartext.
   */
  TELEMETRY_BROKER_URL: 'https://broker.openrung.org/',

  /**
   * Ordered discovery candidates, raced with a staggered start: the first entry starts
   * immediately, each later entry joins DISCOVERY_STAGGER_MS after the previous one, and the
   * first candidate to return relays wins (see `firstReachable` in `net/brokerClient.ts`).
   * Every candidate's relay list is verified against RELAY_SIGNING_KEYS (loopback dev hosts
   * excepted), so list authenticity no longer rests on the TLS cert of the serving host —
   * a forged or tampered response is simply a failed candidate.
   *
   * Two independent fronts are deployed — the Cloudflare Worker and an AWS CloudFront distribution
   * (different provider AND DNS zone) — so a single CDN/zone/account failure no longer fails
   * discovery CLOSED. Both proxy the one signing broker, so both serve verifiable lists. Now that
   * the list is signed, non-TLS channels (direct-IP fallback, static mirrors) become safe to ADD
   * here in a later step — signing defends integrity only, a censor can still block any individual
   * entry. Keep this in sync with the other clients' AppConfig.
   */
  DEFAULT_BROKER_URLS: [
    'https://broker.openrung.org/',
    // Independent second front: AWS CloudFront (different provider + DNS zone).
    'https://d2r7mdpyevvs1m.cloudfront.net/',
  ],

  /**
   * Ordered discovery candidates for a connection attempt: the caller-selected `primary` (a user
   * override or the persisted choice) first, then the built-in DEFAULT_BROKER_URLS, de-duplicated
   * while preserving order. A GENUINE override (a primary that is not one of the defaults) is
   * flagged `overrideFirst`: `firstReachable` tries it strictly first with its full per-attempt
   * timeout — a user's custom broker is never silently outrun by a default front merely for being
   * slower than the stagger — and the defaults race as fallbacks only after it fails. A primary
   * that echoes a default keeps the pure staggered race, where list position is just a head start
   * of DISCOVERY_STAGGER_MS per position.
   */
  brokerCandidates(primary: string | null | undefined): BrokerCandidates {
    return candidates(primary, AppConfig.DEFAULT_BROKER_URLS);
  },

  /**
   * Stagger interval of the discovery race (`firstReachable`): candidate N+1 is started this many
   * milliseconds after candidate N unless an attempt has already succeeded. Small enough that a
   * blocked/blackholed primary front only delays discovery by ~2.5 s per fallback position
   * (instead of a full 15 s request timeout), large enough that a healthy primary almost always
   * answers before the first fallback is ever contacted, keeping fallback-front load near zero.
   * MUST stay in sync with desktop `DiscoveryStagger` (Go config package) and the Kotlin/Swift
   * AppConfigs — the staggered-race semantics are identical across all four clients.
   */
  DISCOVERY_STAGGER_MS: 2_500,

  /**
   * Pinned Ed25519 public keys for relay-list signature verification (SPEC v1 §4.2), ordered
   * active first, offline standby second. `publicKeyHex` is the raw 32-byte key as lowercase hex;
   * `keyId` is lowercase hex of the first 8 bytes of SHA-256 over that raw key. The key_id in the
   * broker's signature header is advisory routing only — verification falls back to trying every
   * pinned key — so a keyId typo here costs one wasted verify, never an outage. MUST stay in sync
   * with the desktop Go client and the Kotlin/Swift AppConfigs, and with the `pinned_keys` block
   * of testdata/signing_vectors.json: the CI pinned-key guard (relaySigning.test.ts) verifies a
   * committed test vector against each constant so a truncated/typo'd key fails CI immediately
   * instead of being discovered on key-promotion day (SPEC v1 §11).
   */
  RELAY_SIGNING_KEYS: [
    {
      keyId: '627405615601c589', // active (online, on the broker)
      publicKeyHex: '176c03cbc70833285abcea75f2a0e137bd687629142408c22806a86308bd4974',
    },
    {
      keyId: '672f79aa99a573cd', // standby (offline, promotable per the rotation runbook)
      publicKeyHex: '5b2698cfa7a796c671a30aabd5475d55095b91464221f051837eb8fe01f36ea2',
    },
  ],

  RELAY_LIMIT: 5,
  VPN_SESSION_NAME: 'OpenRung Volunteer VPN',
  STATUS_PREFS: 'openrung_status',

  /**
   * Relay fetch used to populate the exit-node map directory (the connect path still uses
   * RELAY_LIMIT). This is the broker's maximum allowed page size — the broker rejects anything
   * larger with HTTP 400 — so it captures the full set of currently-advertised relays.
   */
  DIRECTORY_RELAY_LIMIT: 20,

  /** Most-recently connected locations kept for the main-screen "Recents" row. */
  MAX_RECENTS: 8,

  /**
   * Public source repository. Surfaced in the in-app open-source licenses screen and used as the
   * GPL-3.0 corresponding-source offer for the (GPL-licensed) app.
   */
  SOURCE_URL: 'https://github.com/openrung/openrung-mobile-app',

  /**
   * Vector tiles + glyphs for the exit-node map. We build our own flat style around these MapLibre
   * demo tiles rather than using the demo *style*, which colour-codes every country. An operator
   * can point these at a self-hosted source to avoid third-party tiles.
   */
  MAP_TILES_URL: 'https://demotiles.maplibre.org/tiles/tiles.json',
  MAP_GLYPHS_URL: 'https://demotiles.maplibre.org/font/{fontstack}/{range}.pbf',
} as const;

/** App version reported in X-OpenRung-App-Version (production uses BuildConfig.VERSION_NAME). */
export const APP_VERSION = version;
