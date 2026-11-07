# iOS home-screen widget

The widget is one button that asks OpenRung to connect to the automatically
selected relay. The host app's deployment target stays iOS 16.0. The button is
interactive on iOS 17 and later. On iOS 16 the same widget opens the app and
does not start a connection.

This was implemented and unit-tested without Xcode or a device. Nothing here
was signed, installed, or run on iOS.

## Why the widget opens the app

`NETunnelProviderManager` and `NEVPNManager` are containing-app APIs. A
WidgetKit extension is an app extension (`APPLICATION_EXTENSION_API_ONLY`) and
cannot load or save the VPN preferences, so it cannot see the saved OpenRung
profile or call `startVPNTunnel()`. There is no public App Intent or
NetworkExtension type that starts a third-party packet tunnel from a widget
process. This project does not invent one.

`AppIntent.openAppWhenRun` (and the later foreground-continuation intents)
bring the host app to the foreground. They do not start the tunnel in the
background. The widget therefore:

1. On iOS 17+, the button runs `ConnectBestRelayIntent` in the widget process,
   which writes one short-lived request into the app group when a VPN profile
   has already been saved.
2. The system opens OpenRung. The same intent is also compiled into the app,
   so if iOS delivers `perform()` there it consumes the request immediately.
   Storing the request also posts a Darwin notification
   (`com.openrung.app.widget-connect`) so an already-running app consumes it
   even when `sceneDidBecomeActive` does not run again. A launch from the
   background or from terminated still consumes the stored request in
   `sceneDidBecomeActive`, with one half-second follow-up if the write lands
   just after that call. Darwin notifications are not replayed, so a
   terminated app depends on the foreground path, not on the notification.
3. `TunnelControl.startAutoBestRelayIfIdle()` loads the real
   `NETunnelProviderManager` and, only when the OS tunnel is idle, calls the
   same configure-and-start path as the in-app Connect button with a nil
   country and a nil relay id. PacketTunnel passes those empty targets to
   connectcore, which already owns relay selection and failover. The widget
   does not probe, does not rank relays, and does not run React Native.

A URL by itself never starts the tunnel. `openrung://open` and
`openrung://connect-auto` are accepted only with an empty path and with no
user, password, port, query, or fragment. A query such as `?relay=` or
`?country=` is ignored. The app starts a connection only after it consumes a
fresh app-group request (`action` `connect-auto`, UUID id, 90 second lifetime,
60 second future-skew allowance). Another app can open the URL and focus
OpenRung; it cannot write the app group, so it cannot choose a relay or start
the VPN.

## What the button shows

The widget reads the app-group connection snapshot and a boolean the app sets
after a VPN profile has been saved. It does not read `NEVPNStatus`.

| Condition | Label | Button | Tap |
|---|---|---|---|
| No saved VPN profile | Setup required | Open | Opens the app. Does not save a profile or show the VPN permission dialog. |
| Disconnected or failed | That status | Connect | Opens the app and requests an automatic connection. |
| Connecting, disconnecting, or connected | That status | Open | Opens the app and still records a request. The app ignores it when the OS tunnel is busy or already up. |

A connected snapshot includes the relay label the tunnel already published.
Failed snapshots prefer the localized `access_denied` / `enrollment_refused`
strings and otherwise show the native error, truncated. The placeholder used
in the widget gallery does not claim a live connection.

The snapshot can stay "connected" if the extension crashes without writing a
terminal state. The app corrects that when it has loaded the manager and the
OS reports the tunnel down, then writes the correction back so the widget can
reload. Until that happens the widget can show a stale connected label. The
tap still asks the app, and the app starts only if the OS tunnel is actually
idle. The widget does not pretend the reload is instant.

Status changes ask WidgetKit to reload the timeline. Log lines do not. iOS
may defer that reload. The timeline also asks for another refresh after 5
minutes while connecting or disconnecting, and after 30 minutes otherwise.
That is a backstop, not a live status stream. The widget process is not
running between reloads.

## What a tap will not do

- It will not start a second tunnel while a connect, disconnect, or
  split-tunnel reapply is in flight, or within 1.5 seconds of one. A manual
  country or relay connect from the app still uses its own path and still
  wins if it arrives while a widget start is waiting.
- It will not disconnect a tunnel that is already up, and it will not switch
  a live manual selection over to automatic.
