package com.openrung.widget

import com.openrung.state.ConnectionStatus
import com.openrung.state.OpenRungUiState
import java.util.Locale

/** What the widget shows; preparing and connecting share one face, as on iOS. */
enum class WidgetFace {
    DISCONNECTED, CONNECTING, CONNECTED, DISCONNECTING, FAILED;

    /** Faces whose control is Connect. */
    val offersConnect: Boolean get() = this == DISCONNECTED || this == FAILED

    companion object {
        /**
         * [tunnelActive] is whether a service owns the engine in this process. The tunnel lives in
         * the app's process, so a live status without an owner was persisted by a process that has
         * since died: the widget shows Disconnected and offers Connect. [pendingConnect] is a widget
         * Connect the engine has not answered yet, shown as Connecting from the tap on.
         */
        fun of(status: ConnectionStatus, tunnelActive: Boolean, pendingConnect: Boolean): WidgetFace {
            val face = when (status) {
                ConnectionStatus.DISCONNECTED -> DISCONNECTED
                ConnectionStatus.PREPARING, ConnectionStatus.CONNECTING -> CONNECTING
                ConnectionStatus.CONNECTED -> CONNECTED
                ConnectionStatus.DISCONNECTING -> DISCONNECTING
                ConnectionStatus.FAILED -> FAILED
            }
            val settled = if (!tunnelActive && !face.offersConnect) DISCONNECTED else face
            return if (pendingConnect && settled.offersConnect) CONNECTING else settled
        }
    }
}

/** Everything a render depends on; the widget is redrawn only when this changes. */
data class WidgetDisplay(
    val face: WidgetFace,
    /** Connected face only: the relay's display name, with its flag when known. */
    val relay: String? = null,
    /** Connected face only: `SystemClock.elapsedRealtime()` when the tunnel entered it. */
    val connectedSince: Long? = null,
    /** One of [WidgetLanguage.TAGS]. */
    val languageTag: String = "en",
    /** Whether Connect can start the tunnel without opening the app (VPN consent granted). */
    val connectsInBackground: Boolean = false,
)

object WidgetRelay {
    /**
     * The connected relay's name, followed by its country flag when the head of the recents is the
     * connected relay: both its relay name and its label match, since a relay without a location
     * adds no recent and relay names are not unique (the iOS widget's rule).
     */
    fun line(state: OpenRungUiState): String? {
        val name = state.relayName?.takeIf { it.isNotBlank() } ?: return null
        val head = state.recentRegions.firstOrNull()
        val flag = head
            ?.takeIf { it.relayName == name && it.label == state.relayLabel }
            ?.let { flag(it.countryCode) }
        return if (flag == null) name else "$name $flag"
    }

    /** Regional-indicator flag for a two-letter country code; null for anything else. */
    fun flag(countryCode: String): String? {
        val code = countryCode.trim().uppercase(Locale.ROOT)
        if (code.length != 2 || code.any { it !in 'A'..'Z' }) return null
        return code.map { String(Character.toChars(0x1F1E6 + (it - 'A'))) }.joinToString("")
    }
}

/** Port of `resolveLanguage` (src/i18n/index.tsx) and the iOS widget's `WidgetStrings.resolve`. */
object WidgetLanguage {
    /** `WIDGET_TAGS` order (src/i18n/widgetStrings.ts). */
    val TAGS = listOf("en", "zh-CN", "zh-TW", "fa", "ru", "ar", "tr", "vi", "my")
    private val RIGHT_TO_LEFT = setOf("fa", "ar")

    /** The in-app selection first ('' = system), then the device language, then English. */
    fun resolve(storedTag: String, deviceTag: String?): String {
        val stored = storedTag.trim()
        val requested = stored.ifEmpty { deviceTag ?: "en" }
        val lower = requested.trim().lowercase(Locale.ROOT)
        TAGS.firstOrNull { it.lowercase(Locale.ROOT) == lower }?.let { return it }
        if (lower.startsWith("zh")) {
            val traditional = "hant" in lower ||
                lower.endsWith("-tw") || lower.endsWith("-hk") || lower.endsWith("-mo")
            return if (traditional) "zh-TW" else "zh-CN"
        }
        val primary = lower.substringBefore('-')
        return TAGS.firstOrNull { it.lowercase(Locale.ROOT) == primary } ?: "en"
    }

    fun isRightToLeft(tag: String): Boolean = tag in RIGHT_TO_LEFT

    /** The locale whose `widget_strings.xml` holds [tag]'s table. */
    fun locale(tag: String): Locale = Locale.forLanguageTag(tag)
}
