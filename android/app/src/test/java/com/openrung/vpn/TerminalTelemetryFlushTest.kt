package com.openrung.vpn

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

class TerminalTelemetryFlushTest {
    @Test
    fun `successful flush completes before service stop`() = runTest {
        val order = mutableListOf<String>()

        flushTelemetryBeforeStop(
            brokerUrl = "https://winner.example/",
            timeoutMillis = 5_000,
            flush = { brokerUrl -> order += "flush:$brokerUrl" },
            stop = { order += "stop" },
        )

        assertEquals(listOf("flush:https://winner.example/", "stop"), order)
    }

    @Test
    fun `upload failure still stops and leaves retry policy to the outbox`() = runTest {
        val order = mutableListOf<String>()

        flushTelemetryBeforeStop(
            brokerUrl = "https://winner.example/",
            timeoutMillis = 5_000,
            flush = { _ ->
                order += "flush"
                throw IllegalStateException("offline")
            },
            stop = { order += "stop" },
        )

        assertEquals(listOf("flush", "stop"), order)
    }

    @Test
    fun `timeout bounds shutdown before service stop`() = runTest {
        val order = mutableListOf<String>()

        flushTelemetryBeforeStop(
            brokerUrl = "https://winner.example/",
            timeoutMillis = 5_000,
            flush = { _ ->
                order += "flush"
                awaitCancellation()
            },
            stop = { order += "stop" },
        )

        assertEquals(listOf("flush", "stop"), order)
    }

    @Test
    fun `caller cancellation prevents stale service stop`() = runTest {
        val order = mutableListOf<String>()
        val flushStarted = CompletableDeferred<Unit>()
        val job = launch {
            flushTelemetryBeforeStop(
                brokerUrl = "https://winner.example/",
                timeoutMillis = 5_000,
                flush = { _ ->
                    order += "flush"
                    flushStarted.complete(Unit)
                    awaitCancellation()
                },
                stop = { order += "stop" },
            )
        }
        flushStarted.await()

        job.cancel()
        job.join()

        assertEquals(listOf("flush"), order)
    }
}
