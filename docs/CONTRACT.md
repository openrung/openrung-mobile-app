# OpenRung RN prototype — architecture contract

This document is the binding contract between the TypeScript shell and the two
native implementations. Every implementer follows it exactly; deviations must be
recorded here.

Reference implementation: the OpenRung repository (the production Android app in
`android/`, the production iOS app in `ios/`). This prototype models its UI and
functionality 1:1 unless noted.

## 1. Division of responsibility

**Native (Kotlin service / Swift NEPacketTunnelProvider extension)** owns the whole
connect path, exactly as in the production apps:
broker relay fetch (connect path), relay selection, TCP reachability, sing-box
(libbox) engine lifecycle, native NAT punching, TUN + DNS config, internet probe, connection-failure
handling, heartbeat telemetry, VPN permission + background lifecycle, recents
recording, status/log persistence.

**TypeScript (RN shell)** owns everything the production *app processes* own:
all UI, navigation, exit-node map directory modeling (grouped by broker-served
relay locations — relay IPs are never geolocated client-side), speed-test UI
and telemetry event construction, update-manifest verification/selection,
language selection, and licenses screens. Eligible broker networking for those
features is performed by the separate native `OpenRungBroker` module.

**Availability over "never leak."** OpenRung is availability-first: keeping the
user reachable matters more than guaranteeing no traffic ever leaves the tunnel.
The only leak protection is sing-box `strict_route` *while the tunnel is up*
(`SingBoxConfiguration`). There is deliberately **no OS-level kill switch** (no
`includeAllNetworks` / on-demand enforcement), so when the tunnel is down — no
relay reachable, a service/extension crash, or between sessions — traffic falls
back to the normal network rather than being blocked. "Connection-failure
handling" above and "report failure if no relay works" elsewhere therefore mean
the connect attempt *reports failure without leaving a half-open or leaky tunnel* —
NOT that the OS blocks traffic while the VPN is down.

Split tunneling (§3 `setSplitTunnelConfig`, §6/§7) obeys the same principle:
a missing or invalid split-tunnel config, or a missing bundled rule-set file,
degrades toward the tunnel — full-tunnel behavior plus a log line — and never
blocks traffic or fails a connect.

## 2. Identifiers

| Thing | Value |
|---|---|
| Android applicationId | `com.openrung.mobile` |
| Android namespace / Kotlin root package | `com.openrung` |
| Android minSdk / compile / target | 26 / 36 / 36 (minSdk raised from RN default 24) |
| iOS app bundle id | `com.openrung.app` |
| iOS extension bundle id | `com.openrung.app.PacketTunnel` |
| iOS app group | `group.com.openrung.app` |
| iOS VPN profile localizedDescription | `OpenRung VPN` |
| iOS deployment target | 16.0 |
| DEVELOPMENT_TEAM | `9VLV9A7KS9` |
| Darwin notification (ext→app) | `com.openrung.app.state-changed` |

The production identifiers (`com.openrung.client`, `group.com.openrung.client`,
`com.openrung.client.state-changed`) are NOT reused so both apps install
side-by-side.

## 3. Native bridge contract (both platforms, identical)

Module name: **`OpenRungVpn`** (classic NativeModule + event emitter; the RN 0.86
bridgeless interop layer handles both).

```ts
// src/native/types.ts — the single source of truth for these types
export type ConnectionStatus =
  | 'disconnected' | 'preparing' | 'connecting'
  | 'connected' | 'disconnecting' | 'failed';

export interface RecentNode {
  countryCode: string;   // ISO 3166-1 alpha-2, uppercase
  relayId?: string;      // exact broker relay id; absent on legacy entries
  label: string;         // "City, Country" or country name
  relayName?: string;    // sanitized relay display name (see NativeVpnState); absent on legacy entries
  latitude: number;
  longitude: number;
}

export interface NativeVpnState {
  status: ConnectionStatus;
  relayLabel: string | null;   // resolved geo label, never a raw IP
  relayName: string | null;    // connected relay's display name: native sanitizes the
                               // operator-supplied label (control/bidi-format characters
                               // stripped, whitespace collapsed, clamped to 24 code points) and
                               // falls back to the id, `relay_` prefix dropped, <=12 code points
  relayClass: 'foundation' | 'volunteer' | null;
                               // connected relay's node class: native normalizes the signed
                               // descriptor's node_class (anything but "foundation" collapses
                               // to "volunteer") and clears it to null whenever the tunnel is
                               // not CONNECTED — the exact relayName lifecycle, including
                               // persistence: Android never writes it to the status store's
                               // SharedPreferences and hard-resets it on initialize(); iOS
                               // carries it inside the app-group ConnectionStateSnapshot (the
                               // cross-process transport). The iOS app's launch view is
                               // sanitized (class dropped, like relayName), then as soon as
                               // the VPN manager loads, refreshVPNStatus() re-reads the
                               // persisted snapshot and the OS tunnel status arbitrates: a
                               // still-live tunnel restores the stored class immediately (no
                               // new extension write needed), while a down/invalid tunnel has
                               // the stale identity cleared by the stale-down guard — so a
                               // dead tunnel's class is never shown.
  lastError: string | null;
  logLines: string[];          // "[HH:mm:ss] message", newest last, cap 80
  recents: RecentNode[];       // newest first, deduped by relayId, cap 8
}

export interface NativeIdentity {
  clientId: string;            // stable install UUID (native-persisted)
  sessionId: string | null;    // active telemetry session id, null when idle
}

export interface OpenRungVpnModule {
  /** Ask for OS VPN consent (Android: VpnService.prepare dialog; also requests
   *  POST_NOTIFICATIONS on API 33+. iOS: load-or-create the
   *  NETunnelProviderManager and save it). Resolves true when usable. */
  prepare(): Promise<boolean>;
  /** Start (or switch) the tunnel. targetCountry: ISO alpha-2 or null = broker
   *  picks. Resolves once the native start has been dispatched (NOT when
   *  connected — completion is reported via events). */
  connect(brokerUrl: string, targetCountry: string | null): Promise<void>;
  disconnect(): Promise<void>;
  getState(): Promise<NativeVpnState>;
  getIdentity(): Promise<NativeIdentity>;
  /** Persist the split-tunnel config JSON (schema below) natively. If the
   *  tunnel is CONNECTED AND the *effective* config changed (the emitted
   *  sing-box config would differ), native reapplies by reconnecting to the
   *  same target. Resolves after persistence + reapply dispatch (NOT
   *  completion). */
  setSplitTunnelConfig(configJson: string): Promise<void>;
}
```

