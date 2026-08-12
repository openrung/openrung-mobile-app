# OpenRung RN prototype — architecture overview

This is the readable companion to [`CONTRACT.md`](CONTRACT.md), which is the
binding specification. Where they disagree, the contract wins.

## The one-sentence version

A React Native (TypeScript) shell owns all UI and the "app-process" logic of
the production OpenRung clients, while the entire VPN connect path is a
verbatim port of the production native code — a Kotlin `VpnService` on
Android, a Swift `NEPacketTunnelProvider` extension on iOS — exposed through
narrow cross-platform bridge modules. `OpenRungVpn` owns the VPN lifecycle.
Android-only OS integrations, such as installed-APK sharing and the
split-tunneling app picker, use separate modules so they do not widen the VPN
contract. Broker control-plane calls use a second, deliberately narrow classic
module, `OpenRungBroker`; it never exposes WSS tickets.

## Division of responsibility

**Native owns the connect path** (exactly as in the production apps):
broker relay fetch for connecting, relay selection, TCP reachability,
NAT punching, sing-box (libbox) engine lifecycle, TUN + DNS configuration, internet probe,
connection-failure handling, heartbeat telemetry, VPN permission and background
lifecycle, recents recording, and status/log persistence. If the RN process
dies, the tunnel keeps running.

**TypeScript owns everything the production app processes own**: all screens
and navigation, exit-node directory modeling, speed-test UI and telemetry event
construction, manifest verification/selection, language selection, and the
licenses screens. Eligible network requests for those features are executed by
native brokerapi operations.

Note that the broker is queried from *both* sides, matching production: the
native VPN service fetches relays to connect, and the TS shell independently
requests a relay snapshot for the map directory through `OpenRungBroker`.

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
  |     |     -> OpenRungBroker.firstReachable(...)                     |
  |     |        (relays carry broker-served city/country/coords)       |
  |     |     -> group into ExitNodeRegion[] -> map pins                |
  |     v                                    |                          |
  |  src/native/OpenRungVpn.ts        NativeEventEmitter                |
  |  (falls back to mock.ts when      'openrungStateChanged'            |
  |   the native module is absent)    payload: NativeVpnState           |
  +-----|--------------------------------^------------------------------+
        | prepare() / connect(brokerUrl, | event on every status/log/
        | targetCountry) / disconnect()  | relay/recents change
        | / setSplitTunnelConfig(json)   |
        v                                |
  +---------------------------------------------------------------------+
  |               NATIVE BRIDGES (two dedicated classic modules)       |
  |  VPN: OpenRungVpn -> lifecycle, state, logs, split-tunnel config   |
  |  Broker: OpenRungBroker -> one single-use brokerapi operation      |
  +-----|--------------------------------^------------------------------+
        | start / stop                   | status, logs, relay label,
        v                                | recents, errors
  +---------------------------------------------------------------------+
  |                     NATIVE CONNECT PATH (ported verbatim)           |
  |  Android: vpn/OpenRungVpnService.kt (foreground VpnService)         |
  |  iOS:     PacketTunnel extension (NEPacketTunnelProvider)           |
  |                                                                     |
  |  broker fetch -> relay selection -> TCP reachability                |
  |     -> Android/iOS: optional NAT punch -> loopback QUIC bridge      |
  |     -> native: on remote direct failure only, signed WSS/CDN front  |
  |     -> sing-box config -> libbox engine + TUN + DNS                 |
  |     -> internet probe -> geo label -> heartbeat telemetry           |
  |     -> report failure if no relay works                             |
  +-----|---------------------------------------------------------------+
        v
     libbox (sing-box, statically linked)
        -> VLESS + REALITY + Vision -> relay -> open internet
