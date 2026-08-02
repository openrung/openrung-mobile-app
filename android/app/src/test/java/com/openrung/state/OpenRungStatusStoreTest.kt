package com.openrung.state

import com.openrung.model.RelayConstants
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test

/**
 * Exercises the relay identity lifecycle in [OpenRungStatusStore]. The store is a singleton and
 * these tests deliberately never call [OpenRungStatusStore.initialize], so persistence is a no-op
 * and each test drives the store to a known state through the public API instead.
 */
class OpenRungStatusStoreTest {
    private val state get() = OpenRungStatusStore.uiState.value

    @Before
    fun resetStore() {
        // Any non-connected status auto-clears relayName/relayClass; explicitly drop the rest.
        OpenRungStatusStore.setStatus(ConnectionStatus.DISCONNECTED, relayLabel = null, lastError = null)
    }

    @Test
    fun `connected status exposes the stamped relay class`() {
        OpenRungStatusStore.setStatus(
            ConnectionStatus.CONNECTED,
            relayName = "relay-1",
            relayClass = RelayConstants.NODE_CLASS_FOUNDATION,
        )

        assertEquals(ConnectionStatus.CONNECTED, state.status)
        assertEquals("relay-1", state.relayName)
        assertEquals(RelayConstants.NODE_CLASS_FOUNDATION, state.relayClass)
    }

    @Test
    fun `re-stamping connected with default args keeps the relay class`() {
        OpenRungStatusStore.setStatus(
            ConnectionStatus.CONNECTED,
            relayName = "relay-1",
            relayClass = RelayConstants.NODE_CLASS_VOLUNTEER,
        )

        OpenRungStatusStore.setStatus(ConnectionStatus.CONNECTED)

        assertEquals("relay-1", state.relayName)
        assertEquals(RelayConstants.NODE_CLASS_VOLUNTEER, state.relayClass)
    }

    @Test
    fun `leaving connected clears the relay class`() {
        OpenRungStatusStore.setStatus(
            ConnectionStatus.CONNECTED,
            relayName = "relay-1",
            relayClass = RelayConstants.NODE_CLASS_FOUNDATION,
        )

        OpenRungStatusStore.setStatus(ConnectionStatus.DISCONNECTED)

        assertNull(state.relayName)
        assertNull(state.relayClass)
    }

    @Test
    fun `fail clears the relay class`() {
        OpenRungStatusStore.setStatus(
            ConnectionStatus.CONNECTED,
            relayName = "relay-1",
            relayClass = RelayConstants.NODE_CLASS_FOUNDATION,
        )

        OpenRungStatusStore.fail("x")

        assertEquals(ConnectionStatus.FAILED, state.status)
        assertEquals("x", state.lastError)
        assertNull(state.relayName)
        assertNull(state.relayClass)
    }
}
