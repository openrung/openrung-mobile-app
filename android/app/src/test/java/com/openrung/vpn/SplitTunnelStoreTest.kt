package com.openrung.vpn

import android.app.Application
import android.content.Context
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class SplitTunnelStoreTest {
    private lateinit var context: Context

    @Before
    fun setUp() {
        context = RuntimeEnvironment.getApplication()
    }

    @Test
    fun `written config round-trips through read`() {
        val configJson =
            """{"version":1,"enabled":true,"bypass_lan":true,"bypass_countries":["ir","cn"],"excluded_packages":["com.tencent.mm"]}"""
        assertTrue(SplitTunnelStore.writeRaw(context, configJson))

        val config = SplitTunnelStore.read(context)!!
        assertEquals(1, config.version)
        assertTrue(config.enabled)
        assertTrue(config.bypassLan)
        assertEquals(listOf("ir", "cn"), config.bypassCountries)
        assertEquals(listOf("com.tencent.mm"), config.excludedPackages)
    }

    @Test
    fun `unknown keys and missing fields are tolerated`() {
        val config = SplitTunnelStore.parse(
            """{"version":2,"enabled":true,"bypass_countries":["ir"],"future_field":{"nested":true}}""",
        )!!
        assertEquals(2, config.version)
        assertTrue(config.enabled)
        // Absent bypass_lan falls back to its default (on).
        assertTrue(config.bypassLan)
        assertEquals(listOf("ir"), config.bypassCountries)
        assertEquals(emptyList<String>(), config.excludedPackages)
    }

    @Test
    fun `invalid JSON parses to null`() {
        assertNull(SplitTunnelStore.parse("not json"))
        assertNull(SplitTunnelStore.parse("""{"version":1,"enabled":"maybe"}"""))
        assertNull(SplitTunnelStore.parse(""))
        assertNull(SplitTunnelStore.parse(null))
        // The shared schema only promises compatibility for version >= 1 (spec §1).
        assertNull(SplitTunnelStore.parse("""{"version":0,"enabled":true}"""))
    }

    @Test
    fun `disabled config still parses`() {
        val config = SplitTunnelStore.parse("""{"version":1,"enabled":false}""")!!
        assertFalse(config.enabled)
    }

    @Test
    fun `writeRaw reports whether the stored value changed`() {
        val configJson = """{"version":1,"enabled":true}"""
        assertTrue(SplitTunnelStore.writeRaw(context, configJson))
        assertFalse(SplitTunnelStore.writeRaw(context, configJson))
        assertTrue(SplitTunnelStore.writeRaw(context, """{"version":1,"enabled":false}"""))
    }

    @Test
    fun `writeAndReportEffectiveChange ignores no-op pushes that keep the emitted config identical`() {
        // First push of a disabled config over an empty store: persisted, but NOT an
        // effective change (both resolve to "disabled"), so a live tunnel must not reapply.
        val defaultDisabled =
            """{"version":1,"enabled":false,"bypass_lan":true,"bypass_countries":[],"excluded_packages":[]}"""
        assertFalse(SplitTunnelStore.writeAndReportEffectiveChange(context, defaultDisabled))
        // The raw string is still persisted even though it was not an effective change.
        assertEquals(defaultDisabled, readBackRaw(context))

        // Enabling with no effective rule (no LAN, no countries, no packages) is still "disabled".
        val enabledButInert =
            """{"version":1,"enabled":true,"bypass_lan":false,"bypass_countries":[],"excluded_packages":[]}"""
        assertFalse(SplitTunnelStore.writeAndReportEffectiveChange(context, enabledButInert))

        // Turning on a real rule IS an effective change.
        val enabledIr =
            """{"version":1,"enabled":true,"bypass_lan":false,"bypass_countries":["ir"],"excluded_packages":[]}"""
        assertTrue(SplitTunnelStore.writeAndReportEffectiveChange(context, enabledIr))

        // Reordering / re-serializing the same effective config is not a change.
        val enabledIrReordered =
            """{"version":1,"enabled":true,"bypass_lan":false,"bypass_countries":["ir"],"excluded_packages":[],"extra":true}"""
        assertFalse(SplitTunnelStore.writeAndReportEffectiveChange(context, enabledIrReordered))

        // An unrecognized country resolves to no effective rule -> back to "disabled".
        val enabledUnknownCountry =
            """{"version":1,"enabled":true,"bypass_lan":false,"bypass_countries":["xx"],"excluded_packages":[]}"""
        assertTrue(SplitTunnelStore.writeAndReportEffectiveChange(context, enabledUnknownCountry))

        // Enabling ir is a change; then adding an excluded package whose app is NOT installed is
        // not (emission drops uninstalled packages), so pruning a stale entry won't reconnect a
        // live tunnel. Robolectric has no packages installed, so com.example.absent is "missing".
        val enabledIrNoPackages =
            """{"version":1,"enabled":true,"bypass_lan":false,"bypass_countries":["ir"],"excluded_packages":[]}"""
        assertTrue(SplitTunnelStore.writeAndReportEffectiveChange(context, enabledIrNoPackages))
        val enabledIrUninstalledPackage =
            """{"version":1,"enabled":true,"bypass_lan":false,"bypass_countries":["ir"],"excluded_packages":["com.example.absent"]}"""
        assertFalse(SplitTunnelStore.writeAndReportEffectiveChange(context, enabledIrUninstalledPackage))
    }

    private fun readBackRaw(context: Context): String? =
        context.getSharedPreferences("openrung_split_tunnel", Context.MODE_PRIVATE)
            .getString("config_json", null)
}
