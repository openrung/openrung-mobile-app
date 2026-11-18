package com.openrung.widget

import android.app.Activity
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Bundle
import com.openrung.MainActivity

/**
 * The widget's Connect before VPN consent is granted (first use, or another VPN app took over):
 * an invisible, non-exported activity that asks for consent, starts the widget connect once it is
 * granted, and opens the app either way. Not exported, so no other app can start a tunnel with it.
 */
class WidgetConnectActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState != null) return // Already waiting on the consent dialog.
        val consent = VpnService.prepare(this)
        if (consent == null) {
            finishWith(connect = true)
            return
        }
        try {
            startActivityForResult(consent, REQUEST_CONSENT)
        } catch (error: RuntimeException) {
            finishWith(connect = false)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_CONSENT) finishWith(connect = resultCode == RESULT_OK)
    }

    private fun finishWith(connect: Boolean) {
        if (connect) OpenRungWidget.requestConnect(applicationContext)
        startActivity(Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        finish()
    }

    companion object {
        private const val REQUEST_CONSENT = 9110

        fun pendingIntent(context: Context): PendingIntent = PendingIntent.getActivity(
            context,
            9103,
            Intent(context, WidgetConnectActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }
}
