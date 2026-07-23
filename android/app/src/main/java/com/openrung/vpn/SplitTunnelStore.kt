package com.openrung.vpn

import android.content.Context
import android.content.SharedPreferences
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * The persisted split-tunnel config: the shared RN → native JSON of the split-tunnel spec §1.
 * Defaults double as forward compatibility — parsers accept any object with `version >= 1` and
 * ignore unknown fields, so a newer RN layer can add keys without breaking an older service.
 */
@Serializable
data class SplitTunnelConfig(
    val version: Int = 1,
    val enabled: Boolean = false,
    @SerialName("bypass_lan") val bypassLan: Boolean = true,
    @SerialName("bypass_countries") val bypassCountries: List<String> = emptyList(),
    @SerialName("excluded_packages") val excludedPackages: List<String> = emptyList(),
)

/**
 * Native persistence for the raw split-tunnel config JSON (contract §3). The raw string is stored
 * verbatim so [writeRaw] can detect no-op pushes by string equality — RN serializes with a stable
 * key order, making equal configs byte-equal. Fail-open (CONTRACT §1): an absent or invalid config
 * parses to null and the service degrades to full-tunnel behavior.
 */
object SplitTunnelStore {
    private const val PREFS_NAME = "openrung_split_tunnel"
    private const val KEY_CONFIG_JSON = "config_json"
    private const val DISABLED = "disabled"

    // The country presets the generator actually emits; an enabled config that resolves to none of
    // these (and no LAN/package rule) is effectively disabled.
    private val EFFECTIVE_COUNTRIES = setOf("ir", "cn")

    private val json = Json { ignoreUnknownKeys = true }

    fun read(context: Context): SplitTunnelConfig? =
        parse(prefs(context).getString(KEY_CONFIG_JSON, null))

    /** Persists the raw config JSON; returns whether it differs from the stored value. */
    fun writeRaw(context: Context, configJson: String): Boolean {
        val prefs = prefs(context)
        if (prefs.getString(KEY_CONFIG_JSON, null) == configJson) return false
        prefs.edit().putString(KEY_CONFIG_JSON, configJson).apply()
        return true
    }

    /**
     * Persists [configJson] and reports whether the EFFECTIVE configuration changed — i.e. whether
     * the emitted sing-box config would actually differ. Two configs that both resolve to disabled
     * (or to the same enabled rule set) compare equal even when their raw JSON differs, so merely
     * opening the split-tunnel screen — which re-persists the default disabled config on a store
     * that had never been written — never bounces a live tunnel (CONTRACT §1: master off is
     * byte-identical to today).
     */
    fun writeAndReportEffectiveChange(context: Context, configJson: String): Boolean {
        val prefs = prefs(context)
        val oldRaw = prefs.getString(KEY_CONFIG_JSON, null)
        if (oldRaw == configJson) return false
        prefs.edit().putString(KEY_CONFIG_JSON, configJson).apply()
        // The emission side (currentSplitTunnelRules) drops packages whose app is no longer
        // installed, so the signature must too — otherwise pruning a stale package would count as
        // a change and needlessly reconnect a live tunnel even though the emitted config is equal.
        val isInstalled: (String) -> Boolean = { pkg ->
            runCatching { context.packageManager.getApplicationInfo(pkg, 0) }.isSuccess
        }
        return effectiveSignature(parse(oldRaw), isInstalled) !=
            effectiveSignature(parse(configJson), isInstalled)
    }

    /** A canonical string that changes only when the emitted sing-box config would change. */
    private fun effectiveSignature(config: SplitTunnelConfig?, isInstalled: (String) -> Boolean): String {
        if (config == null || !config.enabled) return DISABLED
        val countries = config.bypassCountries
            .map { it.lowercase() }
            .filter { it in EFFECTIVE_COUNTRIES }
            .distinct()
            .sorted()
        val packages = config.excludedPackages.filter(isInstalled).distinct().sorted()
        if (!config.bypassLan && countries.isEmpty() && packages.isEmpty()) return DISABLED
        return "enabled|lan=${config.bypassLan}|c=${countries.joinToString(",")}|p=${packages.joinToString(",")}"
    }

    fun parse(configJson: String?): SplitTunnelConfig? {
        if (configJson.isNullOrBlank()) return null
        return runCatching { json.decodeFromString<SplitTunnelConfig>(configJson) }
            .getOrNull()
            ?.takeIf { it.version >= 1 }
    }

    private fun prefs(context: Context): SharedPreferences =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
}
