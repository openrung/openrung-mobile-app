package com.openrung.widget

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * The widget's background controls: Connect once VPN consent is granted, and Disconnect. Not
 * exported, so only the widget's own PendingIntents reach it. A widget tap lets the app start its
 * foreground VPN service from the background.
 */
class WidgetActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        OpenRungWidget.start(context)
        when (intent.action) {
            ACTION_CONNECT -> OpenRungWidget.requestConnect(context)
            ACTION_DISCONNECT -> OpenRungWidget.requestDisconnect(context)
        }
    }

    companion object {
        private const val ACTION_CONNECT = "com.openrung.widget.action.CONNECT"
        private const val ACTION_DISCONNECT = "com.openrung.widget.action.DISCONNECT"

        fun connect(context: Context): PendingIntent = broadcast(context, ACTION_CONNECT, 9101)

        fun disconnect(context: Context): PendingIntent = broadcast(context, ACTION_DISCONNECT, 9102)

        private fun broadcast(context: Context, action: String, requestCode: Int): PendingIntent =
            PendingIntent.getBroadcast(
                context,
                requestCode,
                Intent(context, WidgetActionReceiver::class.java).setAction(action),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
    }
}
