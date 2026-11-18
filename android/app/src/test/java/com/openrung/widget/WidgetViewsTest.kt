package com.openrung.widget

import android.app.Application
import android.view.View
import android.widget.FrameLayout
import android.widget.TextView
import com.openrung.R
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/** The widget's RemoteViews, applied the way a launcher would. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class WidgetViewsTest {
    private val context = RuntimeEnvironment.getApplication()

    private fun render(display: WidgetDisplay): View =
        WidgetViews.build(context, display).apply(context, FrameLayout(context))

    private fun View.text(id: Int) = findViewById<TextView>(id).text.toString()
    private fun View.visible(id: Int) = findViewById<View>(id).visibility == View.VISIBLE

    @Test fun `disconnected offers connect under the two-line label`() {
        val view = render(WidgetDisplay(WidgetFace.DISCONNECTED))
        assertEquals("OpenRung", view.text(R.id.widget_app_name))
        assertEquals("Not\nconnected", view.text(R.id.widget_status))
        assertEquals("CONNECT", view.text(R.id.widget_connect))
        assertEquals(listOf(true, false, false), listOf(R.id.widget_connect, R.id.widget_disconnect, R.id.widget_inline_status).map { view.visible(it) })
        assertEquals(listOf(false, false), listOf(R.id.widget_relay, R.id.widget_timer).map { view.visible(it) })
    }

    @Test fun `connected shows relay timer and disconnect`() {
        val view = render(WidgetDisplay(WidgetFace.CONNECTED, relay = "falcon 🇯🇵", connectedSince = 1_000L))
        assertEquals("Connected", view.text(R.id.widget_status))
        assertEquals("falcon 🇯🇵", view.text(R.id.widget_relay))
        assertEquals("DISCONNECT", view.text(R.id.widget_disconnect))
        assertEquals(listOf(false, true, false), listOf(R.id.widget_connect, R.id.widget_disconnect, R.id.widget_inline_status).map { view.visible(it) })
        assertEquals(listOf(true, true), listOf(R.id.widget_relay, R.id.widget_timer).map { view.visible(it) })
    }

    @Test fun `transitional faces restate themselves where the control goes`() {
        for ((face, label) in listOf(WidgetFace.CONNECTING to "Connecting", WidgetFace.DISCONNECTING to "Disconnecting")) {
            val view = render(WidgetDisplay(face, relay = "ignored", connectedSince = 1L))
            assertEquals(label, view.text(R.id.widget_inline_status))
            assertEquals(listOf(false, false, true), listOf(R.id.widget_connect, R.id.widget_disconnect, R.id.widget_inline_status).map { view.visible(it) })
            assertEquals(listOf(false, false), listOf(R.id.widget_relay, R.id.widget_timer).map { view.visible(it) })
        }
    }

    @Test fun `failed offers connect again`() {
        val view = render(WidgetDisplay(WidgetFace.FAILED))
        assertEquals("Failed", view.text(R.id.widget_status))
        assertEquals(true, view.visible(R.id.widget_connect))
    }

    @Test fun `the in-app language wins over the device and sets direction`() {
        val persian = render(WidgetDisplay(WidgetFace.DISCONNECTED, languageTag = "fa"))
        assertEquals("اتصال", persian.text(R.id.widget_connect))
        assertEquals("متصل\nنیست", persian.text(R.id.widget_status))
        assertEquals(View.LAYOUT_DIRECTION_RTL, persian.layoutDirection)
        val traditional = render(WidgetDisplay(WidgetFace.CONNECTED, languageTag = "zh-TW"))
        assertEquals(View.LAYOUT_DIRECTION_LTR, traditional.layoutDirection)
        assertEquals(
            WidgetViews.localized(context, "zh-TW").getString(R.string.widget_status_connected),
            traditional.text(R.id.widget_status),
        )
    }
}
