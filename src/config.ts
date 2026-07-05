import { candidates } from './net/brokerClient';

/**
 * App configuration, ported 1:1 from the production `config/AppConfig.kt`
 * (same constant names and values).
 */
export const AppConfig = {
  /**
   * Discovery broker (relay-list bootstrap) default. Prefer the HTTPS, Cloudflare-fronted endpoint:
   * discovery is the censorship-critical path — it runs BEFORE the VPN tunnel is up — and TLS + CDN
   * edge IPs make it costly to block. Falls back to the raw origin IP; see DEFAULT_BROKER_URLS.
   */
  DEFAULT_BROKER_URL: 'https://broker.openrung.org/',

  /**
   * Telemetry / heartbeat / speed-test target: the raw origin IP, NOT the Cloudflare-fronted
   * hostname. Heartbeats fire ~once/minute per connected user; routing them through the Cloudflare
   * Worker would burn the Workers free-tier quota (100k requests/day). They ride the established VPN
   * tunnel so they don't need the CDN front (and it's the same broker either way). Discovery stays
   * fronted (low volume, pre-tunnel, needs the resilience); telemetry goes direct (high volume).
   */
  TELEMETRY_BROKER_URL: 'http://54.238.185.205:8080/',

  /**
   * Ordered discovery candidates, tried in order until one returns relays (see
   * `firstReachable` in `net/brokerClient.ts`): the Cloudflare-fronted endpoint first, then the
   * raw IP as a fallback so a blocked edge never takes discovery offline. The raw cleartext IP is
   * why cleartext HTTP stays allowed in both native app configs.
   */
  DEFAULT_BROKER_URLS: ['https://broker.openrung.org/', 'http://54.238.185.205:8080/'],

  /**
   * Ordered discovery candidates for a connection attempt: the caller-selected `primary` (a user
   * override or the persisted choice) first, then the built-in DEFAULT_BROKER_URLS, de-duplicated
   * while preserving order. The primary is never discarded, so a user's custom broker is always
   * tried first and the defaults only act as a fallback.
   */
  brokerCandidates(primary: string | null | undefined): string[] {
    return candidates(primary, AppConfig.DEFAULT_BROKER_URLS);
  },

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

  /**
   * Exit IP info endpoint for the Settings "Exit IP check". Third-party: the request necessarily
   * reveals the exit IP (that is its purpose) plus a request fingerprint to the endpoint, so the
   * UI only ever calls it on an explicit user tap AND only while connected — running it
   * disconnected would hand the user's REAL IP to the third party. Operators can point this at a
   * self-hosted echo endpoint (e.g. on the broker) to keep the check first-party.
   */
  EXIT_IP_INFO_URL: 'https://ipinfo.io/json',

  /**
   * Upload speed-test target. The broker has no upload endpoint yet, so this uses Cloudflare's
   * anonymous speed-test sink (the body is discarded). Candidate to move to
   * `{broker}/api/v1/speed-test` (upload variant) later so all measurement traffic stays
   * first-party like the download test.
   */
  SPEEDTEST_UPLOAD_URL: 'https://speed.cloudflare.com/__up',

  /**
   * Curated diagnostic links for the Settings "Network toolbox" section. All third-party sites
   * opened in the system browser (outside the app) on explicit tap; ids map to i18n titles.
   */
  TOOLBOX_LINKS: [
    { id: 'ipCheck', url: 'https://ipleak.net' },
    { id: 'dnsLeak', url: 'https://dnsleaktest.com' },
    { id: 'webrtcLeak', url: 'https://browserleaks.com/webrtc' },
    { id: 'speedTest', url: 'https://speed.cloudflare.com' },
  ] as ReadonlyArray<{ id: 'ipCheck' | 'dnsLeak' | 'webrtcLeak' | 'speedTest'; url: string }>,

  /** Latency probe tuning (exit-location "TEST LATENCY" + connect-to-fastest). */
  LATENCY_PROBE_TIMEOUT_MS: 3_000,
  LATENCY_PROBES_PER_REGION: 2,
  /** Probe results older than this are treated as stale and hidden. */
  LATENCY_RESULT_TTL_MS: 5 * 60_000,
} as const;

/** App version reported in X-OpenRung-App-Version (production uses BuildConfig.VERSION_NAME). */
export const APP_VERSION = '0.2.1';
