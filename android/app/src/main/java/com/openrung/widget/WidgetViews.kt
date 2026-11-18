package com.openrung.widget

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.view.View
import android.widget.RemoteViews
import androidx.core.content.ContextCompat
import com.openrung.MainActivity
import com.openrung.R

/** Builds the widget's [RemoteViews] for one [WidgetDisplay] (layout `widget_connect.xml`). */
object WidgetViews {
    fun build(context: Context, display: WidgetDisplay): RemoteViews {
        val strings = localized(context, display.languageTag)
        val face = display.face
        val views = RemoteViews(context.packageName, R.layout.widget_connect)

        views.setInt(
            android.R.id.background, "setLayoutDirection",
            if (WidgetLanguage.isRightToLeft(display.languageTag)) View.LAYOUT_DIRECTION_RTL else View.LAYOUT_DIRECTION_LTR,
        )
        views.setTextViewText(R.id.widget_app_name, strings.getString(R.string.widget_app_name))

        // One line per line of the translation, so a label wraps only where it says and a long word
        // is scaled down (auto-size) instead of being broken.
        val lines = labelLines(strings, face)
        views.setTextViewText(R.id.widget_status, lines.joinToString("\n"))
        views.setInt(R.id.widget_status, "setMaxLines", lines.size.coerceAtLeast(1))
        views.setTextColor(
            R.id.widget_status,
            ContextCompat.getColor(context, if (face == WidgetFace.CONNECTED) R.color.widget_connected else R.color.widget_green),
        )

        val relay = display.relay.takeIf { face == WidgetFace.CONNECTED }
        views.setViewVisibility(R.id.widget_relay, if (relay != null) View.VISIBLE else View.GONE)
        views.setTextViewText(R.id.widget_relay, relay.orEmpty())

        val since = display.connectedSince.takeIf { face == WidgetFace.CONNECTED }
        if (since != null) {
            // Counts up on its own; no redraws are spent on it.
            views.setChronometer(R.id.widget_timer, since, null, true)
            views.setViewVisibility(R.id.widget_timer, View.VISIBLE)
        } else {
            views.setChronometer(R.id.widget_timer, 0L, null, false)
            views.setViewVisibility(R.id.widget_timer, View.GONE)
        }

        views.setViewVisibility(R.id.widget_connect, if (face.offersConnect) View.VISIBLE else View.GONE)
        views.setViewVisibility(R.id.widget_disconnect, if (face == WidgetFace.CONNECTED) View.VISIBLE else View.GONE)
        val inline = !face.offersConnect && face != WidgetFace.CONNECTED
        views.setViewVisibility(R.id.widget_inline_status, if (inline) View.VISIBLE else View.GONE)
        views.setTextViewText(R.id.widget_connect, strings.getString(R.string.widget_action_connect))
        views.setTextViewText(R.id.widget_disconnect, strings.getString(R.string.widget_action_disconnect))
        views.setTextViewText(R.id.widget_inline_status, lines.joinToString(" "))

        // A tap anywhere but a control opens the app and starts nothing.
        views.setOnClickPendingIntent(android.R.id.background, openApp(context))
        views.setOnClickPendingIntent(
            R.id.widget_connect,
            if (display.connectsInBackground) WidgetActionReceiver.connect(context) else WidgetConnectActivity.pendingIntent(context),
        )
        views.setOnClickPendingIntent(R.id.widget_disconnect, WidgetActionReceiver.disconnect(context))
        return views
    }

    fun labelLines(strings: Context, face: WidgetFace): List<String> {
        val resource = when (face) {
            WidgetFace.DISCONNECTED -> R.string.widget_status_disconnected
            WidgetFace.CONNECTING -> R.string.widget_status_connecting
            WidgetFace.CONNECTED -> R.string.widget_status_connected
            WidgetFace.DISCONNECTING -> R.string.widget_status_disconnecting
            WidgetFace.FAILED -> R.string.widget_status_failed
        }
        return strings.getString(resource).split('\n').map { it.trim() }.filter { it.isNotEmpty() }
    }

    /** [context] with its resources in [tag]'s language, whatever the device language is. */
    fun localized(context: Context, tag: String): Context {
        val configuration = Configuration(context.resources.configuration)
        configuration.setLocale(WidgetLanguage.locale(tag))
        return context.createConfigurationContext(configuration)
    }

    private fun openApp(context: Context): PendingIntent = PendingIntent.getActivity(
        context,
        REQUEST_OPEN_APP,
        Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    private const val REQUEST_OPEN_APP = 9100
}