The module has **six** methods (split tunneling raised the count from five).

### Dedicated broker module

Module name: **`OpenRungBroker`** (separate classic NativeModule; never add
these methods to `OpenRungVpn`):

```ts
firstReachable(requestId, primary, limit, clientId, sessionId): Promise<RelaySnapshot>
runSpeedTest(requestId, brokerUrl): Promise<SpeedSnapshot>
sendTelemetryBatchJSON(requestId, brokerUrl, batchJson): Promise<void>
fetchManifestCandidate(requestId, candidateUrl): Promise<ManifestSnapshot>
cancel(requestId): Promise<boolean>
```

Each request ID owns a new single-use gomobile operation. Android constructs it
with `NewOpenRungBrokerOperationForReactNative(appVersion, "android")`; iOS
uses the same constructor with `"ios"`. The VPN service and PacketTunnel keep
their platform constructors. A thread-safe registry rejects duplicate active
IDs, cancellation cancels the Kotlin coroutine or Swift task so the shared
runner calls `Close`, and invalidation/deinitialization cancels every
outstanding request. Generated objects never cross the generated adapters:
plain value snapshots are copied before close.

Failures carry a bounded structured kind (`cancelled`, `timeout`,
`rate_limited`, `http_status`, `dns`, `tls`, `network`, `verification`,
`validation`, `unknown`, plus local `unavailable`/`decode`), optional HTTP
status, and optional retry-after milliseconds. Policy never parses diagnostic
messages. A stale or absent module rejects `unavailable` and requires a native
rebuild; there is no JavaScript broker-network fallback. No ticket request,
ticket, or WSS URL is exposed to React Native. For directory discovery, each
platform removes the VPN-only `wss_fronts` member from the verified relay
envelope before returning `relayJson`; TypeScript still decodes the remaining
directory payload into its existing data model. `signatureVerified` is an
enforced invariant, not advisory metadata: brokerapi reports false only for its
loopback development short-circuit, and `brokerClient.firstReachable` rejects an
unverified snapshot with kind `verification` rather than decoding it. Relay
verification moving into Go must not leave the shell indifferent to it.

`setSplitTunnelConfig` payload — the shared split-tunnel config JSON. TS
serializes with exactly this key order (snake_case): `version`, `enabled`,
`bypass_lan`, `bypass_countries`, `country_source`, `excluded_packages`.

```json
{"version":1,"enabled":true,"bypass_lan":true,"bypass_countries":["cn"],"country_source":"auto","excluded_packages":["com.tencent.mm"]}
```

- `version` is currently 1; parsers accept any object with `version >= 1` and
  ignore unknown fields.
- `bypass_countries`: lowercase ISO codes. v1 recognizes only `"ir"` and
  `"cn"`; unknown codes are ignored (forward compatibility). The two are
  **mutually exclusive** and RN sends at most one: the presets say where the
  device is, and no device is in two countries at once, so enabling both only
  adds a country's worth of domains to the direct path where they cannot help.
  The split-tunneling screen enforces it (switching one on switches the other
  off) and hydration collapses any pair it finds. The field stays a list and
  native parsers stay tolerant of several, so this is a product invariant, not
  a wire-format change.
- `country_source`: `"auto"` when RN derived `bypass_countries` from the device
  region, `"manual"` when the user chose them. Absent means `"manual"`, so an
  older RN layer behaves exactly as before. This is **provenance, not a
  preference**, and it is load-bearing: on an `"auto"` config each native
  generator IGNORES the stored `bypass_countries` and re-derives from its own
  `TimeZone` at the moment it builds a config. `bypass_countries` remains a
  snapshot of wherever the device was when JS last ran, kept for older native
  binaries and as a fallback.

  The reason is that both services rebuild sing-box configs on their own —
  every connect attempt AND every recovery reconnect after a physical-network
  change — while the app may not have been opened for weeks. Trusting the
  snapshot would let a phone that auto-selected China in Shanghai have its
  tunnel rebuilt with `geosite-cn` bypassed in Berlin, before the user ever
  opens OpenRung, and would leave the RN foreground re-check racing an
  already-started recovery (which deliberately skips reapply while connecting).
  Native re-deriving at construction time removes both.
- `excluded_packages`: Android package names excluded from the VPN at the OS
  level. iOS parses and ignores the field.
- **Split-tunnel routing selections are session-scoped.** The master switch, LAN
  bypass and country presets are never persisted: every launch starts from the
  product default — `enabled:true`, `bypass_lan:true`, and the country preset for
  the region the device is actually in (`["ir"]` in Iran, `["cn"]` in mainland
  China, `[]` everywhere else) — and a user's changes to them last only as long
  as the JS process. `initializeSplitTunnel` deletes the `openrung.splitTunnel`
  key older builds wrote, which held the whole slice.
- **`excluded_packages` is the exception and IS remembered**, under its own RN key
  `openrung.splitTunnel.excludedApps` (a JSON string array). Picking apps out of
  everything installed is real work, and an app bypass is a lasting statement
  about that app ("my bank refuses the VPN") rather than a temporary routing
  tweak. Initialization reads it back before the launch push, so native receives
  ONE config carrying both this launch's routing default and the remembered
  packages. A local edit that lands while that read is in flight wins.
  The split-tunneling screen states both halves of this in its footer, and says
  so only on builds that have an APPS section (Android).
- Native still persists the raw JSON (§6/§7) because the VPN service reads its
  own store on every connect, including background recovery rebuilds. That store
  therefore holds the CURRENT session's config, and each app launch overwrites it
  with that launch's routing default plus the remembered packages. A live tunnel whose config differed from the
  default reapplies (a brief reconnect) shortly after launch — the intended
  consequence of session-scoped settings, not a bug.