```

State flows one way: native emits a full `NativeVpnState` snapshot on every
change; TS mirrors it into the store and never mutates it. Commands flow the
other way as the six bridge methods (`prepare`, `connect`, `disconnect`,
`getState`, `getIdentity`, `setSplitTunnelConfig`).

## Network transport

Every production endpoint the app talks to is HTTPS. Both platforms enforce
this at the OS layer: iOS runs default App Transport Security (no exceptions),
and the Android `network_security_config.xml` denies cleartext for all hosts.
There is no `http://` production endpoint anywhere in the app. The WSS ticket
URL parser has one code-level development allowance for an explicit
literal-loopback HTTP base; it cannot authorize a remote cleartext endpoint or
weaken the production OS policy.

- **Eligible direct broker requests attempt opportunistic ECH with verified
  ordinary-TLS fallback.** Go `brokerapi` owns request policy, headers,
  timeouts, candidate racing, and relay-list verification for both the native
  VPN clients and `OpenRungBroker`. ECH is opportunistic, not guaranteed; this
  wording does not claim that SNI is never visible or that every app request
  uses ECH.
- **React Native broker surface** — each directory, speed-test, speed-test
  telemetry, or broker-hosted manifest call receives a new single-use native
  operation. Cancelling its Kotlin coroutine or Swift task makes the shared
  PR 2 runner call `Close`; generated objects are copied into value snapshots
  before close. The RN-only directory projection removes `wss_fronts` before
  TypeScript decodes the relay JSON; the full signed envelope remains available
  to the native VPN owners. WSS ticket requests, front URLs, and credentials
  remain exclusively owned by `VpnService` and `PacketTunnelProvider`.
  `brokerClient.firstReachable` then ENFORCES the returned `signatureVerified`
  flag — an unverified snapshot fails the fetch instead of becoming map pins —
  so consolidating verification into Go does not make the shell indifferent to
  whether it happened.
- **Native punch coordination** — a punch-capable relay advertises an explicit
  `https://...` coordinator in that signed list. The deployed bare-IP endpoint
  has a self-signed certificate whose exact SHA-256 leaf pin is built into the
  app; unpinned IP endpoints, redirects, and cleartext endpoints are rejected.
  Future hostname endpoints use normal CA/hostname validation. The authenticated
  response supplies a separate per-session QUIC certificate pin, while
  VLESS/Reality remains the end-to-end authentication and encryption boundary.
  Repeated short-lived direct paths recover with jittered exponential backoff;
  after three rapid losses either platform keeps the selected relay but routes it
  through RelayHub for the rest of that user connection.
  Android must successfully protect the retained UDP descriptor with
  `VpnService.protect` before discovery. PacketTunnel uses the Apple constructor
  without a protector because provider-created sockets are outside its own TUN;
  both constructors otherwise share the same pinned punchcore session and
  QUIC/loopback implementation.
- **Native WSS/CDN access fallback** — only after a genuine remote direct
  Reality failure, an eligible foundation relay's signed, wsscore-canonical
  `wss_fronts` are tried in their advertised order. The client obtains a
  relay/front-bound ticket by redirect-rejecting HTTPS POST with sequential
  broker-front failover under one deadline, then passes the exact signed URL and
  opaque ticket to the pinned `github.com/openrung/openrung/wsscore v0.2.0`.
  wsscore exposes a loopback endpoint to the unchanged Reality client. Android
  requires `VpnService.protect(fd)` to return true before connecting the outer
  socket and fails closed; PacketTunnel uses the dedicated Apple constructor's
  nil-protector wsscore path because iOS has no equivalent API. Both
  platforms opt into wsscore's native CloudFront no-SNI mode: only an exact
  one-label `*.cloudfront.net` signed front omits ClientHello SNI while retaining
  hostname certificate verification and the encrypted HTTP Host; custom CNAMEs
  and other CDNs retain ordinary URL-derived SNI. DNS can still expose the
  distribution hostname, and an ambiguous failure is never downgraded into a
  same-ticket retry with SNI. Ticket/CDN
  failures are transport metrics, not extra relay-health penalties. Once
  connected, a native WSS close, the end-to-end health-failure threshold, or a
  changed physical-network fingerprint tears the entire path down; recovery
  begins with fresh discovery and direct Reality, never a reused ticket. On
  iOS, the first `NWPath` fingerprint is the baseline and only a later,
  different fingerprint is an epoch change. Repeated identical callbacks are
  ignored, while device wake resumes the Reality engine without independently
  retiring a healthy native adapter or minting a ticket. On both platforms, the
  transport-independent libbox monitor covers
  direct, punched, and WSS sessions: unexpected engine exit is terminal and
  never starts WSS or reladdering. WSS network, adapter, or end-to-end
  path-health recovery cancels that monitor, stops libbox first, retires the
  epoch monitor, and only then closes the WSS adapter before waiting for a usable
  physical network. On iOS, every startup and health result used for path
  classification is a bounded HTTPS response-head probe created with
  `NEPacketTunnelProvider.createTCPConnectionThroughTunnel`; a provider-owned
  `URLSession` is excluded from its own TUN and must never authorize fallback
  or recovery.
