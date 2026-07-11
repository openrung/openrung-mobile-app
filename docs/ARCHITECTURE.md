# OpenRung RN prototype — architecture overview

This is the readable companion to [`CONTRACT.md`](CONTRACT.md), which is the
binding specification. Where they disagree, the contract wins.

## The one-sentence version

A React Native (TypeScript) shell owns all UI and the "app-process" logic of
the production OpenRung clients, while the entire VPN connect path is a
verbatim port of the production native code — a Kotlin `VpnService` on
Android, a Swift `NEPacketTunnelProvider` extension on iOS — exposed to
TypeScript through one small bridge module, `OpenRungVpn`.

## Division of responsibility

**Native owns the connect path** (exactly as in the production apps):
broker relay fetch for connecting, relay selection, TCP reachability,
Android NAT punching, sing-box (libbox) engine lifecycle, TUN + DNS configuration, internet probe,
connection-failure handling, heartbeat telemetry, VPN permission and background
lifecycle, recents recording, and status/log persistence. If the RN process
dies, the tunnel keeps running.

**TypeScript owns everything the production app processes own**: all screens
and navigation, the exit-node map directory (its own broker fetch, grouped by
the broker-served relay locations — the app never geolocates relay IPs), the
speed test, language selection, and the licenses screens.

Note that the broker is queried from *both* sides, matching production: the
native service fetches relays to connect, and the TS shell independently
fetches relays to draw the map directory.

**Availability over "never leak."** OpenRung is availability-first. The only leak
protection is sing-box `strict_route` while the tunnel is up; there is deliberately
no OS-level kill switch, so when the tunnel is down (no relay reachable, a crash, or
between sessions) traffic falls back to the normal network instead of being blocked.
"Report failure if no relay works" below means the connect attempt reports failure
without leaving a leaky tunnel — not that traffic is blocked. See CONTRACT.md §1.

## Data flow

```text
                         REACT NATIVE (TypeScript)
  +---------------------------------------------------------------------+
  |  Screens (Main / Settings / Debug / Licenses)                       |
  |     |                                    ^                          |
  |     | connect(code) / disconnect()       | store update -> rerender |
  |     v                                    |                          |
  |  app store (src/state/store.ts)  <--- useVpnState hook              |
  |     |                                    ^                          |
  |     |                                    |                          |
  |     |   DIRECTORY PATH (TS-owned)        |                          |
  |     |   store.refreshDirectory()         |                          |
  |     |     -> src/net/brokerClient.ts  GET /api/v1/relays?limit=N    |
  |     |        (relays carry broker-served city/country/coords)       |
  |     |     -> group into ExitNodeRegion[] -> map pins                |
  |     v                                    |                          |
  |  src/native/OpenRungVpn.ts        NativeEventEmitter                |
  |  (falls back to mock.ts when      'openrungStateChanged'            |
  |   the native module is absent)    payload: NativeVpnState           |
  +-----|--------------------------------^------------------------------+
        | prepare() / connect(brokerUrl, | event on every status/log/
        | targetCountry) / disconnect()  | relay/recents change
        v                                |
  +---------------------------------------------------------------------+
  |                    NATIVE BRIDGE  (module 'OpenRungVpn')            |
  |  Android: bridge/OpenRungVpnModule.kt (collects StatusStore flow)   |
  |  iOS:     OpenRungVpnModule.swift (Darwin notify + NEVPNStatus)     |
  +-----|--------------------------------^------------------------------+
        | start / stop                   | status, logs, relay label,
        v                                | recents, errors
  +---------------------------------------------------------------------+
  |                     NATIVE CONNECT PATH (ported verbatim)           |
  |  Android: vpn/OpenRungVpnService.kt (foreground VpnService)         |
  |  iOS:     PacketTunnel extension (NEPacketTunnelProvider)           |
  |                                                                     |
  |  broker fetch -> relay selection -> TCP reachability                |
  |     -> Android: optional NAT punch -> loopback QUIC bridge          |
  |     -> sing-box config -> libbox engine + TUN + DNS                 |
  |     -> internet probe -> geo label -> heartbeat telemetry           |
  |     -> report failure if no relay works                             |
  +-----|---------------------------------------------------------------+
        v
     libbox (sing-box, statically linked)
        -> VLESS + REALITY + Vision -> volunteer relay -> open internet
```

State flows one way: native emits a full `NativeVpnState` snapshot on every
change; TS mirrors it into the store and never mutates it. Commands flow the
other way as the five bridge methods (`prepare`, `connect`, `disconnect`,
`getState`, `getIdentity`).