- The region comes from the device's IANA time zone ONLY — offline, no geo-IP
  call, no location permission, and deliberately no locale fallback: a language
  preference is not evidence of physical location, so a zone that carries none
  yields no preset rather than a guess. A country preset must never ship on
  outside its country: `geosite-cn` carries hosts the whole world loads
  (doubleclick.net, fonts.googleapis.com, www.gstatic.com …), so bypassing it
  elsewhere hands the user's real IP to those on ordinary page loads while the
  app reports CONNECTED.
- Within a session, an automatic selection keeps following the device: RN
  re-derives it on every app foreground and immediately before every connect
  (`refreshSplitTunnelRegion`) when the region it was derived from no longer
  matches, because the JS process routinely outlives a flight. A selection the
  user made by hand is never re-derived for the rest of that session; only a
  `bypass_countries` edit forfeits tracking, since toggling LAN or apps says
  nothing about which country's rule set belongs there. RN is not the last line
  of defence either — `country_source` (above) lets each native generator
  re-derive independently, which is what covers a background recovery rebuild
  that no JS code takes part in.
- Parse failure, an absent config, or `enabled:false` ⇒ "no split tunneling":
  the generated sing-box config is byte-identical to the no-split output
  (fail-open, §1).
- Both platforms persist the raw JSON string on every push, but reapply only
  when the *effective* config changes — the signature that determines the
  emitted sing-box config (Android: `enabled`, `bypass_lan`, recognized
  countries — RESOLVED through `country_source`, so an automatic selection is
  compared as the countries it currently derives to — and excluded packages; iOS
  ignores `excluded_packages`). Both sides of a comparison resolve against one
  region read, so a zone change landing mid-comparison cannot masquerade as a
  config change. Two payloads
  that both resolve to disabled, or to the same rule set, do not reconnect. So
  a redundant push (RN rehydration after a restore), the first persistence of
  any disabled config, or a change that nets to the same routing is a
  no-op — a live tunnel is never bounced for a no-op change (§1).
- Reapply targets a **CONNECTED** tunnel only. A connect or path-loss recovery
  in flight is left alone: it re-reads the persisted config on its next
  connect pass, so a settings change never has to tear down a recovery that is
  waiting for the network (which would turn a self-healing session into a hard
  failure). RN also flushes any pending push just before a connect, so a change
  made moments before tapping Connect is applied on that connect.

Native keeps every recent entry; the Recents row decides which are offerable. A pill
pins its exact `relayId`, and a pinned connect fails outright when the broker no
longer lists that relay, so TS renders a pill only while its relay is present in the
loaded exit-node directory (that directory and the pinned-connect path fetch the same
`DIRECTORY_RELAY_LIMIT` page and apply the same usability predicate). While the
directory is unloaded or failed nothing is hidden — absence is not evidence.

Event: name **`openrungStateChanged`**, payload `NativeVpnState`. Emitted on every
status/log/relay/recents change. TS subscribes via `NativeEventEmitter`.
Android also honors `addListener`/`removeListeners` no-op methods (RN interop).

`src/native/OpenRungVpn.ts` exports the typed module. When
`NativeModules.OpenRungVpn` is missing (Jest, fresh Metro without rebuild) it
falls back to `MockOpenRungVpn` (in `src/native/mock.ts`): a scripted simulator
that walks preparing → connecting → connected with fake log lines, so the UI is
demoable without native builds. Selection is automatic; a `isMock` flag is
exported for the Debug screen to display.

## 4. TypeScript layout

```
src/
  config.ts            # port of AppConfig.kt (same constant names/values)
  theme.ts             # palette + mono font (ios Menlo / android monospace)
  i18n/
    index.tsx          # LanguageProvider, useStrings(), setLanguage(tag), RTL note
    strings/en.ts …    # ported from android res/values*/strings.xml (9 locales;
                       #   picker shows 10 options: System default + 9 languages)
  model/
    relay.ts           # RelayDescriptor (snake_case JSON, optional broker-served
                       #   city/country/country_code/latitude/longitude), isUsable()
    countryGeo.ts      # 51-entry centroid table, verbatim from CountryGeo.kt
    exitNode.ts        # ExitNodeRegion (country+city marker), DirectoryStatus
  net/
    brokerClient.ts    # decode native firstReachable relay snapshot
    exitNodeDirectory.ts # groups relays by broker-served geo (no client-side GeoIP)
    speedTestClient.ts # map native brokerapi speed snapshot
    telemetryClient.ts # build + serialize speed-test event batches
  state/
    store.ts           # app store: native slice (mirrored) + directory slice
    useVpnState.ts     # hook wiring native events into the store
  native/
    types.ts, OpenRungVpn.ts, OpenRungBroker.ts, mock.ts
  screens/
    MainScreen.tsx, SettingsScreen.tsx, DebugScreen.tsx,
    LicensesScreen.tsx, LicenseTextScreen.tsx
  components/
    ExitNodeMap.tsx, MapStatusChip.tsx, RecentsSection.tsx,
    SettingPanel.tsx, ConsolePanel.tsx, ScreenHeader.tsx
  licenses/
    notices.ts         # bundled license text (generated from THIRD_PARTY_NOTICES.md + LICENSE)
App.tsx                # route enum { MAIN, SETTINGS, DEBUG, LICENSES, LICENSE_TEXT },
                       # BackHandler mapping, dark StatusBar, SafeArea handling
```

Store shape (mirrors `OpenRungUiState`):

```ts
interface AppState {
  native: NativeVpnState;                 // mirrored from native
  brokerUrl: string;                      // fixed to config default (not editable)
  directoryStatus: 'idle' | 'loading' | 'loaded' | 'failed';
  availableRegions: ExitNodeRegion[];
  languageTag: string;                    // '' = system, persisted in AsyncStorage
}
```

Derived: `isWorking` = preparing|connecting|disconnecting; `isConnected` = connected.
`refreshDirectory(force?)` reproduces `OpenRungStatusStore.refreshDirectory`
(no-op while loading or after a successful non-empty load unless forced).

