package com.openrung.vpn

import android.app.Application
import android.net.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowNetworkInfo
import org.robolectric.shadows.ShadowNetwork
import org.robolectric.util.ReflectionHelpers
import org.robolectric.util.ReflectionHelpers.ClassParameter
import io.nekohasekai.libbox.InterfaceUpdateListener
import java.net.InetAddress
import java.net.NetworkInterface

@Suppress("DEPRECATION") // Legacy network fixtures also run on the API 28 fallback.
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28, 34], application = Application::class)
class EngineNetworkObserverTest {
    private fun caps(transport: Int) = NetworkCapabilities().apply {
        shadowOf(this).addTransportType(transport)
        shadowOf(this).addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        shadowOf(this).addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
        shadowOf(this).addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
    }
    private fun links(name: String) = LinkProperties().apply {
        interfaceName = name
        ReflectionHelpers.callInstanceMethod<Boolean>(this, "addDnsServer",
            ClassParameter.from(InetAddress::class.java, InetAddress.getByName("192.0.2.53")))
    }

    @Test fun `physical best match survives VPN active network and ignores duplicate or retired callbacks`() {
        val service = Robolectric.buildService(OpenRungVpnService::class.java).create().get()
        val cm = service.getSystemService(ConnectivityManager::class.java)
        val shadow = shadowOf(cm)
        shadow.clearAllNetworks()
        val vpn = ShadowNetwork.newInstance(ConnectivityManager.TYPE_VPN)
        val vpnInfo = ShadowNetworkInfo.newInstance(NetworkInfo.DetailedState.CONNECTED, ConnectivityManager.TYPE_VPN, 0, true, true)
        shadow.addNetwork(vpn, vpnInfo)
        shadow.setActiveNetworkInfo(vpnInfo)
        shadow.setNetworkCapabilities(vpn, caps(NetworkCapabilities.TRANSPORT_VPN))
        assertEquals(vpn, cm.activeNetwork)
        val changes = mutableListOf<EngineNetworkSnapshot>()
        service.observe(changes::add)
        val callback = shadow.networkCallbacks.single()
        val wifi = ShadowNetwork.newInstance(101)
        val wifiCaps = caps(NetworkCapabilities.TRANSPORT_WIFI)
        val wifiLinks = links("wlan0")
        callback.onAvailable(wifi)
        callback.onCapabilitiesChanged(wifi, wifiCaps)
        callback.onLinkPropertiesChanged(wifi, wifiLinks)
        assertEquals(wifi, service.physicalNetwork())
        assertEquals("wifi", service.networkAttributes()["network_transport"])
        val cached = service.networkSnapshot()
        repeat(20) {
            callback.onCapabilitiesChanged(wifi, wifiCaps)
            callback.onLinkPropertiesChanged(wifi, wifiLinks)
            assertSame(cached, service.networkSnapshot())
        }
        assertEquals(1, changes.size)
        val cell = ShadowNetwork.newInstance(102)
        callback.onAvailable(cell)
        callback.onCapabilitiesChanged(cell, caps(NetworkCapabilities.TRANSPORT_CELLULAR))
        callback.onLinkPropertiesChanged(cell, links("rmnet0"))
        callback.onLost(wifi) // Old default's loss must not clear the new default.
        callback.onLinkPropertiesChanged(wifi, wifiLinks)
        assertEquals(cell, service.physicalNetwork())
        assertEquals(2, changes.size)
        service.closeObservation()
        assertTrue(shadow.networkCallbacks.isEmpty())
        callback.onLost(cell)
        assertEquals(2, changes.size)
    }

    @Test fun `libbox gets changed default tuple once including metering changes`() {
        val service = Robolectric.buildService(OpenRungVpnService::class.java).create().get()
        val cm = service.getSystemService(ConnectivityManager::class.java)
        val shadow = shadowOf(cm)
        shadow.clearAllNetworks()
        service.observe { }
        val callback = shadow.networkCallbacks.single()
        val physical = ShadowNetwork.newInstance(101)
        // Use a real host interface so this exercises the same name/index resolution
        // as production; the JVM test runner must have networking to fetch dependencies.
        val iface = NetworkInterface.getNetworkInterfaces().toList().first {
            it.isUp && !it.isLoopback && !it.name.startsWith("tun") && !it.name.startsWith("utun")
        }
        val networkCaps = caps(NetworkCapabilities.TRANSPORT_WIFI)
        val networkLinks = links(iface.name)
        shadow.addNetwork(physical, ShadowNetworkInfo.newInstance(NetworkInfo.DetailedState.CONNECTED, ConnectivityManager.TYPE_WIFI, 0, true, true))
        shadow.setNetworkCapabilities(physical, networkCaps)
        shadow.setLinkProperties(physical, networkLinks)
        callback.onAvailable(physical)
        callback.onCapabilitiesChanged(physical, networkCaps)
        callback.onLinkPropertiesChanged(physical, networkLinks)
        val platform = OpenRungLibboxPlatform(service, { _, _ -> }, { _, _, _ -> })
        val updates = mutableListOf<List<Any?>>()
        val listener = object : InterfaceUpdateListener {
            override fun updateDefaultInterface(name: String?, index: Int, expensive: Boolean, constrained: Boolean) {
                updates.add(listOf(name, index, expensive, constrained))
            }
        }
        platform.startDefaultInterfaceMonitor(listener)
        repeat(10) { platform.refreshInterfaces() }
        assertEquals(listOf(listOf(iface.name, iface.index, false, false)), updates)
        val metered = NetworkCapabilities(networkCaps).apply { shadowOf(this).removeCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) }
        shadow.setNetworkCapabilities(physical, metered)
        callback.onCapabilitiesChanged(physical, metered)
        platform.refreshInterfaces(); platform.refreshInterfaces()
        assertEquals(2, updates.size)
        assertEquals(listOf(iface.name, iface.index, true, false), updates.last())
        platform.closeDefaultInterfaceMonitor(listener)
        platform.refreshInterfaces()
        assertEquals(2, updates.size)
        service.closeObservation()
    }
}
