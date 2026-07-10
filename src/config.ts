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
   * Discovery broker (relay-list bootstrap) default, and — since discovery is HTTPS-only — the sole
   * built-in discovery candidate. Discovery is the censorship-critical path: it runs BEFORE the VPN
   * tunnel is up, and the relay list it returns defines which server the client trusts as its exit.
   * The relay list is NOT signed, so it must only be fetched over a TLS-authenticated channel; the
   * Cloudflare-fronted HTTPS endpoint (TLS + CDN edge IPs) is both hard to block and unforgeable.
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
   * Every entry MUST be HTTPS: the relay list is not yet signed, so it is
   * authenticated only by the TLS cert of the serving host — a cleartext/bare-IP entry would let an
   * on-path censor inject a malicious relay set.
   *
   * Only one front is deployed today, so a censor who blocks it fails discovery CLOSED (offline).
   * Closing that single point of failure is the front-diversity layer: adding more *HTTPS* fronts on
   * independent CDNs/domains is safe now (still TLS-authenticated) and just needs the extra fronts
   * deployed. Non-TLS / out-of-band channels (raw IP, cached blobs) stay off this list until the
   * broker signs the relay list. Keep this in sync with the other clients' AppConfig.
   */
  DEFAULT_BROKER_URLS: [
    'https://broker.openrung.org/',
    // Additional HTTPS fronts once deployed (second domain / second CDN), e.g.:
    //   'https://broker2.openrung.org/',
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
