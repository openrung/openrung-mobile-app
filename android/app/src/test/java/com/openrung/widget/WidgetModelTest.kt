package com.openrung.widget

import com.openrung.model.RecentNode
import com.openrung.state.ConnectionStatus
import com.openrung.state.OpenRungUiState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pure widget model: faces, relay line and language resolution (paired with the iOS widget's rules). */
class WidgetModelTest {
    @Test fun `statuses map to faces while a tunnel owns the engine`() {
        val expected = mapOf(
            ConnectionStatus.DISCONNECTED to WidgetFace.DISCONNECTED,
            ConnectionStatus.PREPARING to WidgetFace.CONNECTING,
            ConnectionStatus.CONNECTING to WidgetFace.CONNECTING,
            ConnectionStatus.CONNECTED to WidgetFace.CONNECTED,
            ConnectionStatus.DISCONNECTING to WidgetFace.DISCONNECTING,
            ConnectionStatus.FAILED to WidgetFace.FAILED,
        )
        for ((status, face) in expected) {
            assertEquals(status.name, face, WidgetFace.of(status, tunnelActive = true, pendingConnect = false))
        }
    }

    @Test fun `a live status left by a dead process shows disconnected`() {
        for (status in listOf(ConnectionStatus.PREPARING, ConnectionStatus.CONNECTING, ConnectionStatus.CONNECTED, ConnectionStatus.DISCONNECTING)) {
            assertEquals(status.name, WidgetFace.DISCONNECTED, WidgetFace.of(status, tunnelActive = false, pendingConnect = false))
        }
        assertEquals(WidgetFace.FAILED, WidgetFace.of(ConnectionStatus.FAILED, tunnelActive = false, pendingConnect = false))
    }

    @Test fun `a pending widget connect shows connecting only over a connect face`() {
        assertEquals(WidgetFace.CONNECTING, WidgetFace.of(ConnectionStatus.DISCONNECTED, false, pendingConnect = true))
        assertEquals(WidgetFace.CONNECTING, WidgetFace.of(ConnectionStatus.FAILED, false, pendingConnect = true))
        assertEquals(WidgetFace.CONNECTED, WidgetFace.of(ConnectionStatus.CONNECTED, true, pendingConnect = true))
        assertEquals(WidgetFace.DISCONNECTING, WidgetFace.of(ConnectionStatus.DISCONNECTING, true, pendingConnect = true))
    }

    @Test fun `only disconnected and failed offer connect`() {
        assertEquals(setOf(WidgetFace.DISCONNECTED, WidgetFace.FAILED), WidgetFace.values().filter { it.offersConnect }.toSet())
    }

    private fun recent(name: String, label: String, country: String = "JP") =
        RecentNode(countryCode = country, relayId = "relay_1", label = label, relayName = name, latitude = 0.0, longitude = 0.0)

    @Test fun `relay line carries the flag only when the head recent is the connected relay`() {
        val connected = OpenRungUiState(
            status = ConnectionStatus.CONNECTED, relayName = "falcon", relayLabel = "Tokyo, Japan",
            recentRegions = listOf(recent("falcon", "Tokyo, Japan")),
        )
        assertEquals("falcon 🇯🇵", WidgetRelay.line(connected))
        // Same name, different place: names are not unique.
        assertEquals("falcon", WidgetRelay.line(connected.copy(recentRegions = listOf(recent("falcon", "Osaka, Japan")))))
        // The relay had no location, so the head is the previous connection.
        assertEquals("falcon", WidgetRelay.line(connected.copy(recentRegions = listOf(recent("hawk", "Tokyo, Japan")))))
        assertEquals("falcon", WidgetRelay.line(connected.copy(recentRegions = emptyList())))
        assertNull(WidgetRelay.line(connected.copy(relayName = null)))
        assertNull(WidgetRelay.line(connected.copy(relayName = " ")))
    }

    @Test fun `flags come only from two-letter codes`() {
        assertEquals("🇩🇪", WidgetRelay.flag("de"))
        assertNull(WidgetRelay.flag(""))
        assertNull(WidgetRelay.flag("DEU"))
        assertNull(WidgetRelay.flag("1A"))
    }

    @Test fun `language resolves like the app and the iOS widget`() {
        assertEquals("fa", WidgetLanguage.resolve("fa", "en-US"))
        assertEquals("en", WidgetLanguage.resolve("", null))
        assertEquals("ru", WidgetLanguage.resolve("", "ru-RU"))
        assertEquals("zh-TW", WidgetLanguage.resolve("", "zh-Hant-HK"))
        assertEquals("zh-TW", WidgetLanguage.resolve("", "zh-MO"))
        assertEquals("zh-TW", WidgetLanguage.resolve("", "zh-TW"))
        assertEquals("zh-CN", WidgetLanguage.resolve("", "zh-Hans-SG"))
        assertEquals("zh-CN", WidgetLanguage.resolve("", "zh"))
        assertEquals("en", WidgetLanguage.resolve("", "pt-BR"))
        assertEquals("my", WidgetLanguage.resolve("  ", "my-MM"))
    }

    @Test fun `persian and arabic lay out right to left`() {
        assertTrue(WidgetLanguage.isRightToLeft("fa"))
        assertTrue(WidgetLanguage.isRightToLeft("ar"))
        assertFalse(WidgetLanguage.isRightToLeft("en"))
        assertEquals(WidgetLanguage.TAGS.size, WidgetLanguage.TAGS.map(WidgetLanguage::locale).toSet().size)
    }
}
