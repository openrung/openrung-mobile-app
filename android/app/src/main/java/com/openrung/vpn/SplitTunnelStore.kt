package com.openrung.vpn

import android.content.Context
import android.content.SharedPreferences
// The country codes live with the emission input so there is one source of truth for them.
import com.openrung.net.SplitTunnelRules
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.util.TimeZone

/**
 * Where the device is, for split-tunnel country defaults — the Kotlin port of
 * `src/model/splitTunnelDefaults.ts`, and the reason a background recovery can re-derive an
 * automatic country selection without any help from the RN process.
 *
 * The IANA time zone is the only evidence used: offline, permission-free, and read fresh from the
 * OS on every call, so a device that changed zones while the app was suspended is seen correctly.
 * There is deliberately no locale fallback — a language preference is not evidence of physical
 * location, and guessing from it would put the China preset on exactly the diaspora devices this
 * protects.
 */
object SplitTunnelRegion {
    const val REGION_IRAN = "IR"
    const val REGION_CHINA = "CN"

    /**
     * Zones that place the device inside a country with a bundled preset (canonical names plus the
     * legacy aliases Android may still report). Hong Kong and Macau are deliberately absent:
     * neither sits behind the GFW, so the mainland preset would cost them the tunnel without
     * buying reachability.
     */
    private val REGION_BY_TIME_ZONE: Map<String, String> = mapOf(
        "asia/tehran" to REGION_IRAN,
        "iran" to REGION_IRAN,
        "asia/shanghai" to REGION_CHINA,
        "asia/chongqing" to REGION_CHINA,
        "asia/chungking" to REGION_CHINA,
        "asia/harbin" to REGION_CHINA,
        "asia/urumqi" to REGION_CHINA,
        "asia/kashgar" to REGION_CHINA,
        "prc" to REGION_CHINA,
    )

    /** ISO-3166 region for an IANA zone id, or "" when it carries no usable location. */
    fun regionForTimeZone(timeZoneId: String): String {
        val normalized = timeZoneId.trim().lowercase()
        if (normalized == "utc" || normalized == "gmt" || normalized == "local" ||
            normalized.startsWith("etc/")
        ) {
            return ""
        }
        return REGION_BY_TIME_ZONE[normalized] ?: ""
    }

    /** ISO-3166 region for this device right now, or "" when the zone gives no usable answer. */
    fun deviceRegion(): String = regionForTimeZone(TimeZone.getDefault().id)

    /** Bypass-country presets for a region; empty everywhere without a bundled rule set. */
    fun bypassCountriesForRegion(region: String): List<String> = when (region.uppercase()) {
        REGION_IRAN -> listOf(SplitTunnelRules.COUNTRY_IR)
        REGION_CHINA -> listOf(SplitTunnelRules.COUNTRY_CN)
        else -> emptyList()
    }
}

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
    /**
     * `"auto"` when RN derived [bypassCountries] from the device region rather than the user
     * choosing them, in which case [resolvedBypassCountries] re-derives here instead of trusting
     * the stored snapshot. Defaults to manual so an older RN layer (which never sends the field)
     * behaves exactly as before.
     */
    @SerialName("country_source") val countrySource: String = COUNTRY_SOURCE_MANUAL,
    @SerialName("excluded_packages") val excludedPackages: List<String> = emptyList(),
) {
    /**
     * The countries this config actually asks for. An automatic selection is re-derived from
     * [region] every time, because the stored list is only a snapshot of wherever the device was
     * when JS last ran — and the service rebuilds configs on its own after every physical-network
     * change, while the app may not have been opened for weeks. A selection the user made by hand
     * is always honored verbatim, however far the device has travelled.
     */
    fun resolvedBypassCountries(region: String = SplitTunnelRegion.deviceRegion()): List<String> =
        if (countrySource == COUNTRY_SOURCE_AUTO) {
            SplitTunnelRegion.bypassCountriesForRegion(region)
        } else {
            bypassCountries
        }

    companion object {
        const val COUNTRY_SOURCE_AUTO = "auto"
        const val COUNTRY_SOURCE_MANUAL = "manual"
    }
}

/**
 * Native persistence for the raw split-tunnel config JSON (contract §3). The raw string is stored
 * verbatim so [writeAndReportEffectiveChange] can detect no-op pushes by string equality — RN
 * serializes with a stable key order, making equal configs byte-equal. Fail-open (CONTRACT §1): an
 * absent or invalid config parses to null and the service degrades to full-tunnel behavior.
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

    /**
     * Persists [configJson] and reports whether the EFFECTIVE configuration changed — i.e. whether
     * the emitted sing-box config would actually differ. Two configs that both resolve to disabled
     * (or to the same enabled rule set) compare equal even when their raw JSON differs, so merely
     * a first disabled payload on a store that had never been written never bounces a live tunnel
     * (CONTRACT §1: master off is byte-identical to the baseline full-tunnel config).
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
        // Both signatures resolve against ONE region read, so a zone change landing between them
        // can never masquerade as a config change (and vice versa). A region change is not this
        // function's business anyway: it reaches the engine through the next connect/recovery
        // rebuild, which re-derives from scratch.
        val region = SplitTunnelRegion.deviceRegion()
        return effectiveSignature(parse(oldRaw), isInstalled, region) !=
            effectiveSignature(parse(configJson), isInstalled, region)
    }

    /** A canonical string that changes only when the emitted sing-box config would change. */
    private fun effectiveSignature(
        config: SplitTunnelConfig?,
        isInstalled: (String) -> Boolean,
        region: String,
    ): String {
        if (config == null || !config.enabled) return DISABLED
        // The emission side re-derives an automatic selection, so the signature must too —
        // otherwise a push that flips country_source without changing bypass_countries would look
        // like a no-op while the emitted config actually changed.
        val countries = config.resolvedBypassCountries(region)
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
