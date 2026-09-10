package com.openrung.vpn

import io.nekohasekai.libbox.OpenRungMobileHost
import io.nekohasekai.libbox.OpenRungMobileRun
import io.nekohasekai.libbox.OpenRungRunTelemetry
import io.nekohasekai.libbox.OpenRungEngineOperation
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.OpenRungEngine
import io.nekohasekai.libbox.OpenRungEngineListener
import io.nekohasekai.libbox.OpenRungWSSProtector
import io.nekohasekai.libbox.PlatformInterface
import org.junit.Assert.assertEquals
import org.junit.Test

/** Generated AAR contract consumed by the Android B2 host. */
class EngineBindingAbiTest {
    @Test
    fun `release AAR exposes the complete engine lifecycle and callback surface`() {
        // Class literals and reflection do not initialize libbox's native runtime
        // on the host JVM. Go exercises behavior; this pins generated signatures.
        val constructors = Libbox::class.java
        assertEquals(OpenRungEngine::class.java, constructors.getMethod(
            "newOpenRungEngineForAndroid", String::class.java, PlatformInterface::class.java,
            OpenRungWSSProtector::class.java, OpenRungEngineListener::class.java,
        ).returnType)
        assertEquals(OpenRungEngine::class.java, constructors.getMethod(
            "newOpenRungEngineForIOS", String::class.java, PlatformInterface::class.java,
            OpenRungEngineListener::class.java,
        ).returnType)
        assertEquals(OpenRungEngine::class.java, constructors.getMethod(
            "newOpenRungMobileEngineForAndroid", String::class.java, OpenRungWSSProtector::class.java,
            OpenRungMobileHost::class.java, OpenRungEngineListener::class.java,
        ).returnType)
        constructors.getMethod("openRungTunName", Int::class.javaPrimitiveType)
        OpenRungMobileHost::class.java.getMethod("settingsJSON")
        OpenRungMobileHost::class.java.getMethod("attributesJSON")
        OpenRungMobileHost::class.java.getMethod("newRun", OpenRungRunTelemetry::class.java)
        OpenRungMobileRun::class.java.getMethod("platform")
        OpenRungMobileRun::class.java.getMethod("waitReady", OpenRungEngineOperation::class.java)
        OpenRungMobileRun::class.java.getMethod("verifyPath", OpenRungEngineOperation::class.java, String::class.java)
        OpenRungMobileRun::class.java.getMethod("close")
        OpenRungEngineOperation::class.java.getMethod("isCancelled")
        OpenRungRunTelemetry::class.java.getMethod("recordApplicationConnections", String::class.java, Int::class.javaPrimitiveType, Long::class.javaPrimitiveType)
        val engine = OpenRungEngine::class.java
        assertEquals(Boolean::class.javaPrimitiveType, engine.getMethod("teardownComplete").returnType)
        engine.getMethod("start", String::class.java, String::class.java, String::class.java)
        engine.getMethod("disconnect")
        engine.getMethod("stop", Long::class.javaPrimitiveType)
        engine.getMethod("pause")
        engine.getMethod("resume")
        engine.getMethod("networkChanged", Boolean::class.javaPrimitiveType, String::class.java, String::class.java)
        assertEquals(String::class.java, engine.getMethod("stateJSON").returnType)
        OpenRungEngineListener::class.java.getMethod("onEvent", String::class.java)
    }
}
