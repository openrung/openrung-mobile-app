import Foundation
import WidgetKit

/// The tunnel process is the one writing connection status while the app is suspended.
/// WidgetCenter is the supported way for an extension to ask for a new timeline; iOS may
/// still defer the reload, so the widget also schedules a coarse fallback.
enum PacketTunnelWidgetReload {
    static func install() {
        WidgetTimelineReloadHook.setReload {
            WidgetCenter.shared.reloadTimelines(ofKind: AppConfig.widgetKind)
        }
    }
}