Speed test runs only while connected, against `config.TELEMETRY_BROKER_URL`,
and posts `speed_test_completed` / `speed_test_failed` telemetry with the
identity from `getIdentity()` (skipped when `sessionId` is null).
`OpenRungBroker.runSpeedTest` runs brokerapi's warmup/measurement flow; Go
`TotalDurationMillis` maps to the established TypeScript `durationMs`.

## 5. UI fidelity

Terminal-green-on-black, ALL text monospace. Palette (from MainActivity.kt):
screen `#030604`, panel `#07110B`, border dim green `#294F35`, terminal green
`#65F58A`, body `#D8FFE0`, dim text `#7DA989`, relay line `#A5F2B5`, connected
button `#B6F579`, on-green text `#061008`, console error `#FFA0A0`, chip failed
`#FFC0C0`, chip bg `#07110B` @ 80%, FAB `#0D1C12`/`#65F58A`, marker stroke `#04140A`.

Screens replicate the Compose layout exactly (spacing 16/18/20dp, button 58dp
r8, map panel r12 border 1, recents cards 140dp r10, FAB bottom-right 20dp,
footer 12sp centered). Navigation = instant swap on a route enum; hardware back:
DEBUG→SETTINGS, LICENSES→SETTINGS, LICENSE_TEXT→LICENSES, else exit-default.
No spinners anywhere — state is communicated by text, exactly like the original.

