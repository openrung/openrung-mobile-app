package com.openrung.vpn

import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.OpenRungEngine
import io.nekohasekai.libbox.OpenRungEngineListener
import io.nekohasekai.libbox.OpenRungWSSProtector
import io.nekohasekai.libbox.PlatformInterface
import org.junit.Assert.assertEquals
import org.junit.Test

/** B1's generated AAR contract, before the service switches to it in B2. */
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
        val engine = OpenRungEngine::class.java
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
