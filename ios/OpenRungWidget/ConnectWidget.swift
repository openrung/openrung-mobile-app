import SwiftUI
import WidgetKit

/// The one OpenRung widget: current tunnel status, a Connect control that starts a tunnel to an
/// automatically chosen relay through the app (see `WidgetConnectHandoff.swift`; without opening
/// it once a VPN profile is saved) and, while connected, the relay, how long the tunnel has been
/// up and a Disconnect control that asks the tunnel to end itself (`WidgetDisconnectIntent`).
/// Small family only; the extension holds no VPN entitlement and never touches the tunnel.
struct ConnectWidget: Widget {
    var body: some WidgetConfiguration {
        let strings = WidgetStrings.current()
        return StaticConfiguration(kind: WidgetSharedState.widgetKind, provider: ConnectTimelineProvider()) { entry in
            ConnectWidgetView(entry: entry)
        }
        .configurationDisplayName(strings.widgetName)
        .description(strings.widgetDescription)
        .supportedFamilies([.systemSmall])
    }
}

struct ConnectEntry: TimelineEntry {
    let date: Date
    let display: WidgetDisplay
    let strings: WidgetStrings
    /// Whether Connect can run without opening the app (`WidgetBackgroundConnect`).
    var connectsInBackground = false

    var face: WidgetFace { display.face }
}

struct ConnectTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> ConnectEntry {
        ConnectEntry(date: Date(), display: WidgetDisplay(face: .disconnected), strings: .current())
    }

    func getSnapshot(in context: Context, completion: @escaping (ConnectEntry) -> Void) {
        completion(current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ConnectEntry>) -> Void) {
        let entries = entries(from: Date())
        let settled = entries[entries.count - 1]
        // What the widget is about to show, so the app can tell a reload WidgetKit deferred
        // (budgeted while the app was not in front) from one it honoured.
        if !context.isPreview {
            WidgetSharedState.recordRenderedFace(settled.face)
        }
        // A settled face changes only when someone asks: the tunnel extension when what is shown
        // changes, the app when the language does or when this face lags the snapshot while it is
        // in the foreground. So no scheduled refresh there (and no budget spent; the connected
        // timer counts on its own). A transitional face asks to be rebuilt, paced by how long it
        // has lasted: the tunnel's own request for the next face may be deferred when the app is
        // not in front.
        let age = settled.display.since.map { settled.date.timeIntervalSince($0) }
        let delay = WidgetSelfRefresh.delay(for: settled.face, age: age)
        let policy: TimelineReloadPolicy = delay.map { .after(settled.date.addingTimeInterval($0)) } ?? .never
        completion(Timeline(entries: entries, policy: policy))
    }

    private func current() -> ConnectEntry {
        entries(from: Date())[0]
    }

    /// Usually one entry. A Disconnect tap the tunnel has not answered adds a second, dated when
    /// the request goes stale, so the widget leaves "disconnecting" then without needing a reload.
    private func entries(from now: Date) -> [ConnectEntry] {
        let strings = WidgetStrings.current()
        let connectsInBackground = WidgetBackgroundConnect.shared.isAvailable
        return WidgetSharedState.timelineDisplays(now: now) { WidgetSharedState.currentDisplay(now: $0) }
            .map {
                ConnectEntry(
                    date: $0.date, display: $0.display, strings: strings,
                    connectsInBackground: connectsInBackground
                )
            }
    }
}

