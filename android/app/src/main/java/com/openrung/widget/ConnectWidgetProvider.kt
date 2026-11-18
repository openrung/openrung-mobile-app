package com.openrung.widget

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context

/**
 * The one OpenRung widget (docs/ANDROID_WIDGET.md). Exported only so the launcher can bind it; it
 * acts on nothing but the system's update broadcasts. Taps go to the non-exported
 * [WidgetActionReceiver] and [WidgetConnectActivity], so no other app can start a tunnel through it.
 */
class ConnectWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        OpenRungWidget.start(context)
        OpenRungWidget.render(context, force = true)
    }
}
