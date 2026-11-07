# iOS home-screen widget

One WidgetKit widget (`OpenRungConnect`, small family only) that shows the tunnel's
current status and offers a Connect control. A tap starts a tunnel to an
**automatically chosen relay** through the app's own connect path; the widget never
selects a relay, talks to the broker, or holds a VPN entitlement.

## How a tap becomes a tunnel

```text
  widget extension (com.openrung.app.OpenRungWidget)      app process (com.openrung.app)
  ┌───────────────────────────────────────────┐            ┌─────────────────────────────────────────┐
  │ ConnectWidget reads app group:            │            │ WidgetConnectMailbox (one pending tap)  │
  │   connection_state → status → WidgetFace  │            │   ▲ intent.perform()   ▲ openrung://    │
  │   widget_language_tag → WidgetStrings     │            │   │ (iOS 17+, run by   │ connect (iOS   │
  │                                           │            │   │  the system here)  │ 16, SceneDel.) │
  │ iOS 17+: Button(intent: WidgetConnectIntent)  ───────► │ OpenRungVpnModule.deliverWidgetConnect │
  │ iOS 16:  widgetURL(openrung://connect)    ───────────► │   collect() · WidgetConnectPolicy       │
  └───────────────────────────────────────────┘            │   → JS event openrungConnectRequested   │
                                                           │   → prepareAndConnect(null, null)       │
  PacketTunnel: SharedConnectionState writes the snapshot  │   → OpenRungVpn.connect(broker, nil, nil)│
  and WidgetReloadGate reloads the widget on face change   └─────────────────────────────────────────┘
```

- `WidgetConnectIntent` sets `openAppWhenRun` (and `supportedModes = .foreground` on
  iOS 26+), so the system opens the app and runs `perform()` **in the app process**.
  A widget extension cannot load `NETunnelProviderManager`; nothing in the extension
  ever tries.
- On iOS 16 the whole widget is the control: it carries `openrung://connect` while a
  Connect control is shown and `openrung://open` otherwise. `WidgetConnectURL`
  accepts exactly `openrung://connect` (scheme and host only; any path, query,
  fragment, user, password or port is rejected), so a URL can never carry a target,
  and it acts **only on iOS 16**: from iOS 17 the intent is the one way in, so an
  arbitrary app or web link can only open OpenRung, never start a tunnel.
- `WidgetConnectMailbox` holds one request, collapses repeat deliveries of one tap
  (3 s window, or while one is still pending) and drops anything older than 30 s
  when collected, so a cold launch that never reached JavaScript cannot connect later.
- `WidgetConnectPolicy` runs in the app when JavaScript is listening: it starts only
  when the shared snapshot (reconciled with `NEVPNStatus`) is disconnected or failed
  **and** the OS tunnel is `.invalid`/`.disconnected`. A tunnel that is connecting,
  connected, reasserting or disconnecting — including one the user pointed at a chosen
  country — is left alone. A refused request is consumed, not retried.
- The accepted request reaches JavaScript as `openrungConnectRequested` and runs the
  same `prepareAndConnect(null, null)` the in-app CONNECT button uses (split-tunnel
  flush, consent, `connect(brokerUrl, null, null)`), so connectcore chooses the relay.

## App-group contract

| Key | Writer | Reader | Meaning |
| --- | --- | --- | --- |
| `connection_state` | PacketTunnel only | app, widget | The existing `ConnectionStateSnapshot`; the widget decodes `status` only. |
| `widget_language_tag` | app (`OpenRungWidget.setLanguageTag`) | widget | In-app language selection, `''` = system. |
| `widget_last_face` | `WidgetReloadGate` (PacketTunnel) | PacketTunnel | Last face WidgetKit was asked to render. |
| `widget_system_tunnel_down` | app (`WidgetStaleTunnelMarker`, set only) · PacketTunnel (removed on every snapshot write) | widget | The OS reported no tunnel while the snapshot still said connected/connecting: the widget shows Disconnected. |

The app never writes `connection_state`. `WidgetReloadGate` asks WidgetKit to reload
only when the face (`disconnected` / `connecting` / `connected` / `disconnecting` /
`failed`; `preparing` collapses into `connecting`) changed — never per log line or
engine event — and the app reloads once per language change.

