# Android home-screen widget

One app widget (`ConnectWidgetProvider`, 2×2 by default and resizable) that behaves and
looks like the [iOS widget](IOS_WIDGET.md). It shows the tunnel's current status and a
Connect control. A tap starts a tunnel to an **automatically chosen relay** without
opening the app, once the app has VPN consent. The widget never selects a relay or
talks to the broker.

While connected it also shows the relay's display name with its country flag, how long
the tunnel has been up and a Disconnect control that ends the tunnel **without opening
the app**. The OpenRung mark sits in the top trailing corner. A tap anywhere but a
control opens the app and starts nothing.

Code lives in `android/app/src/main/java/com/openrung/widget/`. The layout is
`res/layout/widget_connect.xml` and the provider info is `res/xml/widget_connect_info.xml`.

## Why it is simpler than the iOS widget

The tunnel runs in the app's own process (`OpenRungVpnService` has no `android:process`),
and Android does not budget widget updates. So:

- The widget follows `OpenRungStatusStore` directly. `OpenRungWidget.start`, called from
  `MainApplication.onCreate`, collects the store's status, relay and head recent, and
  redraws placed widgets only when what they show changes. Log lines never reach it.
  Nothing like the iOS reload gate, self-refresh, render catch-up or stale-tunnel marker
  is needed.
- Disconnect is an ordinary `startService(disconnectIntent)` from the widget's receiver.
  There is no request key or cross-process notification.
- The connected timer is a `Chronometer` based on `SystemClock.elapsedRealtime()` when the
  widget first saw the connected face. It counts on its own and costs no redraws.

## Faces

`WidgetFace.of(status, tunnelActive, pendingConnect)`:

| Store status | Face | Control |
| --- | --- | --- |
| `disconnected` | Disconnected ("Not connected") | CONNECT |
| `preparing`, `connecting` | Connecting | inline status |
| `connected` | Connected, relay with flag, timer | DISCONNECT |
| `disconnecting` | Disconnecting | inline status |
| `failed` | Failed | CONNECT |

A live status with no engine owner in this process (`ConnectcoreProcessHost.isActive`
false) was persisted by a process that has died, so it shows Disconnected. After a
widget Connect, the widget shows Connecting from the tap until the store status changes,
for at most 10 s (`PENDING_CONNECT_MS`).

The flag is shown only when the head of the recents is the connected relay: both its
relay name and its label match the store's. This is the iOS rule.

## Connect

The CONNECT control's target is chosen when the widget is drawn:

- **Consent granted** (`VpnService.prepare` returns null): a broadcast to the
  non-exported `WidgetActionReceiver`. It calls `OpenRungWidget.requestConnect`, which
  starts the foreground VPN service with `connectIntent(DEFAULT_BROKER_URL,
  onlyIfIdle = true)`: no country, no relay, so connectcore chooses. A widget tap
  allows the app to start a foreground service from the background. If the system
  refuses anyway, the widget falls back to the next path for later taps.
- **No consent** (first use, another VPN app took over, or a refused background start):
  the non-exported, invisible `WidgetConnectActivity`. It asks for consent, makes the
  same connect when consent is granted, and opens the app either way. If consent was
  revoked after the widget was drawn, the first tap only redraws the widget, and the
  next tap takes this path.

Either way the connect uses the split-tunnel settings the app last persisted
(`SplitTunnelStore`). The JavaScript `prepareAndConnect` is not involved, and Android
never emits `openrungConnectRequested`.

**A widget tap never replaces a tunnel.** `requestConnect` acts only on a Connect face.
The service re-checks on the engine queue: an `onlyIfIdle` connect is dropped when any
service owns the engine. This covers a tunnel that is connecting, connected or pinned to
a chosen country, a double tap, and a race with an in-app connect queued just before.
A dropped connect restores the notification text and hands its start id to the owner,
so the service can still stop.

Only the provider is exported, for the launcher, and it acts on nothing but the
system's update broadcasts. The receiver and the activity are not exported, so no other
app can start a tunnel through the widget.

## Disconnect

The DISCONNECT control broadcasts to `WidgetActionReceiver`, which sends
`disconnectIntent` when a service owns the engine. Otherwise it only redraws the widget.
The store then moves through `disconnecting` to `disconnected` and the widget follows.

## Language

The widget renders in the in-app language. `OpenRungWidgetModule` (`OpenRungWidget`,
`setLanguageTag(tag)`) stores the selection (`''` = system) in the `openrung_widget`
preferences and redraws when it changed. `WidgetLanguage.resolve` ports the app's
resolution: the stored tag, then the device language, then English. `zh-Hant`, TW, HK and
MO resolve to `zh-TW`. Strings come from a configuration context in that locale. Persian
and Arabic set the root's layout direction to right-to-left.

`res/values*/widget_strings.xml` is rendered from `src/i18n/strings/*.ts` by
`npm run widget:strings`, alongside the iOS table. `__tests__/core/widgetStrings.test.ts`
fails when either drifts. The widget picker's name and description use the same
resources in the device language.

## Not carried over from iOS

- **Lock-screen redaction.** Phones show no widgets on the lock screen, so nothing hides
  the relay line.
- **Exact geometry.** Launchers choose cell sizes. Android 12+ uses the launcher's corner
  radius (`system_app_widget_background_radius`).
- **A widget left stale by a killed process.** If Android kills the app (and with it the
  tunnel), the sticky service restart reports Disconnected and the widget follows. After
  a force-stop, the widget keeps its last face until the app process runs again: any tap
  starts it, and the first draw is correct.

## Local checks

```sh
npm run widget:strings
npm test -- --ci --runInBand __tests__/core/widgetStrings.test.ts
cd android && ./gradlew --no-daemon :app:testDebugUnitTest --tests 'com.openrung.widget.*' --tests 'com.openrung.vpn.EngineProcessHostTest'
```

## Device checklist

Run on a signed build with VPN consent granted once from the app.

- [ ] Add the widget from the picker: the preview and the placed widget show the app
      name, the mark, a two-line "Not connected" and CONNECT. Change the in-app language
      and confirm the widget follows. Set Persian or Arabic and confirm right-to-left.
- [ ] Tap CONNECT with the app swiped away. The app does **not** open. The widget shows
      "Connecting" at once, then "Connected" with the relay, its flag and a running timer
      (no country or relay pin).
- [ ] Tap DISCONNECT with the app swiped away. The app does not open, the VPN key icon goes
      away and the widget returns to "Not connected" with CONNECT.
- [ ] Tap outside the controls in each state: the app opens and nothing starts or stops.
- [ ] Connect to a chosen country in the app, then tap the widget's body: the tunnel is
      not switched. Double-tap CONNECT quickly: exactly one tunnel start.
- [ ] Revoke consent (connect another VPN app, or clear consent in Settings), then tap
      CONNECT: the consent dialog appears over the home screen. Accept: the tunnel starts
      and the app opens. Decline: the app opens and nothing starts.
- [ ] Fresh install with the widget placed before ever opening the app: tap CONNECT,
      grant consent, and the tunnel starts.
- [ ] Disconnect and connect from the app and the notification: the widget follows each
      change.
- [ ] Force-stop the app while connected, then open it: the widget shows "Not connected".