- **Telemetry / heartbeat / speed-test** — currently also `https://broker.openrung.org/`
  (the same Cloudflare-fronted broker); see the trade-off below.
- **Update manifest** — the exact direct broker and CloudFront candidates use
  `OpenRungBroker.fetchManifestCandidate`. The exact redirecting GitHub release
  asset remains the only JavaScript-fetch exception; signature, freshness,
  rollback, cache re-verification, and candidate selection stay in TypeScript.
  The candidate URLs are pinned twice on purpose — `AppConfig.UPDATE_MANIFEST_URLS`
  (what the walk consumes) and `MANIFEST_CANDIDATE_URLS` (what the router will
  accept) — because an unrecognized candidate throws inside the fail-open walk
  and would silently demote the app to the GitHub-only path. `transport:check`
  and `updateManifest.test.ts` both assert the two lists are identical.
- **Geo lookup** (`https://ipwho.is/`) and **connectivity probes** are HTTPS.
  The through-tunnel probes target `https://probe.openrung.org/generate_204`
  (dedicated, OpenRung-controlled; server-side route is a Cloudflare Worker
  returning 204) with `https://cp.cloudflare.com/generate_204` as the
  third-party fallback, plus a fresh-DNS check: a raw nonce-labelled A query
  (`<nonce>.probe.openrung.org`) sent through the TUN, hijacked by sing-box,
  and resolved via the proxied DoH resolver — any well-formed response
  (including NXDOMAIN) proves the DNS path; nonces defeat OS, engine, and
  upstream caches. Neither hostname appears in any bundled geosite rule set,
  and the emitted config pins both (DNS rule → proxied DoH with
  `disable_cache`; route rule → `proxy`) ahead of every country-bypass rule,
  so a split-tunnel preset can never route a probe onto the direct path
  (geosite-cn contains `www.gstatic.com`, which is why gstatic was dropped
  from the through-tunnel lists). Android's physical-network recovery probe
  is unchanged and deliberately identity-free: `Network.openConnection`
  against `www.gstatic.com/generate_204` and `cp.cloudflare.com/generate_204`
  so the check cannot accidentally traverse the unhealthy VPN and sends no
  OpenRung identity or broker headers.
- **In-tunnel DNS** — DoH over 443 to IP-literal resolvers (`1.1.1.1`, then
  `8.8.8.8`), detoured through the `proxy` outbound, with TLS authenticating
  the provider hostnames (`cloudflare-dns.com`, `dns.google`) so a provider
  dropping IP SANs from its certificate cannot break resolution. IP literals
  keep the bootstrap non-circular (no resolver is needed to reach the
  resolver), and port 443 works over every transport — the previous
  TCP/53-via-proxy design received no replies under WSS relays. sing-box has
  no upstream failover of its own, so the emitted `dns.rules` build one from
  1.14 rule actions: `evaluate` the primary (non-terminal on transport
  error/timeout/SERVFAIL/REFUSED), `respond` with any usable answer (NOERROR,
  or an authoritative NXDOMAIN), else fall through to the fallback resolver's
  terminal route rule — per query, mid-session, with no engine restart. A
  `dns_probe`-stage failure therefore means NO configured resolver answered
  through that transport. Split-tunnel bypassed domains still resolve via the
  in-country UDP resolvers over the direct path (unchanged).

