package com.openrung.vpn

import android.content.Context
import com.openrung.config.AppConfig

/**
 * Per-app split-tunnel config, persisted in its own SharedPreferences file so the VpnService can
 * read it synchronously at establish time (before any JS runs — an AsyncStorage mirror would
 * race). The bridge writes it; [OpenRungLibboxPlatform.openTun] reads it.
 *
 *  - OFF: every app rides the tunnel (default).
 *  - PROXY_ONLY: only the listed apps use the tunnel (addAllowedApplication).
 *  - BYPASS: the listed apps skip the tunnel (addDisallowedApplication).
 */
enum class SplitTunnelMode(val wireName: String) {
    OFF("off"),
    PROXY_ONLY("proxyOnly"),
    BYPASS("bypass");

    companion object {
        fun fromWireName(value: String?): SplitTunnelMode =
            entries.firstOrNull { it.wireName == value } ?: OFF
    }
}

data class SplitTunnelConfig(
    val mode: SplitTunnelMode = SplitTunnelMode.OFF,
    val packages: Set<String> = emptySet(),
)

object SplitTunnelStore {
    private const val KEY_MODE = "mode"
    private const val KEY_PACKAGES = "packages"

    fun read(context: Context): SplitTunnelConfig {
        val prefs = context.getSharedPreferences(AppConfig.SPLIT_TUNNEL_PREFS, Context.MODE_PRIVATE)
        return SplitTunnelConfig(
            mode = SplitTunnelMode.fromWireName(prefs.getString(KEY_MODE, SplitTunnelMode.OFF.wireName)),
            packages = prefs.getStringSet(KEY_PACKAGES, emptySet())?.toSet() ?: emptySet(),
        )
    }

    fun write(context: Context, config: SplitTunnelConfig) {
        context.getSharedPreferences(AppConfig.SPLIT_TUNNEL_PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_MODE, config.mode.wireName)
            .putStringSet(KEY_PACKAGES, config.packages)
            .apply()
    }
}
