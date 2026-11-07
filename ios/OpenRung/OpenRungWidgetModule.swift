import Foundation
import React

/// Publishes the in-app language override into the app group so the widget can follow it.
/// Not part of the OpenRungVpn contract. Missing on Android; JavaScript treats it as optional.
@objc(OpenRungWidget)
final class OpenRungWidgetModule: NSObject {
    @objc static func requiresMainQueueSetup() -> Bool { false }

    @objc func setLanguageTag(_ tag: String) {
        guard let store = WidgetAppGroup.store else { return }
        WidgetPreferences.setLanguageTag(tag, store)
        WidgetTimelineReloadHook.reload()
    }
}
