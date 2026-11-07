import Foundation
import WidgetKit

enum AppWidgetReload {
    static func install() {
        WidgetTimelineReloadHook.setReload {
            WidgetCenter.shared.reloadTimelines(ofKind: AppConfig.widgetKind)
        }
    }
}