There is no runtime switch back to the removed JavaScript broker transports.
A missing or stale `OpenRungBroker` binding rejects as `unavailable` and
requires a native rebuild. Rollback is by reverting or shipping a new app
version, not by enabling a hidden legacy transport.

### Telemetry transport: current (Option B) vs. future (Option A)

Telemetry is higher-volume than discovery — heartbeats fire ~once/minute per
connected user, plus per-app connection records (aggregated client-side: DNS
flows are skipped; destination and client geo/device/network attributes are
never sent; and repeated flows normally collapse into one
`application_connection` event per app per 15 minutes whose `connection_count`
measurement carries the represented flow total. Counts above 100,000 are split
into bounded chunks and separated across HTTP batches to match the broker's
per-app request budget, while each window's still-suppressed tail is flushed
atomically when the session ends or is replaced. The broker's hourly
per-application rollup sums these counts, treating legacy per-flow events as
one each) — so its transport is a cost/security trade-off:

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
- `setSplitTunnelConfig(configJson)` — persist the split-tunnel preset config
  JSON natively (schema in the contract §3); when the tunnel is connected and
  the *effective* config changed (the emitted sing-box config would differ),
  native reapplies by reconnecting to the same target. Resolves when the
  reapply is *dispatched*.
- Event `openrungStateChanged` with payload `NativeVpnState`:
  `{ status, relayLabel, lastError, logLines (cap 80), recents (cap 8) }`.
  `status` is one of disconnected / preparing / connecting / connected /
  disconnecting / failed.

`src/native/types.ts` is the single source of truth for these types.

### Split tunneling (presets)

Settings → Split tunneling is presets-only: a master toggle (default on), with
"bypass local network" also on by default, the Iranian and Chinese sites & apps
presets defaulted from where the device actually is, and — Android only — a
bypassed-apps picker (no individual apps are preselected). RN persists its own
slice, debounces changes, and pushes one small snake_case JSON config
(`version`, `enabled`, `bypass_lan`, `bypass_countries`, `country_source`,
`excluded_packages`) through `setSplitTunnelConfig`.

Native persists the raw string (Android SharedPreferences
`openrung_split_tunnel`, iOS app-group defaults key `split_tunnel_config`)
and, when the tunnel is up and the string changed, reapplies by reconnecting
to the same relay target through the existing relay-switch mechanics.

The two country presets are mutually exclusive — a device is in one country, so
switching one on switches the other off, and hydration collapses any pair left
by an older install. A preset may also only ship on *inside* its own country:
`geosite-cn` carries hosts the whole world loads on ordinary pages
(doubleclick.net, fonts.googleapis.com, www.gstatic.com …), so bypassing it
elsewhere would put those requests on the direct path with the user's real IP
while the app reports CONNECTED, and inside China the same bypassed hosts are
GFW-blocked and simply fail. `src/model/splitTunnelDefaults.ts` picks the
default from the device's IANA time zone and nothing else — offline, no geo-IP
call, no location permission, and no locale fallback, since a language
preference is not evidence of location and guessing from it would hand the
China preset to exactly the diaspora phones this protects. A fresh install
starts with Iran + LAN in Iran, China + LAN in mainland China, and LAN alone
everywhere else.

An automatic selection keeps following the device: RN records the region it was
derived from (`autoCountryRegion`) and re-derives whenever the device has moved,
so a phone that auto-selected China in Shanghai drops it on landing in Berlin.
That check runs on every app foreground and immediately before every connect,
not just at hydration — hydration settles once per JS process, and the process
routinely survives the flight. A selection the user made by hand is frozen and
never re-derived.