## Network transport

Every endpoint the app talks to is HTTPS. Both platforms enforce this at the OS
layer: iOS runs default App Transport Security (no exceptions), and the Android
`network_security_config.xml` denies cleartext for all hosts. There is no `http://`
endpoint anywhere in the app.

- **Relay discovery** — independent HTTPS fronts return an Ed25519-signed relay
  list. Native and TypeScript clients verify the raw response bytes against the
  pinned operator keys before accepting any relay or punch endpoint.
- **Android punch coordination** — a punch-capable relay advertises an explicit
  `https://...` coordinator in that signed list. The deployed bare-IP endpoint
  has a self-signed certificate whose exact SHA-256 leaf pin is built into the
  app; unpinned IP endpoints, redirects, and cleartext endpoints are rejected.
  Future hostname endpoints use normal CA/hostname validation. The authenticated
  response supplies a separate per-session QUIC certificate pin, while
  VLESS/Reality remains the end-to-end authentication and encryption boundary.
- **Telemetry / heartbeat / speed-test** — currently also `https://broker.openrung.org/`
  (the same Cloudflare-fronted broker); see the trade-off below.
- **Geo lookup** (`https://ipwho.is/`) and **connectivity probes**
  (`https://www.gstatic.com/generate_204`, `https://cp.cloudflare.com/generate_204`)
  are HTTPS.

### Telemetry transport: current (Option B) vs. future (Option A)

Telemetry is higher-volume than discovery — heartbeats fire ~once/minute per
connected user, plus per-app connection records — so its transport is a
cost/security trade-off:

- **Option B — current.** Send telemetry to the Cloudflare-fronted
  `https://broker.openrung.org/`, the same endpoint as discovery. TLS end-to-end with
  zero extra infrastructure. Cost: every heartbeat runs through the Cloudflare Worker
  and counts against its request quota (free tier: 100k/day). Fine at low user counts.