Extension killed under the tunnel: when iOS stops the extension (memory limit, crash)
the snapshot keeps saying "connected". Once the app has loaded its tunnel manager,
`refreshVPNStatus` sees the OS report `.disconnected`/`.invalid` against a live
snapshot and sets `widget_system_tunnel_down` — once, deduplicated on the stored
value, with one WidgetKit reload — so the widget shows Disconnected with a Connect
control. The app never clears the marker: the tunnel's next snapshot flush removes
it (`WidgetReloadGate.publish`), so a real tunnel always wins and ordering stays
with the sole snapshot writer. Until the app next runs, the widget still shows the
last tunnel-written face; tapping it opens the app, which corrects it.

A widget tap is also never acted on before that manager load has finished:
`OpenRungVpnModule` leaves the request in the mailbox until both JavaScript is
listening and the OS tunnel state is known, so a placeholder `.invalid` can never
pass for "down" and let a running country-pinned tunnel be replaced.

## Strings

`ios/OpenRungWidget/WidgetStrings.generated.swift` is rendered from
`src/i18n/strings/*.ts` by `npm run widget:strings` (keys listed in
`src/i18n/widgetStrings.ts`). `__tests__/core/widgetStrings.test.ts` fails when the
committed Swift drifts from the TypeScript tables; `WidgetStringsTests` (XCTest)
covers resolution (stored tag → device language → English, `zh-Hant`/TW/HK/MO →
`zh-TW`) and the right-to-left layout for `fa` and `ar`.

## Provisioning

The widget is a second app extension on the same team (`9VLV9A7KS9`):

1. App ID `com.openrung.app.OpenRungWidget`, explicit, with the **App Groups**
   capability and the existing group `group.com.openrung.app`. No Network
   Extension capability: the widget's entitlements file holds the app group only.
2. With automatic signing, Xcode registers the App ID and provisioning profile on the
   first device build; for cloud-managed/manual signing create the profile for the
   new App ID like the PacketTunnel one.
3. The app's Info.plist registers the `openrung` URL scheme; nothing else is needed
   for the iOS 16 path.
4. `CFBundleShortVersionString`/`CFBundleVersion` of the widget inherit
   `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`, so App Store validation sees the
   same version on all three bundles.

Regenerate the project after touching `ios/project.yml`:

```sh
bundle exec ./ios/scripts/generate-project.sh
```

## Local checks

```sh
npm run widget:strings
npm test -- --ci --runInBand
xcodebuild -project ios/OpenRung.xcodeproj -scheme OpenRungTests \
  -destination 'platform=iOS Simulator,id=<booted sim>' test
xcodebuild -project ios/OpenRung.xcodeproj -scheme OpenRungWidget \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

The simulator cannot start a packet tunnel, so a widget tap there ends in the
app's canned simulator error, exactly like the in-app button.

## Physical-device checklist

Run on a signed iPhone with the VPN profile already saved once from the app.

- [ ] Add the small widget; it renders the app name, status and
      CONNECT in the in-app language (change the language in Settings and confirm
      the widget re-renders once; set Persian or Arabic and confirm right-to-left).
- [ ] iOS 17+: tap CONNECT from a disconnected state with the app killed. The app
      opens, the console shows the normal connect sequence, the relay is the
      automatically chosen one (no country/relay pin), and the widget moves to
      "Connecting" then "Connected".
- [ ] Tap the widget while connected: the app opens, nothing restarts, the tunnel
      stays on the same relay.
- [ ] Connect to a chosen country in the app, then tap the widget: the tunnel is not
      switched.
- [ ] Double-tap CONNECT quickly: exactly one connect attempt in the console.
- [ ] Disconnect in the app: widget shows "Disconnected" and offers CONNECT again.
- [ ] Open `openrung://connect` from Safari on iOS 17+: the app opens and does
      **not** connect (the URL acts only on iOS 16). On an iOS 16 device,
      `openrung://connect?country=JP` and `openrung://connect/x` open the app without
      connecting; plain `openrung://connect` connects.
- [ ] iOS 16 device (if available): tapping the widget opens the app via the URL and
      connects; while connected the tap only opens the app.
- [ ] Kill the app, wait a minute, tap CONNECT: still connects (request is fresh at
      collection). Then simulate a stale request only if a debug build exposes it.
- [ ] Watch WidgetKit reloads over one connect/disconnect cycle (Console.app,
      subsystem `com.apple.chronod`): two reloads for connect, two for disconnect.