RN is not the last line of defence, because it is not always running. The pushed
config carries `country_source`, and on an automatic selection each native
generator ignores the stored country list and re-derives from its own `TimeZone`
whenever it builds a config — which includes the recovery reconnects both
services perform on their own after a physical-network change, with the app
possibly unopened for weeks. That is what stops a tunnel from being rebuilt with
`geosite-cn` bypassed in Berlin, and it removes the race where a foreground
re-check arrives while a recovery is already connecting (reapply is deliberately
skipped in that window). `SplitTunnelRegion` is ported into Kotlin and Swift
alongside `src/model/splitTunnelDefaults.ts`; all three must agree. Installs that persisted the old unconditional `["ir","cn"]` default
are repaired once, keyed on a `defaultsRevision` stamp. All of this lives in
RN's own persisted slice, never in the native config JSON (see CONTRACT §3).

At connect time the native generators translate the stored config into
sing-box deltas: an `ip_is_private` → direct route rule for LAN bypass;
per-country local rule sets (`geosite-<cc>.srs` / `geoip-<cc>.srs`, bundled
from `rulesets/dist/` — Android stages them into `<filesDir>/libbox/rulesets/`,
iOS reads them from the PacketTunnel bundle) routed direct, with a sniff rule
and per-country DNS over the direct path where a trustworthy in-country
resolver exists (AliDNS `223.5.5.5` for China — as DoH over 443, since those
queries leave the device on the user's real IP and must not be readable or
forgeable on the way; a failing resolver falls through to the proxied chain
rather than failing the lookup). Iran currently ships none: every endpoint
Shecan publishes served an expired certificate as of 2026-08-12, and a primary
that must fail a TLS handshake on every lookup is worse than none at all, so
Iranian bypass traffic takes the direct path while resolving through the proxied
chain. And on Android an OS-level `exclude_package`
list on the TUN inbound. The Android app picker is fed by the separate
`OpenRungAppList` module (launcher apps, background-resolved). Everything
fails open (CONTRACT §1): a bad/missing config or a missing rule-set file
degrades to full-tunnel behavior with a log line — split tunneling never
blocks a connect.

### Android-only offline APK sharing

The Settings tab's General section has a "Share OpenRung offline" row that calls
the separate `OpenRungApkShare` native module. `InstalledApkProvider` exposes
one exact, read-only `content://` URI for the package's own installed APK and
the module opens the standard `ACTION_SEND` chooser with a temporary read
grant. The provider streams `ApplicationInfo.sourceDir` directly, so sharing
does not keep a second copy of the large APK in app storage.

This path is enabled only for a monolithic installation. If
`ApplicationInfo.splitSourceDirs` is non-empty, the module rejects the action:
`sourceDir` is only `base.apk`, and sending it without its configuration splits
would give the recipient an incomplete app. No storage or package-install
permission is requested by the sender.

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
| iOS app / extension | `com.openrung.client(.PacketTunnel)` | `com.openrung.app(.PacketTunnel)` |
| App group | `group.com.openrung.client` | `group.com.openrung.app` |
| Darwin notification | `com.openrung.client.state-changed` | `com.openrung.app.state-changed` |

## Android native (§6)

The production connect-path packages are ported with only the package rename
(`com.openrung.client.*` → `com.openrung.*`); Compose UI and directory code
are not ported (TS owns them). Key pieces:

- `vpn/OpenRungVpnService.kt` + `vpn/ProxyEngine.kt` — the whole connect
  flow, NAT-punch-first/RelayHub-fallback ladder, connection-failure handling,
  notification id 2001 on channel `openrung_vpn`, heartbeat every 50–70 s.
- `net/NatPunchClient.kt` + `android/punchbridge/` — a cancelable gomobile
  binding over the shared `github.com/openrung/openrung/punchcore` module
  (pinned in `punchbridge/go.mod`), compiled into the same AAR/Go runtime as
  libbox. It protects the retained UDP fd with `VpnService.protect`, then
  exposes a loopback TCP bridge that sing-box uses without changing the relay's
  Reality identity.
