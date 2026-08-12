package com.openrung.vpn

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.TimeZone

/**
 * Region detection and automatic-country resolution. Pure JVM (no Robolectric): the whole point is
 * that the service can answer "where is this device now?" itself, without the RN process, so a
 * background recovery after a physical-network change rebuilds with the right rule set.
 *
 * Must stay behaviourally identical to `src/model/splitTunnelDefaults.ts` and the Swift port.
 */
class SplitTunnelRegionTest {
    private val originalTimeZone: TimeZone = TimeZone.getDefault()

    @After
    fun restoreTimeZone() {
        TimeZone.setDefault(originalTimeZone)
    }

    @Test
    fun `time zones inside a preset country map to its region`() {
        assertEquals("IR", SplitTunnelRegion.regionForTimeZone("Asia/Tehran"))
        assertEquals("IR", SplitTunnelRegion.regionForTimeZone("Iran"))
        assertEquals("CN", SplitTunnelRegion.regionForTimeZone("Asia/Shanghai"))
        assertEquals("CN", SplitTunnelRegion.regionForTimeZone("Asia/Urumqi"))
        assertEquals("CN", SplitTunnelRegion.regionForTimeZone("PRC"))
    }

    @Test
    fun `everywhere else resolves to no region`() {
        // Hong Kong and Macau are deliberately not mainland: neither sits behind the GFW.
        listOf(
            "Europe/Berlin",
            "America/Los_Angeles",
            "Asia/Hong_Kong",
            "Asia/Macau",
            "UTC",
            "GMT",
            "Etc/UTC",
            "Etc/GMT+3",
            "local",
            "",
        ).forEach { zone ->
            assertEquals("no region for $zone", "", SplitTunnelRegion.regionForTimeZone(zone))
        }
    }

    @Test
    fun `regions map to exactly their own preset`() {
        assertEquals(listOf("ir"), SplitTunnelRegion.bypassCountriesForRegion("IR"))
        assertEquals(listOf("cn"), SplitTunnelRegion.bypassCountriesForRegion("CN"))
        assertEquals(emptyList<String>(), SplitTunnelRegion.bypassCountriesForRegion(""))
        assertEquals(emptyList<String>(), SplitTunnelRegion.bypassCountriesForRegion("DE"))
    }

    @Test
    fun `deviceRegion reads the OS zone fresh on every call`() {
        // The reason native can be trusted after a suspended-process resume: no cached value.
        TimeZone.setDefault(TimeZone.getTimeZone("Asia/Shanghai"))
        assertEquals("CN", SplitTunnelRegion.deviceRegion())
        TimeZone.setDefault(TimeZone.getTimeZone("Europe/Berlin"))
        assertEquals("", SplitTunnelRegion.deviceRegion())
    }

    @Test
    fun `an automatic selection is re-derived from the device, not the stored snapshot`() {
        // The travel case that RN alone cannot fix: the app auto-selected cn in Shanghai and has
        // not been opened since, but the service is rebuilding its config in Berlin.
        val auto = SplitTunnelStore.parse(
            """{"version":1,"enabled":true,"bypass_lan":true,"bypass_countries":["cn"],""" +
                """"country_source":"auto","excluded_packages":[]}""",
        )!!
        assertEquals(listOf("cn"), auto.resolvedBypassCountries("CN"))
        assertEquals(emptyList<String>(), auto.resolvedBypassCountries(""))
        assertEquals(listOf("ir"), auto.resolvedBypassCountries("IR"))
    }

    @Test
    fun `a hand-picked selection is honored verbatim however far the device travels`() {
        val manual = SplitTunnelStore.parse(
            """{"version":1,"enabled":true,"bypass_lan":true,"bypass_countries":["cn"],""" +
                """"country_source":"manual","excluded_packages":[]}""",
        )!!
        assertEquals(listOf("cn"), manual.resolvedBypassCountries("CN"))
        assertEquals(listOf("cn"), manual.resolvedBypassCountries(""))
        assertEquals(listOf("cn"), manual.resolvedBypassCountries("IR"))
    }

    @Test
    fun `a config from an older RN layer carries no source and is treated as hand-picked`() {
        val legacy = SplitTunnelStore.parse(
            """{"version":1,"enabled":true,"bypass_lan":true,"bypass_countries":["ir"],"excluded_packages":[]}""",
        )!!
        assertEquals(SplitTunnelConfig.COUNTRY_SOURCE_MANUAL, legacy.countrySource)
        assertEquals(listOf("ir"), legacy.resolvedBypassCountries(""))
    }
}
