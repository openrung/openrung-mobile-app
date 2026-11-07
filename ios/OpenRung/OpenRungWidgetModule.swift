import Foundation
import React
import WidgetKit

/// iOS-only companion module of the home-screen widget (contract §3). It publishes the in-app
/// language tag under the widget's own app-group key so the widget renders in the language chosen
/// in Settings, and asks WidgetKit to re-render only when that tag actually changed. Deliberately
/// separate from `OpenRungVpn`, like the Android-only modules: Android has no counterpart.
@objc(OpenRungWidget)
final class OpenRungWidgetModule: NSObject {
    @objc static func requiresMainQueueSetup() -> Bool { false }

    /// `tag` is the stored selection: '' = follow the system language, else a supported BCP-47 tag.
    @objc(setLanguageTag:resolver:rejecter:)
    func setLanguageTag(
        _ tag: String,
        resolver resolve: RCTPromiseResolveBlock,
        rejecter reject: RCTPromiseRejectBlock
    ) {
        let defaults = WidgetSharedState.defaults
        let stored = defaults?.string(forKey: WidgetSharedState.languageTagKey) ?? ""
        if stored != tag {
            defaults?.set(tag, forKey: WidgetSharedState.languageTagKey)
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetSharedState.widgetKind)
        }
        resolve(nil)
    }
}
