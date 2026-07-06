# OpenRung RN prototype — architecture contract

This document is the binding contract between the TypeScript shell and the two
native implementations. Every implementer follows it exactly; deviations must be
recorded here.

Reference implementation: `/opt/projects/openrung` (the production Android app in
`android/`, the production iOS app in `ios/`). This prototype models its UI and
functionality 1:1 unless noted.

## 1. Division of responsibility

**Native (Kotlin service / Swift NEPacketTunnelProvider extension)** owns the whole
connect path, exactly as in the production apps:
broker relay fetch (connect path), relay selection, TCP reachability, sing-box
(libbox) engine lifecycle, TUN + DNS config, internet probe, fail-closed behavior,
heartbeat telemetry, VPN permission + background lifecycle, recents recording,
status/log persistence.

**TypeScript (RN shell)** owns everything the production *app processes* own:
all UI, navigation, exit-node map directory (broker fetch, grouped by the
broker-served relay locations — relay IPs are never geolocated client-side),
speed test, language selection, licenses screens.

## 2. Identifiers

| Thing | Value |
|---|---|
| Android applicationId | `com.openrung.mobile` |
| Android namespace / Kotlin root package | `com.openrung` |
| Android minSdk / compile / target | 26 / 36 / 36 (minSdk raised from RN default 24) |
| iOS app bundle id | `com.openrung.mobile` |
| iOS extension bundle id | `com.openrung.mobile.PacketTunnel` |
| iOS app group | `group.com.openrung.mobile` |
| iOS VPN profile localizedDescription | `OpenRung Volunteer VPN` |
| iOS deployment target | 16.0 |
| DEVELOPMENT_TEAM | `9VLV9A7KS9` |
| Darwin notification (ext→app) | `com.openrung.mobile.state-changed` |

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
  label: string;         // "City, Country" or country name
  latitude: number;
  longitude: number;
}

export interface NativeVpnState {
  status: ConnectionStatus;
  relayLabel: string | null;   // resolved geo label, never a raw IP
  lastError: string | null;
  logLines: string[];          // "[HH:mm:ss] message", newest last, cap 80
  recents: RecentNode[];       // newest first, deduped by countryCode, cap 8
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
}
```

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
    brokerClient.ts    # GET /api/v1/relays?limit=N, candidates(), firstReachable()
    exitNodeDirectory.ts # groups relays by broker-served geo (no client-side GeoIP)
    speedTestClient.ts # warmup 1MB + measure 10MB via /api/v1/speed-test
    telemetryClient.ts # POST /api/v1/telemetry/events (speed-test events only)
  state/
    store.ts           # app store: native slice (mirrored) + directory slice
    useVpnState.ts     # hook wiring native events into the store
  native/
    types.ts, OpenRungVpn.ts, mock.ts
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
identity from `getIdentity()` (skipped when `sessionId` is null). RN `fetch`
cannot stream progressively; measure wall time to full body and note TTFB as
headers-arrival time (documented limitation).

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

- `vpn/OpenRungVpnService.kt`, `vpn/ProxyEngine.kt` — verbatim port (connect flow,
  fail-closed, notification id 2001 channel `openrung_vpn`, heartbeat 50–70s).
- `net/` BrokerClient, GeoIpClient, InternetProbe, RelayReachability,
  SingBoxConfiguration; `model/` RelayDescriptor, RelaySelector, CountryGeo,
  RecentNode; `telemetry/` all four files; `config/AppConfig.kt`.
- `state/ConnectionStatus.kt`, `state/OpenRungStatusStore.kt` — trimmed: drop
  directory fields/refresh (TS owns), keep status/relay/error/logs/recents +
  SharedPreferences persistence (`openrung_status`).
- `bridge/OpenRungVpnModule.kt` + `bridge/OpenRungVpnPackage.kt` — implements §3.
  Collects `OpenRungStatusStore.uiState`, maps to a WritableMap, emits events.
  `prepare()` uses VpnService.prepare + ActivityEventListener (request code 7001)
  and POST_NOTIFICATIONS via PermissionAwareActivity on API 33+.
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
- `ios/OpenRung/OpenRungVpnModule.swift` + `OpenRungVpnModule.m`
  (RCT_EXTERN_MODULE) — implements §3 over NETunnelProviderManager +
  SharedConnectionState (Darwin observer + NEVPNStatusDidChange), including the
  production relay-switch dance (stop → 350 ms → reconfigure → start).
- Both targets: packet-tunnel-provider entitlement + app group; no ATS exceptions —
  default App Transport Security is enforced because every endpoint is HTTPS (see
  ARCHITECTURE.md § "Network transport"). PacketTunnel links `ThirdParty/Libbox.xcframework`
  (embed:false) + libresolv.tbd, `APPLICATION_EXTENSION_API_ONLY=YES`; compiles
  without the xcframework via the existing `#if canImport(Libbox)` stub.

## 8. Known prototype limitations (documented in README)

- Speed test TTFB/throughput measured via whole-body fetch (no streaming).
- In-app language switch does not relayout RTL (fa/ar) without app restart.
- iOS simulator: UI + map + directory work; connect fails by design
  (NetworkExtension requires a signed device build).
- Telemetry from TS covers only speed-test events; the native connect path keeps
  full production telemetry.
- License: GPL-3.0-or-later (statically links sing-box), same as production.