- **Option A — future, if the Worker quota becomes the bottleneck.** Give the origin
  box a dedicated *unproxied* (DNS-only / "grey-cloud") hostname — e.g.
  `origin.openrung.org` → the origin IP directly — with a publicly-trusted TLS
  certificate (e.g. Let's Encrypt) terminated on the origin, then point
  `TELEMETRY_BROKER_URL` at `https://origin.openrung.org/`. This keeps telemetry
  TLS-protected *and* bypasses the Cloudflare Worker (so it no longer consumes the
  quota), while remaining a real hostname both platforms' cleartext policies accept.
  The app-side change is one line of `TELEMETRY_BROKER_URL` in each of the three
  `AppConfig` files (`src/config.ts`, `android/.../config/AppConfig.kt`,
  `ios/Shared/AppConfig.swift`); the rest is server-side (DNS record + origin cert).
  Because the new endpoint is HTTPS, no cleartext exception is needed on either
  platform — unless the origin cannot present a publicly-trusted cert, in which case
  add a scoped `domain-config` in `network_security_config.xml` (Android) and the
  equivalent `NSExceptionDomains` entry (iOS) for that one hostname.

  Do **not** revert to the old raw-IP-over-HTTP telemetry endpoint. That transmitted
  the user's real pre-VPN IP, city, ISP and stable client ID in cleartext — readable
  by the volunteer relay operator, and (on connection-failure flush paths) by the
  user's own censored network.

## The bridge contract (§3 of the contract)

One classic NativeModule named `OpenRungVpn` on both platforms, identical
shape (the RN 0.86 bridgeless interop layer handles it):

- `prepare()` — OS VPN consent. Android: `VpnService.prepare` dialog (plus
  POST_NOTIFICATIONS on API 33+). iOS: load-or-create the
  `NETunnelProviderManager` and save it.
- `connect(brokerUrl, targetCountry)` — start or switch the tunnel;
  `targetCountry` is ISO alpha-2 or null (broker picks). Resolves when the
  start is *dispatched*; completion arrives via events.
- `disconnect()`, `getState()`, `getIdentity()`.
- Event `openrungStateChanged` with payload `NativeVpnState`:
  `{ status, relayLabel, lastError, logLines (cap 80), recents (cap 8) }`.
  `status` is one of disconnected / preparing / connecting / connected /
  disconnecting / failed.

`src/native/types.ts` is the single source of truth for these types.

### The mock

When `NativeModules.OpenRungVpn` is missing (Jest, or Metro attached to a
build without the native module), `src/native/OpenRungVpn.ts` transparently
substitutes `MockOpenRungVpn` — a scripted simulator that walks
preparing → connecting → connected with fake log lines. Selection is
automatic; an exported `isMock` flag lets the Debug screen display it.

## Identifiers

Everything is re-namespaced so the prototype installs side-by-side with the
production app:

| | Production | Prototype |
| --- | --- | --- |
| Android applicationId | `com.openrung.client` | `com.openrung.mobile` |
| Kotlin root package | `com.openrung.client` | `com.openrung` |
| iOS app / extension | `com.openrung.client(.PacketTunnel)` | `com.openrung.mobile(.PacketTunnel)` |
| App group | `group.com.openrung.client` | `group.com.openrung.mobile` |
| Darwin notification | `com.openrung.client.state-changed` | `com.openrung.mobile.state-changed` |

## Android native (§6)

The production connect-path packages are ported with only the package rename
(`com.openrung.client.*` → `com.openrung.*`); Compose UI and directory code
are not ported (TS owns them). Key pieces:

- `vpn/OpenRungVpnService.kt` + `vpn/ProxyEngine.kt` — the whole connect
  flow, NAT-punch-first/RelayHub-fallback ladder, connection-failure handling,
  notification id 2001 on channel `openrung_vpn`, heartbeat every 50–70 s.
- `net/NatPunchClient.kt` + `android/punchbridge/` — a cancelable gomobile
  binding compiled into the same AAR/Go runtime as libbox. It protects the
  retained UDP fd with `VpnService.protect`, then exposes a loopback TCP bridge
  that sing-box uses without changing the volunteer's Reality identity.
- `net/`, `model/`, `telemetry/`, `config/AppConfig.kt` — verbatim.
- `state/OpenRungStatusStore.kt` — trimmed to status/relay/error/logs/recents
  (directory state removed), still persisted in SharedPreferences
  (`openrung_status`).
- `bridge/OpenRungVpnModule.kt` — implements the contract; collects the
  status store's flow, maps it to a WritableMap, emits events.
- libbox arrives as a git-ignored local AAR (`app/libs/libbox.aar`,
  conditional Gradle file dependency); a `StubProxyEngine` that throws
  "engine not linked" protects checkouts without the AAR.

## iOS native (§7)

The Xcode project is regenerated by xcodegen from `ios/project.yml` (the RN
template app target plus the `PacketTunnel` app-extension target);
`ios/scripts/generate-project.sh` runs `xcodegen generate` + `pod install`.

- `ios/PacketTunnel/` — the production provider, proxy engine, and libbox
  platform interface, ported verbatim with the prototype identifiers.
- `ios/Shared/` — the production `Shared/` + needed OpenRungKit sources
  flattened into one directory compiled into both targets (no SPM package).
- `ios/OpenRung/OpenRungVpnModule.swift` — the bridge over
  `NETunnelProviderManager` + app-group shared state (Darwin observer +
  `NEVPNStatusDidChange`), including the production relay-switch dance
  (stop → 350 ms → reconfigure → start).
- `PacketTunnel` links `ThirdParty/Libbox.xcframework` (embed: false) +
  libresolv.tbd; compiles without the framework via `#if canImport(Libbox)`.

## UI fidelity (§5)

Terminal-green-on-black, all text monospace (Menlo on iOS, monospace on
Android), no spinners anywhere — state is communicated by text, exactly like
the original. The palette, spacing, map style ("openrung-neon" over MapLibre
demotiles) reuses the production Compose UI's palette and marker design; the
redesigned shell renders the map full-screen behind an edge vignette, with a
glass connect card and a Home / Settings / About us tab bar on top. Base hex
values live in §5 of the contract.

Navigation is an instant swap over plain state (a bottom-tab enum
HOME / SETTINGS / ABOUT plus pushed sub-routes DEBUG / LICENSES /
LICENSE_TEXT) with hardware-back mapping — no navigation library.

## Known limitations (§8)

- Speed test TTFB/throughput measured via whole-body fetch (no streaming in
  RN `fetch`).
- In-app language switch does not relayout RTL (fa/ar) without app restart.
- iOS simulator: UI + map + directory work; connect fails by design
  (NetworkExtension requires a signed device build).
- NAT punching is currently Android-only; iOS uses the advertised RelayHub path.
- Telemetry from TS covers only speed-test events; the native connect path
  keeps full production telemetry.
- License: GPL-3.0-or-later (statically links sing-box), same as production.
