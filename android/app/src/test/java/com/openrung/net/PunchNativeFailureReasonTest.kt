package com.openrung.net

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/** Mirrors iOS `testNativeFailureReasonsMapToABoundedTaxonomy` in PunchNativeClientTests. */
class PunchNativeFailureReasonTest {
    @Test
    fun `native failure reasons map to a bounded taxonomy`() {
        assertEquals(
            PunchNativeFailureReason.CONFIGURATION,
            PunchNativeFailureReason.fromNative("config"),
        )
        assertEquals(
            PunchNativeFailureReason.SOCKET_PROTECTION,
            PunchNativeFailureReason.fromNative("protect"),
        )
        assertEquals(
            PunchNativeFailureReason.DECLINED,
            PunchNativeFailureReason.fromNative("declined:relay busy"),
        )
        assertEquals(
            PunchNativeFailureReason.TRANSPORT,
            PunchNativeFailureReason.fromNative("new-server-value"),
        )
        assertEquals(
            PunchNativeFailureReason.BRIDGE,
            PunchNativeFailureReason.fromNative("adapter"),
        )
        assertEquals(
            PunchNativeFailureReason.CANCELLED,
            PunchNativeFailureReason.fromNative(" Cancelled\n"),
        )
        assertEquals(
            PunchNativeFailureReason.TRANSPORT,
            PunchNativeFailureReason.fromNative(""),
        )

        // Distinct declined payloads collapse to one wire value and never leak into telemetry.
        val first = PunchNativeFailureReason.fromNative("declined:secret-a")
        val second = PunchNativeFailureReason.fromNative("declined:secret-b")
        assertEquals("declined", first.wireValue)
        assertEquals("declined", second.wireValue)
        assertEquals(first, second)
        assertFalse(first.wireValue.contains("secret"))

        // The wire vocabulary is the closed set shared with iOS's PunchNativeFailureReason.
        assertEquals(
            setOf(
                "client", "config", "socket", "protect", "nonce", "discovery", "request",
                "declined", "session", "token", "certificate", "punch", "quic", "bridge",
                "transport", "cancelled",
            ),
            PunchNativeFailureReason.entries.map { it.wireValue }.toSet(),
        )
    }
}
