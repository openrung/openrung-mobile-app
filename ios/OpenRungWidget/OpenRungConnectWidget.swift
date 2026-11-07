import SwiftUI
import WidgetKit

@main
struct OpenRungWidgets: WidgetBundle {
    var body: some Widget {
        OpenRungConnectWidget()
    }
}

struct OpenRungConnectWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: AppConfig.widgetKind, provider: OpenRungWidgetProvider()) { entry in
            OpenRungConnectWidgetView(model: entry.model)
                .widgetURL(WidgetConnectURL.openApp())
        }
        .configurationDisplayName("OpenRung")
        .description(Text("widget_gallery_description"))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct OpenRungWidgetEntry: TimelineEntry {
    let date: Date
    let model: WidgetViewModel
}

struct OpenRungWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> OpenRungWidgetEntry {
        OpenRungWidgetEntry(date: Date(), model: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (OpenRungWidgetEntry) -> Void) {
        completion(OpenRungWidgetEntry(date: Date(), model: Self.loadModel()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<OpenRungWidgetEntry>) -> Void) {
        let model = Self.loadModel()
        let entry = OpenRungWidgetEntry(date: Date(), model: model)
        // Coarse fallback when a WidgetCenter reload is deferred. Not a live status stream.
        let minutes: TimeInterval = (model.phase == .connecting || model.phase == .disconnecting) ? 5 : 30
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(minutes * 60))))
    }

    private static func loadModel() -> WidgetViewModel {
        guard let store = WidgetAppGroup.store else {
            return WidgetViewModel.load(
                profileReady: false,
                languageTag: "",
                systemLocale: WidgetStrings.systemLanguageTag(),
                snapshot: ConnectionStateSnapshot()
            )
        }
        return WidgetViewModel.load(
            profileReady: WidgetPreferences.isProfileReady(store),
            languageTag: WidgetPreferences.languageTag(store),
            systemLocale: WidgetStrings.systemLanguageTag(),
            snapshot: WidgetConnectionReader.snapshot(from: store)
        )
    }
}

struct OpenRungConnectWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let model: WidgetViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("OpenRung")
                .font(.custom("Menlo", size: 12).weight(.semibold))
                .foregroundStyle(WidgetPalette.green)
                .accessibilityHidden(true)
            Text(model.statusLine)
                .font(.custom("Menlo", size: 16).weight(.medium))
                .foregroundStyle(model.phase == .failed ? WidgetPalette.error : WidgetPalette.body)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .accessibilityHidden(true)
            if family != .systemSmall, let detail = model.detailLine {
                Text(detail)
                    .font(.custom("Menlo", size: 11))
                    .foregroundStyle(WidgetPalette.dim)
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 4)
            action
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.layoutDirection, model.rightToLeft ? .rightToLeft : .leftToRight)
        .widgetBackground()
    }

    @ViewBuilder
    private var action: some View {
        if #available(iOS 17.0, *) {
            Button(intent: ConnectBestRelayIntent()) {
                buttonLabel
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.accessibilityLabel)
        } else {
            // iOS 16 has no interactive widget button. The widget URL opens the app;
            // it does not enqueue a connect.
            buttonLabel
                .accessibilityLabel(model.accessibilityLabel)
                .accessibilityAddTraits(.isButton)
        }
    }

    private var buttonLabel: some View {
        Text(model.buttonTitle)
            .font(.custom("Menlo", size: 13).weight(.bold))
            .foregroundStyle(WidgetPalette.onGreen)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(WidgetPalette.green, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private enum WidgetPalette {
    static let screen = Color(red: 3.0 / 255, green: 6.0 / 255, blue: 4.0 / 255)
    static let green = Color(red: 101.0 / 255, green: 245.0 / 255, blue: 138.0 / 255)
    static let body = Color(red: 216.0 / 255, green: 255.0 / 255, blue: 224.0 / 255)
    static let dim = Color(red: 125.0 / 255, green: 169.0 / 255, blue: 137.0 / 255)
    static let error = Color(red: 1, green: 160.0 / 255, blue: 160.0 / 255)
    static let onGreen = Color(red: 6.0 / 255, green: 16.0 / 255, blue: 8.0 / 255)
}

private extension View {
    @ViewBuilder
    func widgetBackground() -> some View {
        if #available(iOS 17.0, *) {
            containerBackground(WidgetPalette.screen, for: .widget)
        } else {
            padding(12)
                .background(WidgetPalette.screen)
        }
    }
}
