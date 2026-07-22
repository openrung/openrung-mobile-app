package com.openrung.vpn

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.test.runTest
import java.net.SocketTimeoutException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TunnelStartupGuardTest {
    @Test
    fun `unexpected engine stop beats and cancels initial probe`() = runTest {
        val engineStopped = CompletableDeferred<String>()
        val probeCancelled = CompletableDeferred<Unit>()
        engineStopped.complete("libbox stopped")
        val error = runCatching {
            awaitStartupProbeOrEngineStop(
                probe = {
                    try {
                        awaitCancellation()
                    } finally {
                        probeCancelled.complete(Unit)
                    }
                },
                awaitUnexpectedEngineStop = { engineStopped.await() },
            )
        }.exceptionOrNull()
        assertTrue(error is LocalTunnelException)
        assertEquals("engine_stopped_during_probe", (error as LocalTunnelException).stage)
        probeCancelled.await()
    }

    @Test
    fun `successful initial probe cancels engine waiter`() = runTest {
        val engineWaitCancelled = CompletableDeferred<Unit>()

        val result = awaitStartupProbeOrEngineStop(
            probe = { "healthy" },
            awaitUnexpectedEngineStop = {
                try {
                    awaitCancellation()
                } finally {
                    engineWaitCancelled.complete(Unit)
                }
            },
        )

        assertEquals("healthy", result)
        engineWaitCancelled.await()
    }

    @Test
    fun `already completed engine stop wins over simultaneous remote probe failure`() = runTest {
        val error = runCatching {
            awaitStartupProbeOrEngineStop<Unit>(
                probe = { throw SocketTimeoutException("remote probe timed out") },
                awaitUnexpectedEngineStop = { "libbox stopped" },
            )
        }.exceptionOrNull()

        assertTrue(error is LocalTunnelException)
        assertEquals("engine_stopped_during_probe", (error as LocalTunnelException).stage)
        assertTrue(error.cause is EngineStartException)
    }
}