- It will not connect on iOS 16. The whole widget is a link to
  `openrung://open`.
- It will not read the installation key, WSS tickets, or broker credentials.
  Those stay in the packet tunnel's existing keychain and in the tunnel
  process. The app group holds only the connection snapshot, the profile-ready
  flag, the language tag, and the one connect request.

The in-app language picker is published with `OpenRungWidget.setLanguageTag`
(empty string means the system language). The widget resolves tags with the
same rules as the React Native shell, including Persian and Arabic
right-to-left layout. The add-widget sheet description uses the system
language via `Localizable.strings`. The sheet does not know the in-app
override until the app has published it, and the description string itself
follows the system locale.

## Xcode and provisioning

No signing identity, certificate, or provisioning profile is stored in this
repo. Do not add one.

1. In the Apple Developer portal, register the App ID
   `com.openrung.app.OpenRungWidget` on the same team as `com.openrung.app`.
   Enable the App Groups capability and the existing group
   `group.com.openrung.app`. Add the widget App ID to that group's membership.
   Do not enable Network Extensions on the widget.
2. The host and PacketTunnel App IDs stay as they are (packet-tunnel-provider
   plus the same app group). The project setting `DEVELOPMENT_TEAM` is
   `9VLV9A7KS9`; replace it locally if you use another team. Signing style is
   Automatic. Let Xcode create a development profile that includes the widget.
3. After changing `ios/project.yml`, regenerate with
   `ios/scripts/generate-project.sh` (`xcodegen generate` then `pod install`).
   The widget target is in `project.yml`, so regeneration keeps it. The
   checked-in `project.pbxproj` already contains the target for a build that
   has not regenerated yet.
4. Build and run the `OpenRung` scheme on a physical iPhone. The simulator
   cannot install or start a packet-tunnel profile. Add the widget from the
   Home Screen (search OpenRung). iOS 17 or later is required for the button;
   iOS 16 only opens the app.

The widget extension is embedded in the app's PlugIns directory next to
PacketTunnel. Its deployment target is 16.0, the same as the host. Interactive
controls are gated with `#available(iOS 17, *)`.

## Manual device checks

These were not run here.

- **Foreground host.** App open on Home. Tap the widget. The app stays in
  front and connects with no country and no relay id (the same request as the
  in-app Connect button). The widget moves to connecting, then connected,
  after iOS accepts a timeline reload.
- **Background host.** Leave the app with the Home Screen visible. Tap the
  widget. The app comes forward and connects.
- **Terminated host.** Force-quit OpenRung. Tap the widget. The app launches
  and connects. Repeat once when the phone has just been unlocked.
- **No configuration.** Delete the OpenRung VPN profile in Settings, or use a
  fresh install that has never tapped Connect. The widget says setup is
  required. Tapping it opens the app and does not present the VPN permission
  dialog by itself. Tap Connect in the app, allow the profile, then use the
  widget.
- **VPN permission denied.** Deny the profile prompt. The widget stays on
  setup required and a later tap still only opens the app.
- **Automatic relay.** After a normal connect from the widget, the tunnel's
  own status names the relay it selected. Confirm the saved profile's
  provider configuration has no `target_country` and no `target_relay_id`.
- **Manual selection still works.** Connect to a specific country from the
  map. While that tunnel is up, tap the widget. It must not disconnect or
  switch relays. Disconnect from the app, then connect to a country again.
- **Blocked network or other failure.** Turn on airplane mode, or otherwise
  cause the existing connect path to fail. The widget shows failed and the
  error the tunnel published. It must not stay on connected.
- **Rapid taps.** Tap the widget repeatedly, including while it already says
  connecting. Only one tunnel start runs. The in-app Disconnect during that
  window is not undone by a second widget start.
- **Stale connected label.** If you can stop the tunnel from outside the app
  (VPN settings) without the extension writing disconnected, the widget may
  keep the old label until the app reconciles it or the timeline reloads.
  Tapping it must not start a second tunnel when the OS profile is still
  connected, and must start one when the OS profile is down.
- **iOS 16 device, if you have one.** The widget has no button. Tapping it
  opens the app and does not connect.
- **Language and VoiceOver.** Set the in-app language to Persian or Arabic,
  background the app, and reload the widget. Status and button copy follow
  that language and lay out right to left. VoiceOver reads the status and the
  action together.