struct ConnectWidgetView: View {
    let entry: ConnectEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .environment(\.layoutDirection, entry.strings.isRightToLeft ? .rightToLeft : .leftToRight)
        .widgetURL(tapURL)
        .widgetChrome()
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(entry.strings.appName)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(WidgetPalette.dim)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
            WidgetMark()
        }
    }

    /// Everything under the header. Where Connect runs in the background the control is a toggle,
    /// not a button: the system draws a toggle's other side the moment it is tapped and keeps it
    /// until the widget is rebuilt, which is only once the app has run the intent and the connect
    /// has an outcome. That other side is the connecting face, status and all, so the toggle draws
    /// the status too. It draws it above itself, outside its own frame: only the control is the
    /// toggle's to be tapped, and a tap on the status opens the app like any other tap.
    @ViewBuilder
    private var content: some View {
        if #available(iOS 17.0, *), entry.face.offersConnect, entry.connectsInBackground {
            GeometryReader { proxy in
                let room = max(0, proxy.size.height - Self.controlHeight - Self.spacing)
                Toggle(isOn: false, intent: WidgetBackgroundConnectIntent()) {
                    connectLabel
                }
                .toggleStyle(PendingToggleStyle(pending: inlineStatus(for: .connecting)) { pending in
                    status(for: pending ? .connecting : entry.face)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: room)
                        .alignmentGuide(.top) { $0[.bottom] + Self.spacing }
                })
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        } else {
            panel(face: entry.face) { control }
        }
    }

    private static let spacing: CGFloat = 4
    /// The height of the Connect control and of the inline status that stands in for it.
    private static let controlHeight: CGFloat = 36

    private func panel<Control: View>(face: WidgetFace, @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            Spacer(minLength: 0)
            status(for: face)
            Spacer(minLength: 0)
            control()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// The status label, then (connected only) the relay and how long the tunnel has been up.
    private func status(for face: WidgetFace) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // One Text per line: a label wraps only where its translation says, and a long word
            // is scaled down instead of being broken mid-word.
            ForEach(Array(entry.strings.labelLines(for: face).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(.headline, design: .monospaced))
                    .foregroundStyle(face == .connected ? WidgetPalette.connected : WidgetPalette.green)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            if face == .connected {
                if let relay = entry.display.relay {
                    Text(relay.flag.map { "\(relay.name) \($0)" } ?? relay.name)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(WidgetPalette.green)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        // Where the tunnel exits is not for a locked screen.
                        .privacySensitive()
                }
                if let since = entry.display.since, since <= entry.date {
                    // Counts up on its own; no timeline entries or reloads are spent on it.
                    Text(since, style: .timer)
                        .font(.system(.caption, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(WidgetPalette.dim)
                        .lineLimit(1)
                        .multilineTextAlignment(.leading)
                }
            }
        }
    }

    /// Disconnected or failed: Connect. On iOS 17+ before the app has a saved VPN profile it is a
    /// button whose intent opens the app (with one, `content` draws the toggle instead); on iOS 16
    /// the same label is shown and the whole widget carries the `openrung://connect` URL.
    /// Connected: Disconnect, iOS 17+ only (a button is the only thing a widget can offer that
    /// does not open the app). In between: the face, restated where the control will be.
    @ViewBuilder
    private var control: some View {
        if entry.face.offersConnect {
            if #available(iOS 17.0, *) {
                Button(intent: WidgetConnectIntent()) {
                    connectLabel
                }
                .buttonStyle(.plain)
            } else {
                connectLabel
            }
        } else if entry.face == .connected {
            if #available(iOS 17.0, *) {
                Button(intent: WidgetDisconnectIntent()) {
                    disconnectLabel
                }
                .buttonStyle(.plain)
            }
        } else {
            inlineStatus(for: entry.face)
        }
    }

    private func inlineStatus(for face: WidgetFace) -> some View {
        Text(entry.strings.inlineLabel(for: face))
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(WidgetPalette.dim)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: Self.controlHeight, maxHeight: Self.controlHeight)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(WidgetPalette.border, lineWidth: 1)
            )
    }

    private var connectLabel: some View {
        Text(entry.strings.connect)
            .font(.system(.subheadline, design: .monospaced).weight(.semibold))
            .foregroundStyle(WidgetPalette.onGreen)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: Self.controlHeight, maxHeight: Self.controlHeight)
            .background(WidgetPalette.green, in: RoundedRectangle(cornerRadius: 8))
    }

    private var disconnectLabel: some View {
        Text(entry.strings.disconnect)
            .font(.system(.footnote, design: .monospaced).weight(.semibold))
            .foregroundStyle(WidgetPalette.onRed)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(WidgetPalette.red, in: RoundedRectangle(cornerRadius: 8))
    }

    /// On iOS 17+ a tap outside a button only opens the app. On iOS 16 the whole widget is the
    /// control, so its URL is the connect request exactly when a Connect control is shown.
    private var tapURL: URL {
        if #available(iOS 17.0, *) {
            return WidgetConnectURL.open
        }
        return entry.face.offersConnect ? WidgetConnectURL.connect : WidgetConnectURL.open
    }
}

/// Shows `pending` in place of the label from the tap until the widget is rebuilt, and `status`
/// (told whether the tap has happened) above it, outside the toggle's frame.
private struct PendingToggleStyle<Pending: View, Status: View>: ToggleStyle {
    let pending: Pending
    @ViewBuilder let status: (Bool) -> Status

    func makeBody(configuration: Configuration) -> some View {
        control(configuration)
            .overlay(alignment: .top) {
                status(configuration.isOn).allowsHitTesting(false)
            }
    }

    @ViewBuilder
    private func control(_ configuration: Configuration) -> some View {
        if configuration.isOn {
            pending
        } else {
            configuration.label
        }
    }
}

/// The OpenRung mark, kept in its own colours when the home screen tints widgets.
private struct WidgetMark: View {
    var body: some View {
        image
            .aspectRatio(contentMode: .fit)
            .frame(width: 20, height: 20)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var image: some View {
        let mark = Image("OpenRungMark").resizable().interpolation(.high)
        if #available(iOS 18.0, *) {
            mark.widgetAccentedRenderingMode(.fullColor)
        } else {
            mark
        }
    }
}

/// The app's terminal-green-on-black palette (contract §5), plus the one red of the Disconnect
/// control.
enum WidgetPalette {
    static let screen = Color(red: 0x03 / 255, green: 0x06 / 255, blue: 0x04 / 255)
    static let green = Color(red: 0x65 / 255, green: 0xF5 / 255, blue: 0x8A / 255)
    static let connected = Color(red: 0xB6 / 255, green: 0xF5 / 255, blue: 0x79 / 255)
    static let dim = Color(red: 0x7D / 255, green: 0xA9 / 255, blue: 0x89 / 255)
    static let border = Color(red: 0x29 / 255, green: 0x4F / 255, blue: 0x35 / 255)
    static let onGreen = Color(red: 0x06 / 255, green: 0x10 / 255, blue: 0x08 / 255)
    static let red = Color(red: 0xE5 / 255, green: 0x48 / 255, blue: 0x4D / 255)
    static let onRed = Color(red: 0xFF / 255, green: 0xF4 / 255, blue: 0xF4 / 255)
}

private extension View {
    /// iOS 17 requires `containerBackground` and supplies content margins; iOS 16 gets both by hand.
    @ViewBuilder
    func widgetChrome() -> some View {
        if #available(iOS 17.0, *) {
            containerBackground(for: .widget) { WidgetPalette.screen }
        } else {
            padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(WidgetPalette.screen)
        }
    }
}