Map: `@maplibre/maplibre-react-native`. Same style JSON ("openrung-neon",
demotiles vector source, ocean `#030604`, land `#65F58A` @ 0.12, outline @ 0.85
width 1). Camera fixed: center [116, 18], zoom 2.2, min=max=2.2; rotate/tilt/zoom
gestures disabled, pan allowed. ShapeSource (one feature per region:
`code`/`name`/`count` props) + halo CircleLayer (r18, opacity 0.18) + core
CircleLayer (r6, stroke 2 `#04140A`) + count SymbolLayer (11pt, "Open Sans
Semibold", halo 1.4, offset [0,-1.6]). Tap (hitbox 28) → `connect(code)`.

## 6. Android native

Ported from the production app with packages renamed
`com.openrung.client.*` → `com.openrung.*`; UI/Compose/directory code is NOT
ported (that lives in TS now). Files:

### Cross-platform WSS/CDN fallback contract

This contract applies to both native clients; §7 records the iOS adapter and
lifecycle details. WSS is a per-relay access fallback, not a replacement tunnel
protocol. The existing VLESS/Reality/Vision client remains the authenticated
end-to-end data path. Each platform MUST attempt that relay's normal Reality
address first and MUST NOT request a WSS ticket until the direct attempt has
produced a genuine remote TCP or post-start data-path failure. Configuration
encoding, engine creation or startup, VPN permission, Android socket
protection, network-monitor setup, and other local/platform failures fail the
connection locally; they neither unlock WSS nor count against relay health.

A relay is WSS-eligible only when the signed descriptor says
`node_class=foundation`, `exit_mode=direct`, `public_port=443`, and `transport`
is empty or `direct`, and contains a non-empty `wss_fronts` array. The complete
advertised array MUST already exactly match `wsscore.NormalizeFronts`
(supported protocol version, canonical URL/ID, uniqueness, and ID-sorted
order). Kotlin and Swift never repair, reorder, or independently reimplement
those rules; malformed sets make WSS unavailable. Eligible fronts are attempted
sequentially in their exact signed order.

For each front, the client POSTs `{relay_id, front_id}` to the selected broker
base path plus `/api/v1/wss/tickets`, then the built-in broker fronts in order.
Production broker URLs MUST be HTTPS; only an explicit literal-loopback HTTP
base is accepted as a development allowance. Redirects are rejected, caching is
disabled, and client/session identity headers are sent only as a complete pair.
All broker-front attempts share a 15 s deadline and use at most 5 s each. A 429
or 503 can schedule one additional failover round: `Retry-After` accepts
delta-seconds or HTTP-date, a missing/invalid/zero value uses 10 s, and a large
value is clamped to 30 s; the retry is skipped if that wait would consume the
remaining overall budget. The first broker diagnostic is retained if all
attempts fail; status diagnostics never include a response body. Successful
responses are capped at 64 KiB and require
an opaque ticket of at most 4096 UTF-8 bytes, a future `expires_at`, and a URL
that exactly equals the selected signed front.

The exact descriptor URL and opaque ticket are passed unchanged to
`wsscore.DialClient`; neither is reconstructed, put into another URL, or logged.
Its loopback endpoint is validated and supplied to the existing Reality client.
The shared transport implementation is the tagged Go module
`github.com/openrung/openrung/wsscore v0.2.0`, pinned in
`android/punchbridge/go.mod`; the repository contains only the gomobile adapter,
ticket/lifecycle policy, telemetry, and platform integration. Android constructs
the client with a `SocketProtector`; before the outer CDN socket connects it
delegates to `VpnService.protect(fd)`. A missing callback, exception, panic, or
`false` result fails closed and never calls `connect(2)`. iOS constructs the
same client inside `PacketTunnel` with the platform-native
`NewOpenRungWSSClientForIOS` entry point. iOS has no `VpnService` equivalent, so
that constructor deliberately selects wsscore's nil-protector path.
Both constructors enable wsscore's opt-in CloudFront no-SNI mode. The core
applies it only when the exact signed URL uses a native one-label
`*.cloudfront.net` distribution hostname: ClientHello SNI is omitted, the same
hostname remains in the encrypted HTTP `Host` header, and the certificate is
still verified against that hostname. Custom CloudFront CNAMEs and all other
CDNs retain ordinary URL-derived SNI. No platform layer rewrites the URL,
selects a TLS verification name, or implements this TLS behavior itself. DNS
resolution can still reveal the distribution hostname. An ambiguous no-SNI
handshake failure never retries the same single-use ticket with SNI; the normal
front ladder may continue only with the next signed front and a fresh
front-bound ticket.

The first direct failure is the relay-health event. Ticket, CDN, handshake, and
WSS-path failures emit transport-only telemetry (`transport_failed` with
`transport=wss`, front ID, and stage) and MUST NOT add another relay penalty.
Once connected, native WSS adapter loss, the end-to-end path-health failure
threshold, or a changed physical-network fingerprint retires the session.
Android treats route/interface/DNS changes as a new epoch. On iOS, the first
`NWPath` fingerprint establishes a baseline and only a later, different
fingerprint is an epoch change; repeated identical callbacks are ignored.
Extension wake resumes the Reality engine but is not itself an epoch change and
MUST NOT retire a healthy WSS session or mint a ticket. An unexpected local
Reality-engine exit is instead terminal: it never triggers reladdering, ticket
acquisition, or WSS recovery.
Cleanup clears ownership before close and always stops the Reality engine before
the native WSS adapter. Recovery waits for a usable physical network, fetches
fresh signed relay data, and starts again at direct Reality; single-use tickets
and the prior WSS preference are never reused across network epochs.

iOS startup and active-health classification MUST probe over
`NEPacketTunnelProvider.createTCPConnectionThroughTunnel` with TLS, bounded
request time, and a bounded HTTP response head. A `URLSession` created by the
packet-tunnel provider bypasses that provider's TUN and therefore MUST NOT be
used as evidence that Reality or WSS carried end-to-end traffic.

- `vpn/OpenRungVpnService.kt`, `vpn/ProxyEngine.kt` — connect flow including
  Android NAT-punch-first/RelayHub and direct-first WSS/CDN fallback,
  connection-failure handling,
  notification id 2001 channel `openrung_vpn`, heartbeat 50–70s.
- `net/` BrokerClient, GeoIpClient, InternetProbe, RelayReachability,
  SingBoxConfiguration, NatPunchClient, WssTicketClient, WssClient,
  PhysicalNetworkEpochMonitor; `model/` RelayDescriptor, RelaySelector, CountryGeo,
  RecentNode; `telemetry/` all four files (since diverged: `application_connection`
  events are aggregated client-side by the added `ApplicationConnectionAggregator.kt`,
  and the schema dropped destination ip/port/protocol); `config/AppConfig.kt`.
- `state/ConnectionStatus.kt`, `state/OpenRungStatusStore.kt` — trimmed: drop
  directory fields/refresh (TS owns), keep status/relay/error/logs/recents +
  SharedPreferences persistence (`openrung_status`).
- `bridge/OpenRungVpnModule.kt` + `bridge/OpenRungVpnPackage.kt` — implements §3.
  Collects `OpenRungStatusStore.uiState`, maps to a WritableMap, emits events.
  `prepare()` uses VpnService.prepare + ActivityEventListener (request code 7001)
  and POST_NOTIFICATIONS via PermissionAwareActivity on API 33+.
- `vpn/SplitTunnelStore.kt` also holds `SplitTunnelRegion` (the Kotlin port of
  `src/model/splitTunnelDefaults.ts`: IANA zone → ISO region → preset, read fresh
  from `TimeZone.getDefault()` on every call) and
  `SplitTunnelConfig.resolvedBypassCountries(region)`, which re-derives the
  countries of a `country_source:"auto"` config and returns a manual one
  verbatim. `OpenRungVpnService.currentSplitTunnelRules()` calls it, so every
  connect attempt AND every recovery reconnect resolves against where the device
  is at that moment — no RN participation required.
- Split-tunnel emission (`net/SingBoxConfiguration.kt`): optional constructor
  input `splitTunnel: SplitTunnelRules? = null` (bypassLan, bypassCountries —
  pre-validated by the caller and normalized to `ir`,`cn` order,
  excludedPackages, ruleSetDirectory). `null`, or rules with nothing effective,
  emit JSON byte-identical to the no-split output; callers pass `null` when the
  feature is disabled. With rules, the deltas are exactly: `exclude_package` on
  the tun inbound (after `endpoint_independent_nat`; only when excludedPackages
  is non-empty; `include_package` is NEVER emitted); per enabled country, `ir`
  first, an appended dns server
  `{"tag":"dns-direct-<cc>","type":"https","server":<resolver ip>,"tls":{"enabled":true,"server_name":<provider host>}}`
  (no `detour`: a detour-less DNS server already builds its own direct dialer,
  while detouring through the otherwise-empty tagged direct outbound fails
  during the sing-box Start stage) — DoH over 443, never plaintext UDP/53, since
  these queries ride the direct path on the user's real IP while the tunnel is
  up. Currently only `cn` has one (`223.5.5.5` / `dns.alidns.com`, AliDNS);
  `ir` has none, because every endpoint Shecan publishes served an expired
  certificate as of 2026-08-12 and no other Iranian provider exposes a reachable
  encrypted resolver. A country without a resolver emits NO dns server and NO
  dns rules — its route bypass is unchanged and its lookups fall to the proxied
  chain, which is strictly better than a primary that must fail a TLS handshake
  on every lookup before the fallback runs. A country WITH one also emits a
  three-rule `dns.rules` chain
  `{"rule_set":["geosite-<cc>"],"action":"evaluate","server":"dns-direct-<cc>","timeout":"2s"}`
  followed by the two NOERROR/NXDOMAIN `match_response` `respond` rules scoped
  to the same rule set, so a resolver that is unreachable, times out or has let
  its certificate lapse falls through to the global chain instead of failing
  the lookup; appended after the always-present probe pin (below), before
  `final`; `route.rule_set`
  local/binary entries for `geosite-<cc>.srs` and `geoip-<cc>.srs` under
  `ruleSetDirectory`, before `rules`; and `route.rules` ordered [hijack-dns
  (existing, first), `{"action":"sniff"}` (only when countries non-empty),
  the probe route pin
  `{"domain_suffix":[<probe hostnames>],"outbound":"proxy"}` (only when
  countries non-empty; it must precede every bypass rule so a dead proxy can
  never look healthy via a bypassed probe — geosite-cn contains
  `www.gstatic.com`), `{"ip_is_private":true,"outbound":"direct"}` (only when
  bypassLan), per-country
  `{"rule_set":["geosite-<cc>","geoip-<cc>"],"outbound":"direct"}`,
  `ir` before `cn`]. `final:"proxy"`, `route_exclude_address` logic,
  `find_process`, and everything else are unchanged.
- Baseline DNS emission (both platforms): `dns-<i>` servers are DoH
  (`{"type":"https","server":<ip>,"detour":"proxy"}`, defaults port 443 and
  path `/dns-query`, plus `tls.server_name` = the provider hostname —
  `cloudflare-dns.com` / `dns.google`) over `1.1.1.1` then `8.8.8.8`; TCP/53
  through the proxy is forbidden — it receives no replies under WSS relays.
  IP-literal servers keep the bootstrap non-circular. `dns.rules` ALWAYS
  contains (no-split baseline included), in order: the 4-rule probe failover
  chain (`evaluate dns-0` with `disable_cache`+`disable_optimistic_cache` and
  a 2s timeout, `respond` on `match_response` RCODE NOERROR, `respond` on
  NXDOMAIN — nonce probes legitimately draw it — then a terminal
  `server: dns-1` route, all scoped `domain_suffix: [<probe hostnames>]` so a
  probe lookup can never reach a country rule), then any country rules, then
  the same 4-rule chain unscoped and cache-friendly as the global failover
  (sing-box has no upstream failover of its own; `evaluate` is non-terminal
  on transport error/timeout/SERVFAIL/REFUSED in the pinned engine).
  `dns.final` names the terminal fallback (`dns-1`), `dns.timeout` is 3s, and
  `route.default_domain_resolver` stays `dns-0`. Probe budgets are DERIVED
  from these chain constants, never hand-tuned: one raw-DNS attempt gets the
  chain's worst case (primary evaluate + terminal fallback = 5s) plus 1s
  margin, the startup deadline covers two attempts, and the iOS through-tunnel
  HTTPS request budget adds the worst case on top of its 3s exchange budget
  because its in-tunnel resolution is uncached for probe domains by design —
  a blackholed primary must never starve the fallback into a false failure.
- `vpn/SplitTunnelStore.kt` — persists the raw config JSON in the
  SharedPreferences file `openrung_split_tunnel`, key `config_json`; `parse`
  uses kotlinx-serialization with `ignoreUnknownKeys`, invalid JSON ⇒ null.
  `writeAndReportEffectiveChange` persists and reports whether the *effective*
  config changed (a canonical signature over enabled / bypass_lan / recognized
  countries / excluded packages), so a no-op push never reapplies.
- `OpenRungVpnService` `ACTION_REAPPLY` (`com.openrung.action.REAPPLY`) —
  dispatched by the bridge when `setSplitTunnelConfig` made an effective change
  while status is PREPARING/CONNECTING/CONNECTED. The service reconnects only
  when status is **CONNECTED** with a live engine in this instance, reusing the
  stored `brokerUrl`, `requestedTargetCountry`, and `requestedTargetRelayId`; it
  skips CONNECTING (a connect or recovery in flight re-reads the config on its
  next pass, so a settings change never clobbers a recovery waiting for the
  network) and `stopSelf`s when a reapply intent started an otherwise idle
  service. The service reads ONE split-tunnel snapshot at connect() start, so
  every config construction site in that attempt uses consistent rules.
- Rule-set staging: build.gradle copies `rulesets/dist/*.srs` into a generated
  assets dir (`copyOpenRungRuleSets`; APK asset path `rulesets/<name>.srs`);
  on every connect the service copies the four assets to
  `<filesDir>/libbox/rulesets/` via a temp file renamed into place (a mid-copy
  IO failure can never leave a truncated `.srs`) and that absolute path is
  `ruleSetDirectory`. A country whose files are missing is dropped and
  `log_split_ruleset_missing` (present in every locale `strings.xml`) logged;
  an `excluded_packages` entry whose app is no longer installed is dropped
  (`addDisallowedApplication` would otherwise throw and abort the connect) —
  connect proceeds either way (fail-open, §1).
- `bridge/OpenRungAppListModule.kt` — separate module **`OpenRungAppList`**
  (registered in OpenRungVpnPackage; does not widen this §3 contract):
  `getInstalledApps()` resolves `[{ "packageName": string, "label": string }]`
  of launcher-intent activities, deduped by package, excluding our own
  applicationId, sorted by label case-insensitively, resolved on a background
  executor. The manifest carries a `<queries>` element with the MAIN/LAUNCHER
  intent for API 30+ package visibility. TS accessor
  `src/native/OpenRungAppList.ts` follows the OpenRungApkShare optional-module
  pattern: on iOS or when the module is absent, `isAppListAvailable` is false
  and `getInstalledApps()` resolves `[]`.
- Manifest: INTERNET, ACCESS_NETWORK_STATE, FOREGROUND_SERVICE,
  FOREGROUND_SERVICE_SPECIAL_USE, POST_NOTIFICATIONS; service
  `.vpn.OpenRungVpnService` with BIND_VPN_SERVICE + specialUse;
  `networkSecurityConfig=@xml/network_security_config` — cleartext HTTP denied for
  all hosts (discovery, telemetry, geo and probes are all HTTPS; see ARCHITECTURE.md
  § "Network transport").
- Gradle: serialization plugin (Kotlin 2.1.20), kotlinx-serialization-json 1.7.3,
  kotlinx-coroutines-android 1.9.0, conditional `implementation(files("libs/libbox.aar"))`
  (file is copied locally, git-ignored). Status strings the service logs live in
  `res/values*/strings.xml` (ported subset, all 10 locales).
- `android/punchbridge/` (the gomobile punch, WSS, and broker bindings plus the
  sagernet-QUIC session/transport/bridge layer, tests excluded) is copied into sing-box's
  temporary `experimental/libbox` tree by `build-libbox-release.sh`, so punch
  and libbox share one gomobile runtime/AAR. The shared punch protocol core is
  not copied: it is resolved as the `github.com/openrung/openrung/punchcore`
  Go module at the version pinned in `android/punchbridge/go.mod`, which the
  script injects into the grafted sing-box `go.mod` via
  `go get github.com/openrung/openrung/punchcore@<pinned version>`
  (`PUNCHCORE_SRC` swaps in a local-checkout `replace` for development only —
  never for releases). The Go UDP fd must be accepted by
  `VpnService.protect` before discovery begins; failure falls back to RelayHub.
- The same combined AAR grafts `wss_binding.go`, but resolves all WebSocket,
  TLS, yamux, transport-bound, and loopback-adapter code from the exact wsscore
  version in `android/punchbridge/go.mod`. `WSSCORE_SRC` is a local-development
  replace only and MUST NOT be used for a release artifact.
- The AAR also grafts `broker_binding.go` and resolves
  `github.com/openrung/openrung/brokerapi v0.1.0` from the same `go.mod`.
  Eligible direct broker requests attempt opportunistic ECH with verified
  ordinary-TLS fallback. `BROKERAPI_SRC` is an explicit local-development
  replace only. Kotlin/Swift generated adapters serve both platform-native
  VPN clients and the dedicated React Native module without a second runtime.
- The signed descriptor must advertise an explicit HTTPS punch endpoint. Bare-IP
  self-signed coordinators are accepted only when their exact certificate SHA-256
  appears in `AppConfig.PUNCH_COORDINATOR_CERT_SHA256_BY_HOST`; hostname endpoints
  use normal public-CA validation. Redirects and cleartext are always rejected.
- After a direct connection reaches CONNECTED, Android races native QUIC closure
  against a jittered end-to-end health monitor. Startup and health sweeps verify
  fresh DNS first (a nonce-labelled raw query for
  `<nonce>.probe.openrung.org` through the TUN, answered only via the proxied
  DoH resolver; any well-formed response counts) and then HTTPS to
  `probe.openrung.org/generate_204` with `cp.cloudflare.com/generate_204` as
  fallback — both rule-pinned through the proxy ahead of country bypass.
  Resolver failover happens inside the emitted DNS rule chain, so a
  `dns_probe`-stage failure means no configured resolver answered through
  that transport. Three failed tunnel
  sweeps plus a successful physical-network connectivity probe trigger fresh
  discovery/re-punch and RelayHub fallback. Native path loss waits for a
  reachable physical network, so a local outage leaves the foreground service
  CONNECTING instead of failing it. The PHYSICAL probe stays bound to
  `Network.openConnection` but targets only `www.gstatic.com/generate_204`
  and `cp.cloudflare.com/generate_204`; any HTTP response proves
  connectivity, and no OpenRung identity/broker header is sent.
- A transport-independent engine monitor watches libbox during direct, punched,
  and WSS sessions. Unexpected engine exit is a terminal local failure and never
  starts reladdering or ticket acquisition. WSS network, adapter, and end-to-end
  path-health recovery cancels that monitor, stops the engine first, closes the
  physical-network epoch monitor, and then closes the WSS adapter. It waits for
  a usable physical network before fresh signed discovery and a direct-first
  attempt with a fresh ticket only if another eligible remote failure occurs.
- Direct-path recovery is bounded per relay. Losses before five minutes use
  jittered exponential backoff; the third rapid loss opens a circuit for the
  current user connection, so fresh discovery still runs but that relay is
  reached through RelayHub. A real physical-network outage does not increment the
  breaker, and an explicit connect/disconnect resets it.
- `ProxyEngineFactory` returns a `StubProxyEngine` (throws "engine not linked")
  when libbox is absent at runtime — compile-time guarded the same way the
  original handles a missing AAR (reflection-free: source set always compiled,
  AAR always present locally; the stub protects CI checkouts without the AAR —
  see build.gradle comment).

## 7. iOS native

The project is regenerated by **xcodegen** from `ios/project.yml` (replicating
the RN template app target: Start Packager + Bundle React Native code build
phases, ENABLE_USER_SCRIPT_SANDBOXING=NO, current pbxproj settings), plus the
`PacketTunnel` app-extension target. `scripts/generate-project.sh` runs
`xcodegen generate` + `pod install`. Podfile target stays `OpenRung`.

- `ios/PacketTunnel/` — ported verbatim from production
  (`PacketTunnelProvider.swift`, `PacketTunnelProxyEngine.swift`,
  `LibboxPacketTunnelPlatformInterface.swift`, `EngineDirectories.swift`,
  Info.plist, entitlements) with the §2 identifiers substituted.
- `ios/Shared/` — ported `Shared/` + the OpenRungKit sources the tunnel and
  module need (BrokerClient, RelayDescriptor, RelaySelector, SingBoxConfiguration,
  GeoIpClient, CountryGeo, RelayReachability, InternetProbe, Telemetry*,
  ActivityLog, ConnectionStatus/Snapshot, SharedConnectionState, AppConfig …)
  flattened into one directory compiled into BOTH targets (no SPM package).
- `ios/Shared/WssTicketClient.swift` and `WssFallbackPolicy.swift` implement
  the shared §6 ticket and direct-first classification contract. PacketTunnel
  owns `WssNativeClient.swift`, the exact-front validator, and
  `PhysicalNetworkEpochMonitor.swift`: adapter loss, the health-failure
  threshold, or a changed `NWPath` fingerprint stops Reality before the
  adapter, then performs fresh signed discovery, direct Reality first, and a
  fresh ticket only if another eligible remote failure occurs. An identical
  `NWPath` callback is ignored, and wake only resumes the engine; neither event
  alone retires a healthy WSS session.
- `ios/PacketTunnel/PunchNativeClient.swift` and
  `PunchRecoveryCircuitBreaker.swift`, plus
  `ios/Shared/PunchFallbackPolicy.swift`, implement the punch-first same-relay
  ladder. Only broker-signed `punch_capable` descriptors with a strict HTTPS
  endpoint are eligible. Bare-IP coordinators require an exact leaf pin;
  hostname endpoints retain normal CA/hostname verification. The native result
  must expose a literal loopback bridge. Adapter, changed-`NWPath`, and
  end-to-end health loss stop Reality before QUIC, wait for a usable physical
  path, then perform fresh signed discovery. Three rapid direct losses open the
  per-relay circuit for the current user connection and select RelayHub.
- `ios/OpenRung/OpenRungVpnModule.swift` + `OpenRungVpnModule.m`
  (RCT_EXTERN_MODULE) — implements §3 over NETunnelProviderManager +
  SharedConnectionState (Darwin observer + NEVPNStatusDidChange), including the
  production relay-switch dance (stop → 350 ms → reconfigure → start).
- `ios/OpenRung/OpenRungBrokerModule.swift` plus its Objective-C extern module
  implement the separate §3 broker surface. The Foundation-only request
  coordinator is included in hostless tests, which use fake operations and do
  not load React or Libbox.
- Split tunneling: the raw config JSON is stored in app-group UserDefaults
  under `AppConfig.splitTunnelConfigDefaultsKey` (`"split_tunnel_config"`).
  `ios/Shared/SplitTunnelConfig.swift` (compiled into both targets) also holds
  `SplitTunnelRegion` — the Swift port of `src/model/splitTunnelDefaults.ts`,
  reading `TimeZone.current` fresh on every call — and
  `resolvedBypassCountries(region:)`, which `resolveSplitTunnelRules()` uses so
  every connect attempt and recovery reconnect re-derives an automatic selection
  itself. The same file decodes it
  — `load(from:)` returns nil on absence, parse failure, or `enabled == false`
  — and defines `SplitTunnelRules` (bypassLan, bypassCountries,
  ruleSetDirectory; no package field) plus the §6 country constants.
  `setSplitTunnelConfig` writes the raw string always but reapplies only on an
  *effective* change (`SplitTunnelConfig.effectiveSignature`, which ignores
  `excluded_packages` since iOS never emits it) while both the shared lifecycle
  and `NEVPNStatus` report fully connected. Connecting/reasserting recovery is
  left alone to read the persisted config on its next connect pass. A qualified
  reapply runs the existing relay-switch dance (stop → 350 ms → start — the
  persisted providerConfiguration already carries the last targets, so no
  reconfigure). The dance captures a `controlEpoch` before the delay and aborts
  the restart if a connect/disconnect arrived meanwhile, so a reapply never
  resurrects a tunnel the user stopped during the window.
  The four `.srs` files are explicit PacketTunnel bundle resources
  (project.yml); `ruleSetDirectory` is the extension bundle resource path, and
  at connect() start the provider verifies each enabled country's two files
  exist, dropping the country with an ActivityLog line otherwise (fail-open,
  §1). iOS has no per-app bypass: `excluded_packages` is parsed and ignored,
  so a config whose only effective content is excluded packages yields nil
  rules.
- Both targets: packet-tunnel-provider entitlement + app group; no ATS exceptions —
  default App Transport Security is enforced because every production endpoint
  is HTTPS (see ARCHITECTURE.md § "Network transport"). The OpenRung host and
  PacketTunnel extension each link the same static
  `ThirdParty/Libbox.xcframework` (`embed:false`) plus `libresolv.tbd`;
  PacketTunnel sets `APPLICATION_EXTENSION_API_ONLY=YES` and compiles without
  the xcframework via the existing `#if canImport(Libbox)` stub.
- `ios/build-libbox-release.sh` generates that one device+simulator
  `Libbox.xcframework` by grafting the shared punch binding/session/bridge,
  `broker_binding.go`, and `wss_binding.go` into the pinned sing-box libbox
  package and resolving brokerapi v0.1.0, punchcore v0.1.0, and wsscore v0.2.0
  from `android/punchbridge/go.mod`. PacketTunnel calls the generated
  `LibboxNewOpenRungPunchClientForIOS(baseURL,relayID,insecureTLS,certSHA256,listener)`
  export. Its nil protector is Apple-specific: provider-created sockets are
  outside PacketTunnel's own TUN, while the Android constructor remains
  fail-closed on a missing/rejected protector. PacketTunnel also calls the
  generated
  `LibboxNewOpenRungWSSClientForIOS(frontURL,ticket,listener)` export, whose
  nil `SocketProtector` deliberately selects wsscore's Apple nil-protector
  path. A second gomobile framework/runtime or an artifact built with
  `BROKERAPI_SRC`, `PUNCHCORE_SRC`, or `WSSCORE_SRC` is not releasable.

The exact direct-broker and CloudFront manifest candidates use
`fetchManifestCandidate`; the GitHub release asset remains the narrowly allowed
redirecting JavaScript fetch. TypeScript still verifies exact envelope bytes,
freshness, rollback monotonicity, cache contents, and candidate preference.
Rollback of this migration is by shipping/reverting the app version, never a
hidden legacy transport switch.

## 8. Known prototype limitations (documented in README)

- In-app language switch does not relayout RTL (fa/ar) without app restart.
- iOS simulator: UI + map + directory work; connect fails by design
  (NetworkExtension requires a signed device build).
- Telemetry from TS covers only speed-test events; the native connect path keeps
  production telemetry except that `application_connection` is reduced client-side:
  DNS flows are skipped; destination ip/port/protocol and client
  geo/device/network attributes are never sent; and repeated flows normally collapse
  into one event per application per 15 minutes carrying a `connection_count` flow
  total. Totals above 100,000 are split without discarding the remainder and sent in
  separate per-app HTTP-batch budgets, with the still-suppressed tail flushed atomically
  when the session ends or is replaced (relay switch) so the broker's summed rollup
  stays accurate within the existing bounded-outbox and at-least-once-delivery limits.
- Per-app split-tunnel bypass is Android-only: `excluded_packages` is parsed
  and ignored on iOS (no iOS per-app tunnel exclusion).
- With a country bypass preset enabled, DNS for bypassed domains resolves via
  that country's in-country public resolver over the direct path, as DoH over
  443 (AliDNS `223.5.5.5` / `dns.alidns.com` for `cn`), so the query is
  encrypted even though it leaves the device on the user's real IP. A failing
  in-country resolver falls back to the proxied chain rather than failing the
  lookup. `ir` currently has no such resolver (Shecan's certificate is expired),
  so Iranian bypass traffic still takes the direct path but resolves through the
  proxied chain.
- Apps excluded at the OS level (Android `exclude_package`) bypass the TUN
  entirely and are invisible to telemetry/traffic counters; sing-box-routed
  direct flows (LAN/country bypass) remain counted.
- License: GPL-3.0-or-later (statically links sing-box), same as production.
