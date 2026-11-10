import SwiftUI
import WidgetKit

/// The one OpenRung widget: current tunnel status plus a Connect control that starts a tunnel to an
/// automatically chosen relay through the app's own connect path (see `WidgetConnectHandoff.swift`).
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
    let face: WidgetFace
    let strings: WidgetStrings
}

struct ConnectTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> ConnectEntry {
        ConnectEntry(date: Date(), face: .disconnected, strings: .current())
    }

    func getSnapshot(in context: Context, completion: @escaping (ConnectEntry) -> Void) {
        completion(current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ConnectEntry>) -> Void) {
        let entry = current()
        // The one thing the widget writes: what it is about to show, so the app can tell a reload
        // WidgetKit deferred (budgeted while the app was not in front) from one it honoured.
        if !context.isPreview {
            WidgetSharedState.recordRenderedFace(entry.face)
        }
        // A settled face changes only when someone asks: the tunnel extension when the face
        // changes, the app when the language does or when this face lags the snapshot while it is
        // in the foreground. So no scheduled refresh there (and no budget spent). A transitional
        // face asks to be rebuilt, paced by how long the tunnel has been in it: the tunnel's own
        // request for the next face may be deferred when the app is not in front.
        let delay = WidgetSelfRefresh.delay(for: entry.face, age: WidgetSharedState.age(of: entry.face))
        let policy: TimelineReloadPolicy = delay.map { .after(Date().addingTimeInterval($0)) } ?? .never
        completion(Timeline(entries: [entry], policy: policy))
    }

    private func current() -> ConnectEntry {
        ConnectEntry(
            date: Date(),
            face: WidgetSharedState.currentFace(),
            strings: .current()
        )
    }
}

struct ConnectWidgetView: View {
    let entry: ConnectEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            appName
            Spacer(minLength: 0)
            statusLine
            Spacer(minLength: 0)
            connectControl
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .environment(\.layoutDirection, entry.strings.isRightToLeft ? .rightToLeft : .leftToRight)
        .widgetURL(tapURL)
        .widgetChrome()
    }

    private var appName: some View {
        Text(entry.strings.appName)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(WidgetPalette.dim)
    }

    private var statusLine: some View {
        Text(entry.strings.label(for: entry.face))
            .font(.system(.headline, design: .monospaced))
            .foregroundStyle(entry.face == .connected ? WidgetPalette.connected : WidgetPalette.green)
            .lineLimit(2)
            .minimumScaleFactor(0.7)
    }

    /// iOS 17+: an interactive button whose intent the system performs inside the app.
    /// iOS 16: the same label, with the whole widget carrying the `openrung://connect` URL.
    @ViewBuilder
    private var connectControl: some View {
        if entry.face.offersConnect {
            if #available(iOS 17.0, *) {
                Button(intent: WidgetConnectIntent()) {
                    connectLabel
                }
                .buttonStyle(.plain)
            } else {
                connectLabel
            }
        } else {
            Text(entry.strings.label(for: entry.face))
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(WidgetPalette.dim)
                .frame(maxWidth: .infinity, minHeight: 36)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(WidgetPalette.border, lineWidth: 1)
                )
        }
    }

    private var connectLabel: some View {
        Text(entry.strings.connect)
            .font(.system(.subheadline, design: .monospaced).weight(.semibold))
            .foregroundStyle(WidgetPalette.onGreen)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(WidgetPalette.green, in: RoundedRectangle(cornerRadius: 8))
    }

    /// On iOS 17+ a tap outside the button only opens the app. On iOS 16 the whole widget is the
    /// control, so its URL is the connect request exactly when a Connect control is shown.
    private var tapURL: URL {
        if #available(iOS 17.0, *) {
            return WidgetConnectURL.open
        }
        return entry.face.offersConnect ? WidgetConnectURL.connect : WidgetConnectURL.open
    }
}

/// The app's terminal-green-on-black palette (contract §5).
enum WidgetPalette {
    static let screen = Color(red: 0x03 / 255, green: 0x06 / 255, blue: 0x04 / 255)
    static let green = Color(red: 0x65 / 255, green: 0xF5 / 255, blue: 0x8A / 255)
    static let connected = Color(red: 0xB6 / 255, green: 0xF5 / 255, blue: 0x79 / 255)
    static let dim = Color(red: 0x7D / 255, green: 0xA9 / 255, blue: 0x89 / 255)
    static let border = Color(red: 0x29 / 255, green: 0x4F / 255, blue: 0x35 / 255)
    static let onGreen = Color(red: 0x06 / 255, green: 0x10 / 255, blue: 0x08 / 255)
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
