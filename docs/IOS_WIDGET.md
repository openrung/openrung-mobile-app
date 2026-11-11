# iOS home-screen widget

One WidgetKit widget (`OpenRungConnect`, small family only) that shows the tunnel's
current status and offers a Connect control. A tap starts a tunnel to an
**automatically chosen relay** through the app; the widget never selects a relay,
talks to the broker, or holds a VPN entitlement. On iOS 17+, once the app has a
saved VPN profile, that happens **without opening the app**
([below](#connect-without-opening-the-app)).

While connected it also shows the relay's display name with its country flag, how
long the tunnel has been up, and (iOS 17+) a Disconnect control that ends the tunnel
**without opening the app**. The OpenRung mark sits in the top trailing corner.

## How a tap becomes a tunnel

The path that opens the app: iOS 16 always, and iOS 17+ until a VPN profile is saved.

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

## Connect without opening the app

Saving the first VPN profile brings up the OS consent dialog, which needs the app
in front. After that nothing about a no-target connect needs the app's UI, so on
iOS 17+ the widget switches to a second intent:

1. **Readiness.** `OpenRungVpnModule` publishes `widget_background_connect` wherever
   it has just read or written the profile: true when a saved profile exists, false
   when it does not. It reloads the widget only when the value changes. The widget
   offers `WidgetBackgroundConnectIntent` when the key is true and the app-opening
   `WidgetConnectIntent` otherwise.
2. **Routing.** `WidgetBackgroundConnectIntent` conforms to `LiveActivityIntent`.
   That is used for one thing: the system performs such an intent in the app's
   process without bringing the app to the front, launching it in the background
   when it is not running. No Live Activity is started.
3. **Start.** The intent may run before JavaScript is up, so it does not go through
   the mailbox or `openrungConnectRequested`. `AppDelegate` installs a native
   starter at launch, `VpnProfile.startFromWidget()`, which loads the saved profile,
   reconciles the snapshot with `NEVPNStatus`, applies the same `WidgetConnectPolicy`
   and, only on `.start`, writes the default broker with no target country or relay
   and calls `startVPNTunnel()`. It never creates a profile. It uses the split-tunnel
   configuration the app last persisted to the app group; the JavaScript-side flush
   and consent steps of `prepareAndConnect` are not run.
4. **Fallback.** If the profile is gone or the start throws, the intent sets
   `widget_background_connect` to false. The rebuilt widget offers the app-opening
   intent again, so the next tap opens the app, which can ask for consent.
5. **Feedback.** WidgetKit holds a widget's reloads while its intent runs and
   rebuilds the timeline a few seconds after `perform()` returns. That rebuild is
   the one reload this path can count on: the app is never in front, so every later
   request, the tunnel's or the widget's own, may be deferred. Two things follow.
   - The intent stays open until the connect has an outcome. After a start it waits
     up to 3 s for the tunnel's first snapshot and then, while the tunnel is
     connecting, up to 20 s from the start (`WidgetBackgroundConnect.wait`), so the
     rebuild lands on "Connected" or "Failed". A connect that takes longer leaves
     the rebuild on "Connecting", and the tunnel's own reloads and
     `WidgetSelfRefresh` take over as for a connect made in the app.
   - The control is a `Toggle` rather than a `Button`: the system draws a toggle's
     other side the moment it is tapped and keeps it until the rebuild, and that
     side is the whole connecting face. So the toggle draws the status line as
     well, above itself and outside its own frame: only the control starts a
     connect, and a tap on the status opens the app like a tap anywhere else.

A tap that finds a tunnel connecting, connected, reasserting or disconnecting is
ignored exactly as on the app-opening path. The request still carries nothing: no
relay, country, broker or credential leaves the widget.

`VpnProfile` (`ios/OpenRung/VpnProfile.swift`) is the one place the profile is
found, written and, for this path, started; `OpenRungVpnModule` uses the same
helpers.

## Disconnect without opening the app

WidgetKit opens the app for any tap that does not land on a button, and a button can
only run an App Intent. `WidgetDisconnectIntent` is compiled into the widget
extension alone and does not set `openAppWhenRun`, so the system performs it in the
widget extension, in the background.

The extension cannot load a tunnel manager, so it asks the tunnel to end itself:

1. `WidgetDisconnectRequest.submit()` stores the tap time under
   `widget_disconnect_request` and posts the Darwin notification
   `com.openrung.app.widget-disconnect`.
2. `PacketTunnelProvider` observes that notification from `startTunnel` on. The
   notification is only a wake-up (any process can post one); the request is the
   app-group key, which only this app's own processes can write. The provider
   consumes the key (removing it), ignores a request older than 15 s, and clears any
   leftover request when a tunnel starts, so a tap that found no tunnel can never
   stop a later one.
3. On a fresh request the provider runs the normal `IOSConnectcore.host.stop`
   (snapshot goes `disconnecting`, then `disconnected`) and then
   `cancelTunnelWithError(nil)` so NetworkExtension retires the tunnel.
4. The intent waits up to 5 s for the snapshot to leave the live faces; WidgetKit
   rebuilds the timeline when the intent returns. While a fresh request is still
   unanswered the widget shows "Disconnecting"; if the tunnel never answers, the
   request goes stale and the widget returns to "Connected". That return is a
   second timeline entry dated at the staleness limit, so it does not wait for a
   reload.

The request carries nothing but a timestamp: there is only one tunnel to stop. On
iOS 16 (no interactive widgets) the connected face has no control and a tap opens
the app.

## Connected details

- **Relay and flag.** The widget decodes `relayName`, `relayLabel` and the head of
  `recentRegions` from the snapshot. The country is used only when that head entry
  is the connected relay — its `relayName` and its `label` both match the snapshot's
  `relayName` and `relayLabel`, since a relay without a location adds no entry and
  relay names are not unique; the flag is derived from its two-letter code. The line is
  `privacySensitive`, so it is redacted where the system hides sensitive content.
- **Timer.** `Text(_:style: .timer)` counts from `widget_last_face_at` (when the
  tunnel entered the connected face). The system animates it; no timeline entries or
  reloads are spent on it.
- **Status label.** `widgetStatusDisconnected` may contain a line break; each line
  is drawn as its own single-line `Text` and scaled rather than broken mid-word.

## App-group contract

| Key | Writer | Reader | Meaning |
| --- | --- | --- | --- |
| `connection_state` | PacketTunnel only | app, widget | The existing `ConnectionStateSnapshot`; the widget decodes `status`, `relayName`, `relayLabel` and the head of `recentRegions` (`countryCode`, `relayName`, `label`) only. |
| `widget_language_tag` | app (`OpenRungWidget.setLanguageTag`) | widget | In-app language selection, `''` = system. |
| `widget_last_face`, `widget_last_face_at` | `WidgetReloadGate` (PacketTunnel) | PacketTunnel, widget | Last face WidgetKit was asked to render, and when the tunnel entered it. |
| `widget_last_relay` | `WidgetReloadGate` (PacketTunnel) | PacketTunnel | The connected relay WidgetKit was last asked to show; absent on other faces. |
| `widget_rendered_face` | widget | app, PacketTunnel | Face of the last timeline the widget built. |
| `widget_disconnect_request` | widget (set on a Disconnect tap) · PacketTunnel (removed when consumed and at tunnel start) | PacketTunnel, widget | Tap time of an unanswered Disconnect; ignored after 15 s. |
| `widget_background_connect` | app (`OpenRungVpnModule`, true/false as a saved profile exists; the app-process intent sets false when a start is unavailable) | widget | Whether Connect can run without opening the app. |
| `widget_system_tunnel_down` | app (`WidgetStaleTunnelMarker`, set only) · PacketTunnel (removed on every snapshot write) | widget | The OS reported no tunnel while the snapshot still said connected/connecting: the widget shows Disconnected. |

The app and the widget never write `connection_state`. `WidgetReloadGate` asks
WidgetKit to reload only when the face (`disconnected` / `connecting` / `connected` /
`disconnecting` / `failed`; `preparing` collapses into `connecting`) changed, or the
relay shown on the connected face did — never per log line or engine event — and
the app reloads once per language change.

A reload request is not a render. WidgetKit applies reloads at once while the app is
in the foreground and budgets them otherwise, so a request the tunnel makes after
the app has gone (connect in the app, leave while it is still connecting) may be
deferred and would leave the widget on "Connecting". Two things cover that:

- **The widget refreshes a transitional face itself.** A timeline built on
  `connecting` or `disconnecting` asks to be rebuilt (`WidgetSelfRefresh`), paced by
  how long the tunnel has been in that face (`widget_last_face_at`): every 10 s for
  the first minute, every minute up to ten, hourly after that. A rebuilt timeline on
  a settled face asks for nothing, so a normal connect costs one or two extra
  reloads and a tunnel stuck in transition stays inside the daily budget. Settled
  faces (`disconnected` / `connected` / `failed`) keep the `.never` policy.
- **The app catches up when it is in front.** The widget records the face of every
  timeline it builds (`widget_rendered_face`). Whenever the app is active and that
  record lags the current face, `WidgetRenderCatchUp` requests a reload, once per
  face per activation. The reload gate skips a face the widget has already rendered.

Both are requests to WidgetKit, which still decides when a widget is redrawn while
the app is not in the foreground.

Extension killed under the tunnel: when iOS stops the extension (memory limit, crash)
the snapshot keeps saying "connected". Once the app has loaded its tunnel manager,
`refreshVPNStatus` sees the OS report `.disconnected`/`.invalid` against a live
snapshot and sets `widget_system_tunnel_down` — once, deduplicated on the stored
value, with one WidgetKit reload — so the widget shows Disconnected with a Connect
control. The app never clears the marker: the tunnel's next snapshot flush removes
it (`WidgetReloadGate.publish`), so a real tunnel always wins and ordering stays
with the sole snapshot writer. Until the app next runs, the widget still shows the
last tunnel-written face; tapping it opens the app, which corrects it.

A widget tap is also never acted on without a loaded manager: `OpenRungVpnModule`
leaves the request in the mailbox until both JavaScript is listening and the
manager has loaded, so the placeholder `.invalid` status can never pass for "down"
and let a running country-pinned tunnel be replaced. A failed load (or the
simulator) never delivers; the request expires in the mailbox. The background path
keeps the same rule by loading the profile itself before it reads any status.

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

The simulator cannot load a tunnel manager, so a widget tap there only opens the
app: the request is dropped, since nothing is delivered without a loaded manager,
and `widget_background_connect` is never published. Setting that key by hand in the
simulator's app-group preferences exercises the routing and the fallback (the
intent runs in the app without opening it, withdraws the key, and the next tap
opens the app); a real start needs a device.

## Physical-device checklist

Run on a signed iPhone with the VPN profile already saved once from the app.

- [ ] Add the small widget; it renders the app name, the OpenRung mark, a two-line
      "Not connected" status and CONNECT in the in-app language (change the language in Settings and confirm
      the widget re-renders once; set Persian or Arabic and confirm right-to-left).
- [ ] iOS 17+: tap CONNECT from a disconnected state with the app killed. The app
      does **not** open, the widget shows "Connecting" at once and keeps it while
      the VPN indicator appears, then moves to "Connected" with the automatically
      chosen relay (no country/relay pin) within a few seconds of the tunnel coming
      up. Repeat with the app in the background: its status follows. A tap on the
      status text, not the control, opens the app and starts nothing.
- [ ] iOS 17+: remove the VPN profile in Settings (or install fresh), open the app
      once without connecting, then tap CONNECT on the widget: the app opens and
      asks for consent. After that connect, later taps no longer open it. Without
      opening the app after removing the profile: the first tap returns to CONNECT
      within a few seconds, the second opens the app.
- [ ] While connected the widget shows the relay name with its flag, a running
      timer and a red DISCONNECT control. Tap outside the control: the app opens,
      nothing restarts, the tunnel stays on the same relay.
- [ ] iOS 17+: tap DISCONNECT with the app killed. The app does **not** open, the
      VPN indicator goes away and the widget moves to "Not connected" with CONNECT.
      Repeat with the app open in the background: its status follows.
- [ ] Lock the device with the widget on the Lock Screen's Today view: the relay
      line is redacted.
- [ ] Connect to a chosen country in the app, then tap the widget: the tunnel is not
      switched.
- [ ] Double-tap CONNECT quickly: exactly one tunnel start.
- [ ] Disconnect in the app: widget shows "Not connected" and offers CONNECT again.
- [ ] Press CONNECT in the app and go to the home screen while it is still
      connecting: the widget moves from "Connecting" to "Connected" without the app
      being reopened. Repeat with the app swiped away from the app switcher.
- [ ] With the widget showing a stale face (if one can be produced), open the app:
      the widget is correct as soon as the app is in front.
- [ ] Open `openrung://connect` from Safari on iOS 17+: the app opens and does
      **not** connect (the URL acts only on iOS 16). On an iOS 16 device,
      `openrung://connect?country=JP` and `openrung://connect/x` open the app without
      connecting; plain `openrung://connect` connects.
- [ ] iOS 16 device (if available): tapping the widget opens the app via the URL and
      connects; while connected the tap only opens the app.
- [ ] Kill the app, wait a minute, tap CONNECT: still connects.
- [ ] Watch WidgetKit reloads over one connect/disconnect cycle (Console.app,
      subsystem `com.apple.chronod`): two reloads for connect, two for disconnect (the timer costs none).
