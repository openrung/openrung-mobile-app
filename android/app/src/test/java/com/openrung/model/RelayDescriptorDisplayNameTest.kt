package com.openrung.model

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * `displayName()` renders operator-supplied relay labels safe for the UI (connect card,
 * recents pills, log lines): control/format characters stripped, whitespace collapsed,
 * length clamped, id fallback when nothing printable remains.
 */
class RelayDescriptorDisplayNameTest {

    @Test
    fun `uses the trimmed label when present`() {
        assertEquals("proud-falcon", relay(label = "  proud-falcon  ").displayName())
    }

    @Test
    fun `falls back to the relay id when the label is blank`() {
        assertEquals("relay-1", relay(label = "").displayName())
        assertEquals("relay-1", relay(label = "   ").displayName())
    }

    @Test
    fun `strips control characters`() {
        assertEquals("proudfalcon", relay(label = "proud\u0007fal\u001Bcon").displayName())
    }

    @Test
    fun `strips bidi override and other format characters`() {
        // U+202E RIGHT-TO-LEFT OVERRIDE could reorder surrounding UI text.
        assertEquals("npj.yaler", relay(label = "\u202Enpj.yaler").displayName())
        // Zero-width space / joiner vanish rather than smuggling hidden boundaries.
        assertEquals("proudfalcon", relay(label = "proud\u200B\u200Dfalcon").displayName())
    }

    @Test
    fun `strips astral-plane format characters`() {
        // Plane-14 TAG characters (here U+E0061 TAG LATIN SMALL LETTER A) encode hidden
        // text; as surrogate pairs they must not survive a char-level filter.
        assertEquals("proudfalcon", relay(label = "proud\uDB40\uDC61falcon").displayName())
    }

    @Test
    fun `collapses interior whitespace runs`() {
        assertEquals("proud falcon", relay(label = "proud \t\n  falcon").displayName())
    }

    @Test
    fun `clamps to 24 characters`() {
        assertEquals("x".repeat(24), relay(label = "x".repeat(80)).displayName())
    }

    @Test
    fun `never ends on half a surrogate pair when clamping`() {
        // 23 ASCII chars then U+1F680 (a surrogate pair): a naive 24-char cut would
        // keep only the high surrogate.
        val name = relay(label = "x".repeat(23) + "\uD83D\uDE80rocket").displayName()
        assertEquals("x".repeat(23), name)
    }

    @Test
    fun `falls back to the id when only unprintable characters remain`() {
        assertEquals("relay-1", relay(label = "\u202E\u200B\u0007").displayName())
    }

    private fun relay(label: String): RelayDescriptor = RelayDescriptor(
        id = "relay-1",
        label = label,
        publicHost = "203.0.113.10",
        publicPort = 443,
        relayProtocol = "vless-reality-vision",
        clientId = "e6b1a1de-9f0f-4c1a-8bb1-1f2b3c4d5e6f",
        realityPublicKey = "key",
        shortId = "abcd",
        serverName = "www.example.com",
        flow = "xtls-rprx-vision",
        exitMode = "direct",
        maxSessions = 8,
        maxMbps = 100,
        relayVersion = "1.0.0",
        registeredAt = "2026-07-01T00:00:00Z",
        lastHeartbeatAt = "2026-07-01T00:00:00Z",
        expiresAt = "2026-08-01T00:00:00Z",
    )
}