- `net/WssTicketClient.kt`, `net/WssClient.kt`, and
  `net/PhysicalNetworkEpochMonitor.kt` — ticket control-plane policy, the thin
  Android adapter over wsscore, and network-epoch retirement. WebSocket/TLS,
  yamux, copying, and transport bounds remain entirely in the pinned wsscore Go
  module compiled into the combined AAR.
- `android/punchbridge/broker_binding.go` — the single-use gomobile foundation
  over pinned `brokerapi v0.1.0`, compiled into that same AAR/Go runtime.
  `NativeBrokerTransport` confines generated objects and serves both the
  Android VPN clients and the separate `OpenRungBroker` module through
  constructor-specific factories.
- `net/`, `model/`, `config/AppConfig.kt` — verbatim. `telemetry/` — ported,
  then diverged: `application_connection` flow events are aggregated
  client-side (see "Telemetry transport" above) via the new
  `ApplicationConnectionAggregator.kt`, and the telemetry schema no longer
  carries destination ip/port/protocol.
- `state/OpenRungStatusStore.kt` — trimmed to status/relay/error/logs/recents
  (directory state removed), still persisted in SharedPreferences
  (`openrung_status`).
- `bridge/OpenRungVpnModule.kt` — implements the contract; collects the
  status store's flow, maps it to a WritableMap, emits events.
- `bridge/OpenRungApkShareModule.kt` + `share/InstalledApkProvider.kt` —
  Android-only sharesheet integration for streaming the installed monolithic
  APK through a narrowly scoped, temporary URI grant.
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
- `ios/Shared/WssTicketClient.swift` + `WssFallbackPolicy.swift` and the
  PacketTunnel-owned `WssNativeClient.swift` +
  `PhysicalNetworkEpochMonitor.swift` mirror the direct-first, ticket,
  transport-only health, engine-before-adapter cleanup, and fresh network-epoch
  recovery rules.
- `ios/PacketTunnel/PunchNativeClient.swift`,
  `PunchRecoveryCircuitBreaker.swift`, and
  `ios/Shared/PunchFallbackPolicy.swift` validate signed coordinator metadata,
  bridge the shared Go punch session into PacketTunnel, preserve
  engine-before-adapter teardown, and bound unstable-path recovery before
  selecting RelayHub for the remainder of the user connection.
- `ios/OpenRung/OpenRungVpnModule.swift` — the bridge over
  `NETunnelProviderManager` + app-group shared state (Darwin observer +
  `NEVPNStatusDidChange`), including the production relay-switch dance
  (stop → 350 ms → reconfigure → start).
- The `OpenRung` host and `PacketTunnel` extension are separate executables;
  both link the single static `ThirdParty/Libbox.xcframework` generated by
  `ios/build-libbox-release.sh` with `embed: false`, and each also links
  `libresolv.tbd` for libbox's Go DNS resolver. The framework contains libbox
  plus the thin brokerapi, Apple punchcore, and Apple wsscore adapters in one
  gomobile runtime.
  Swift value snapshots and the shared cancellation-safe runner serve both
  PacketTunnel and the `OpenRungBroker` host module; hostless tests use fakes
  and never load Libbox.

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

- In-app language switch does not relayout RTL (fa/ar) without app restart.
- iOS simulator: UI + map + directory work; connect fails by design
  (NetworkExtension requires a signed device build).
- Telemetry from TS covers only speed-test events; the native connect path
  keeps full production telemetry.
- Per-app split-tunnel bypass is Android-only; iOS parses and ignores
  `excluded_packages`.
- With a country bypass preset on, DNS for bypassed domains resolves via that
  country's in-country public resolver over the direct path, encrypted (DoH/443)
  and falling back to the proxied chain. China uses AliDNS; Iran has no
  currently valid encrypted resolver, so it resolves through the proxied chain
  while its traffic still takes the direct path.
- Android apps excluded at the OS level are invisible to telemetry/traffic
  counters; sing-box-routed direct flows (LAN/country bypass) remain counted.
- License: GPL-3.0-or-later (statically links sing-box), same as production.
