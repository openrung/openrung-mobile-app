package com.openrung.telemetry

import android.app.Application
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/**
 * The JVM has no gomobile engine, so touching Libbox here throws a real
 * LinkageError — the same stale-or-missing-native-artifact failure the guards
 * in NativeTelemetryOutbox exist for. Every TelemetryOutboxHandle method must
 * degrade to the unavailable path instead of throwing: record() runs inside
 * the service's failure handlers, where a throw would replace the real error
 * and crash the service.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class NativeTelemetryOutboxTest {
    @Test
    fun unloadableNativeEngineDegradesEveryCallInsteadOfThrowing() {
        val outbox: TelemetryOutboxHandle = NativeTelemetryOutbox(RuntimeEnvironment.getApplication())

        assertFalse(outbox.enqueue("""{"event":"x"}"""))
        // -1 tells the legacy import to keep its only copy for a later retry.
        assertEquals(-1, outbox.enqueueBatch("[]"))
        outbox.applySessionAttributes("session", """{"country":"JP"}""")
        assertEquals(0, outbox.pendingCount())

        val upload = outbox.beginUpload()
        val flush = upload.flushNextBatch("https://broker.example")
        assertFalse(flush.succeeded)
        assertEquals("unavailable", flush.errorKind)
        val heartbeat = upload.sendHeartbeat("https://broker.example", """{"event":"session_heartbeat"}""")
        assertFalse(heartbeat.succeeded)
        assertEquals("unavailable", heartbeat.errorKind)
        upload.close()
    }
}
