package com.openrung.telemetry

import com.openrung.net.BrokerNativeFailure
import com.openrung.net.BrokerNativeFailureKind
import com.openrung.net.NativeBrokerCommonResult
import com.openrung.net.RecordingNativeBrokerOperation
import com.openrung.net.RecordingNativeBrokerOperationFactory
import com.openrung.net.assertSuspendThrows
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TelemetryClientTest {
    @Test
    fun `empty batch is a no-op and creates no native operation`() = runBlocking {
        val factory = RecordingNativeBrokerOperationFactory()
        TelemetryClient("https://broker.example/", factory).send(emptyList())
        assertEquals(0, factory.createCalls.get())
    }

    @Test
    fun `telemetry sends exact single encoded batch JSON`() = runBlocking {
        val operation = RecordingNativeBrokerOperation()
        val client = TelemetryClient(
            baseUrl = "https://telemetry.example/base",
            operationFactory = RecordingNativeBrokerOperationFactory(operation),
        )

        client.send(listOf(EVENT))

        val call = operation.telemetryCalls.single()
        assertEquals("https://telemetry.example/base", call.brokerUrl)
        assertEquals(
            """{"events":[{"schema_version":1,"event_id":"event-1","event":"session_heartbeat","occurred_at":"2026-07-26T00:00:00Z","client_id":"client-a","session_id":"session-a","relay_id":null,"application_package":null,"application_uid":null,"attributes":{},"measurements":{}}]}""",
            call.batchJson,
        )
        assertEquals(1, operation.closeCalls.get())
    }

    @Test
    fun `each telemetry batch gets an independent single-use operation`() = runBlocking {
        val first = RecordingNativeBrokerOperation()
        val second = RecordingNativeBrokerOperation()
        val factory = RecordingNativeBrokerOperationFactory(first, second)
        val client = TelemetryClient("https://telemetry.example/", factory)

        client.send(listOf(EVENT))
        client.send(listOf(EVENT.copy(eventId = "event-2")))

        assertEquals(2, factory.createCalls.get())
        assertEquals(1, first.telemetryCalls.size)
        assertEquals(1, second.telemetryCalls.size)
        assertEquals(1, first.closeCalls.get())
        assertEquals(1, second.closeCalls.get())
    }

    @Test
    fun `typed telemetry failure propagates and leaves queued IDs uncommitted`() = runBlocking {
        var committed = false
        val failure = BrokerNativeFailure(
            kind = BrokerNativeFailureKind.NETWORK,
            message = "network unavailable",
        )

        val surfaced = assertSuspendThrows<BrokerNativeFailure> {
            sendTelemetryBatchAndCommit(
                events = listOf(EVENT),
                queuedEventIds = setOf(EVENT.eventId),
                send = { throw failure },
                commit = { committed = true },
            )
        }

        assertEquals(BrokerNativeFailureKind.NETWORK, surfaced.kind)
        assertFalse(committed)
    }

    @Test
    fun `cancellation racing a successful send leaves queued IDs uncommitted`() = runBlocking {
        var committed = false
        val observed = CompletableDeferred<Throwable>()
        val job = launch {
            try {
                sendTelemetryBatchAndCommit(
                    events = listOf(EVENT),
                    queuedEventIds = setOf(EVENT.eventId),
                    send = {
                        // Model native success followed by caller cancellation before resume.
                        currentCoroutineContext().cancel(CancellationException("disconnect"))
                    },
                    commit = { committed = true },
                )
            } catch (error: Throwable) {
                observed.complete(error)
                throw error
            }
        }
        job.join()

        assertTrue(observed.await() is CancellationException)
        assertFalse(committed)
    }

    @Test
    fun `spurious Go cancelled result is a typed failure for a live caller and closes operation`() = runBlocking {
        val operation = RecordingNativeBrokerOperation().apply {
            telemetryResult = NativeBrokerCommonResult(
                succeeded = false,
                errorKind = "cancelled",
                errorText = "request cancelled",
            )
        }

        // A native "cancelled" kind reaching this live coroutine is a failed upload the outbox
        // retries later; CancellationException here would end the caller's epoch instead.
        val failure = assertSuspendThrows<BrokerNativeFailure> {
            TelemetryClient(
                "https://telemetry.example/",
                RecordingNativeBrokerOperationFactory(operation),
            ).send(listOf(EVENT))
        }

        assertEquals(BrokerNativeFailureKind.CANCELLED, failure.kind)
        assertEquals(1, operation.closeCalls.get())
    }

    @Test
    fun `historical backlog cannot delay heartbeat and then flushes homogeneous prefixes`() = runBlocking {
        val outbox = mutableListOf(
            event("old-a-1", "client-old-a", "session-old-a"),
            event("old-a-2", "client-old-a", "session-old-a"),
            event("old-a-3", "client-old-a", "session-old-a"),
            event("old-a-4", "client-old-a", "session-old-a"),
            event("old-b-1", "client-old-b", "session-old-b"),
            event("current-1", "client-current", "session-current"),
            event("current-2", "client-current", "session-current"),
        )
        val heartbeat = event("heartbeat-now", "client-current", "session-current")
        val sent = mutableListOf<List<TelemetryEvent>>()

        sendHeartbeatWithQueuedEvents(
            heartbeat = heartbeat,
            batchSize = 3,
            readQueued = { outbox.toList() },
            send = { sent += it },
            commit = { ids -> outbox.removeAll { it.eventId in ids } },
            flushQueued = {
                while (outbox.isNotEmpty()) {
                    val batch = telemetryUploadBatch(outbox, limit = 3)
                    sent += batch
                    val sentIDs = batch.mapTo(hashSetOf(), TelemetryEvent::eventId)
                    outbox.removeAll { it.eventId in sentIDs }
                }
            },
        )

        assertEquals(
            listOf(
                listOf("heartbeat-now"),
                listOf("old-a-1", "old-a-2", "old-a-3"),
                listOf("old-a-4"),
                listOf("old-b-1"),
                listOf("current-1", "current-2"),
            ),
            sent.map { batch -> batch.map { it.eventId } },
        )
        sent.forEach { batch ->
            assertEquals(
                1,
                batch.map { it.clientId to it.sessionId }.distinct().size,
            )
        }
        assertTrue(outbox.isEmpty())
    }

    @Test
    fun `historical prefix failure occurs after heartbeat and retains backlog`() = runBlocking {
        val original = listOf(
            event("old-1", "client-old", "session-old"),
            event("current-1", "client-current", "session-current"),
        )
        val outbox = original.toMutableList()
        val heartbeat = event("heartbeat-now", "client-current", "session-current")
        val sent = mutableListOf<List<String>>()

        assertSuspendThrows<BrokerNativeFailure> {
            sendHeartbeatWithQueuedEvents(
                heartbeat = heartbeat,
                batchSize = 3,
                readQueued = { outbox.toList() },
                send = { sent += it.map(TelemetryEvent::eventId) },
                commit = { ids -> outbox.removeAll { it.eventId in ids } },
                flushQueued = {
                    val batch = telemetryUploadBatch(outbox, limit = 3)
                    sendTelemetryBatchAndCommit(
                        events = batch,
                        queuedEventIds = batch.mapTo(hashSetOf(), TelemetryEvent::eventId),
                        send = {
                            sent += it.map(TelemetryEvent::eventId)
                            throw BrokerNativeFailure(
                                kind = BrokerNativeFailureKind.NETWORK,
                                message = "offline",
                            )
                        },
                        commit = { ids -> outbox.removeAll { it.eventId in ids } },
                    )
                },
            )
        }

        assertEquals(listOf(listOf("heartbeat-now"), listOf("old-1")), sent)
        assertEquals(original.map { it.eventId }, outbox.map { it.eventId })
    }

    @Test
    fun `heartbeat piggybacks only a matching head prefix`() = runBlocking {
        val outbox = mutableListOf(
            event("current-1", "client-current", "session-current"),
            event("current-2", "client-current", "session-current"),
            event("old-1", "client-old", "session-old"),
        )
        val heartbeat = event("heartbeat-now", "client-current", "session-current")
        val sent = mutableListOf<List<TelemetryEvent>>()

        sendHeartbeatWithQueuedEvents(
            heartbeat = heartbeat,
            batchSize = 3,
            readQueued = { outbox.toList() },
            send = { sent += it },
            commit = { ids -> outbox.removeAll { it.eventId in ids } },
            flushQueued = {
                while (outbox.isNotEmpty()) {
                    val batch = telemetryUploadBatch(outbox, limit = 3)
                    sent += batch
                    val sentIDs = batch.mapTo(hashSetOf(), TelemetryEvent::eventId)
                    outbox.removeAll { it.eventId in sentIDs }
                }
            },
        )

        assertEquals(
            listOf(
                listOf("current-1", "current-2", "heartbeat-now"),
                listOf("old-1"),
            ),
            sent.map { batch -> batch.map(TelemetryEvent::eventId) },
        )
        sent.forEach { batch ->
            assertEquals(
                1,
                batch.map { it.clientId to it.sessionId }.distinct().size,
            )
        }
        assertTrue(outbox.isEmpty())
    }

    private fun event(id: String, clientId: String, sessionId: String): TelemetryEvent =
        EVENT.copy(
            eventId = id,
            clientId = clientId,
            sessionId = sessionId,
        )

    companion object {
        private val EVENT = TelemetryEvent(
            eventId = "event-1",
            event = "session_heartbeat",
            occurredAt = "2026-07-26T00:00:00Z",
            clientId = "client-a",
            sessionId = "session-a",
        )
    }
}
