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
   * Primary broker passed to the native brokerapi selector. Go owns the built-in candidates,
   * custom-override policy, staggered racing, relay verification, and transport selection.
   */
  DEFAULT_BROKER_URL: 'https://broker.openrung.org/',

  /**
   * Native brokerapi target for the React Native speed test and its small telemetry batch.
   * General VPN telemetry remains owned by the Android VPN service and iOS PacketTunnel.
   */
  TELEMETRY_BROKER_URL: 'https://broker.openrung.org/',

  RELAY_LIMIT: 5,
  VPN_SESSION_NAME: 'OpenRung VPN',
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

  /** Public policy covering app and network data handling. */
  PRIVACY_URL: 'https://www.openrung.org/privacy',

  /**
   * TestFlight public invite link for the iOS beta, shared from Settings → "Share OpenRung"
   * (the iOS counterpart of Android's offline APK sharing). Regenerate it in App Store Connect →
   * TestFlight → external group → Public Link if the group is ever recreated; the Settings row
   * hides itself whenever this is empty. Note RELEASE.md §5: external TestFlight distribution of
   * the GPL-linked binary has an unresolved licensing caveat.
   */
  TESTFLIGHT_URL: 'https://testflight.apple.com/join/RMTt4UfQ',

  /**
   * Vector tiles + glyphs for the exit-node map. We build our own flat style around these MapLibre
   * demo tiles rather than using the demo *style*, which colour-codes every country. An operator
   * can point these at a self-hosted source to avoid third-party tiles.
   */
  MAP_TILES_URL: 'https://demotiles.maplibre.org/tiles/tiles.json',
  MAP_GLYPHS_URL: 'https://demotiles.maplibre.org/font/{fontstack}/{range}.pbf',

  /**
   * Ordered candidates for the in-app update manifest (docs/UPDATE_MANIFEST.md), tried
   * sequentially with a per-attempt timeout, fail-open: all-fail just means "no update UI".
   * The direct broker and CloudFront candidates use native brokerapi. The GitHub release asset is
   * the narrow redirecting JavaScript-fetch exception and remains last because github.com is
   * unreliable in several target regions.
   * These URLs are a FOREVER CONTRACT with shipped clients: never repurpose or break them.
   */
  UPDATE_MANIFEST_URLS: [
    'https://broker.openrung.org/api/v1/app-manifest',
    'https://d2r7mdpyevvs1m.cloudfront.net/api/v1/app-manifest',
    'https://github.com/openrung/openrung-mobile-app/releases/latest/download/update-manifest.json',
  ],

  /**
   * Where the "Update" buttons send Android users. Deliberately a pinned constant — update
   * destinations NEVER come from the manifest, so even a validly-signed (let alone forged)
   * manifest cannot redirect users to a hostile download. iOS uses TESTFLIGHT_URL.
   */
  UPDATE_URL_ANDROID: 'https://github.com/openrung/openrung-mobile-app/releases/latest',

  /** Minimum interval between successful update-manifest checks (cold start + app foreground). */
  UPDATE_CHECK_INTERVAL_MS: 6 * 3_600_000,

  /** Minimum interval between retries after a failed check (in-memory, per app session). */
  UPDATE_CHECK_RETRY_MS: 15 * 60_000,

  /**
   * Pinned Ed25519 public keys for update-manifest signature verification. The manifest can
   * hard-block app startup, so its signing key is scoped to exactly that power and remains in
   * TypeScript even though relay verification moved into native brokerapi.
   * The client only ever hard-blocks ("Update required") on a manifest that verifies against one
   * of these keys; unsigned or unverifiable manifests are capped at the passive update row. MUST
   * stay in sync with the `pinned_keys` block of testdata/update_manifest_vectors.json (CI guard
   * in updateManifest.test.ts + scripts/update-manifest.mjs check). Rotation: keygen mode of
   * scripts/update-manifest.mjs, pin the new key here, ship a release, then swap the secret.
   */
  MANIFEST_SIGNING_KEYS: [
    {
      keyId: 'a71d7615b7af163b', // active (seed in GitHub secret OPENRUNG_MANIFEST_SIGNING_SEED_B64)
      publicKeyHex: '3443068d4cb27dd474dee11155c365a44df6a24c560b8ae2cb019487b555bfc7',
    },
  ],
} as const;

/** App version reported in X-OpenRung-App-Version (production uses BuildConfig.VERSION_NAME). */
export const APP_VERSION = version;
