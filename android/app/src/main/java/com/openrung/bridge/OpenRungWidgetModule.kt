package com.openrung.bridge

import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.UiThreadUtil
import com.openrung.widget.OpenRungWidget

/**
 * `OpenRungWidget` bridge module (docs/CONTRACT.md §3): mirrors the in-app language selection
 * ('' = system) for the home-screen widget, which redraws only when it changed.
 */
class OpenRungWidgetModule(
    private val reactContext: ReactApplicationContext,
) : ReactContextBaseJavaModule(reactContext) {
    override fun getName(): String = "OpenRungWidget"

    @ReactMethod
    fun setLanguageTag(tag: String, promise: Promise) {
        UiThreadUtil.runOnUiThread {
            try {
                OpenRungWidget.setLanguageTag(reactContext.applicationContext, tag)
                promise.resolve(null)
            } catch (error: Throwable) {
                promise.reject("E_WIDGET_LANGUAGE", error)
            }
        }
    }
}
