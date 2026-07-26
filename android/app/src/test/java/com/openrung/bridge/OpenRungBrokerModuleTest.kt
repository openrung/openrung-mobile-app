package com.openrung.bridge

import com.openrung.net.BrokerNativeFailureKind
import com.openrung.net.FirstReachableCall
import com.openrung.net.ManifestCandidateCall
import com.openrung.net.NativeBrokerCommonResult
import com.openrung.net.NativeBrokerManifestResult
import com.openrung.net.NativeBrokerRelayResult
import com.openrung.net.NativeBrokerSpeedTestResult
import com.openrung.net.RecordingNativeBrokerOperation
import com.openrung.net.RecordingNativeBrokerOperationFactory
import com.openrung.net.SpeedTestCall
import com.openrung.net.TelemetryCall
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

class OpenRungBrokerModuleTest {
    @Test
    fun `all operations return plain snapshots and each uses a fresh operation`() {
        val discovery = RecordingNativeBrokerOperation().apply {
            relayResult = NativeBrokerRelayResult(
                succeeded = true,
                brokerUrl = "https://broker.openrung.org/",
                relayJson = """{"count":0,"relays":[]}""",
                keyId = "key-a",
                signatureVerified = true,
            )
        }
        val speed = RecordingNativeBrokerOperation().apply {
            speedTestResult = NativeBrokerSpeedTestResult(
                succeeded = true,
                bytes = 1_048_576,
                ttfbMillis = 11,
                downloadDurationMillis = 70,
                totalDurationMillis = 91,
                mbps = 92.19,
            )
        }
        val telemetry = RecordingNativeBrokerOperation()
        val manifest = RecordingNativeBrokerOperation().apply {
            manifestResult = NativeBrokerManifestResult(
                succeeded = true,
                bodyJson = " \n{\"signed\":\"exact\"}\n",
                sourceUrl = "https://broker.openrung.org/api/v1/app-manifest",
            )
        }
        val factory = RecordingNativeBrokerOperationFactory(
            discovery,
            speed,
            telemetry,
            manifest,
        )
        val coordinator = OpenRungBrokerRequestCoordinator(factory)

        val discoveryCallbacks = RecordingCallbacks()
        coordinator.firstReachable(
            requestId = "discovery",
            primary = "https://custom.example/",
            limit = 20,
            clientId = "client-a",
            sessionId = "session-a",
            callbacks = discoveryCallbacks.value,
        )
        assertEquals(
            mapOf(
                "brokerUrl" to "https://broker.openrung.org/",
                "relayJson" to """{"count":0,"relays":[]}""",
                "keyId" to "key-a",
                "signatureVerified" to true,
            ),
            discoveryCallbacks.awaitResult(),
        )
        assertEquals(
            FirstReachableCall(
                primary = "https://custom.example/",
                limit = 20,
                clientId = "client-a",
                sessionId = "session-a",
            ),
            discovery.firstReachableCalls.single(),
        )

        val speedCallbacks = RecordingCallbacks()
        coordinator.runSpeedTest("speed", "https://speed.example/", speedCallbacks.value)
        assertEquals(
            mapOf(
                "bytes" to 1_048_576.0,
                "ttfbMillis" to 11.0,
                "downloadDurationMillis" to 70.0,
                "totalDurationMillis" to 91.0,
                "mbps" to 92.19,
            ),
            speedCallbacks.awaitResult(),
        )
        assertEquals(SpeedTestCall("https://speed.example/"), speed.speedTestCalls.single())

        val telemetryCallbacks = RecordingCallbacks()
        coordinator.sendTelemetryBatchJSON(
            "telemetry",
            "https://telemetry.example/",
            """{"events":[{"event":"speed_test"}]}""",
            telemetryCallbacks.value,
        )
        assertTrue(telemetryCallbacks.awaitResult().isEmpty())
        assertEquals(
            TelemetryCall(
                "https://telemetry.example/",
                """{"events":[{"event":"speed_test"}]}""",
            ),
            telemetry.telemetryCalls.single(),
        )

        val manifestCallbacks = RecordingCallbacks()
        coordinator.fetchManifestCandidate(
            "manifest",
            "https://broker.openrung.org/api/v1/app-manifest",
            manifestCallbacks.value,
        )
        assertEquals(
            mapOf(
                "bodyJson" to " \n{\"signed\":\"exact\"}\n",
                "sourceUrl" to "https://broker.openrung.org/api/v1/app-manifest",
            ),
            manifestCallbacks.awaitResult(),
        )
        assertEquals(
            ManifestCandidateCall("https://broker.openrung.org/api/v1/app-manifest"),
            manifest.manifestCandidateCalls.single(),
        )

        assertEquals(4, factory.createCalls.get())
        listOf(discovery, speed, telemetry, manifest).forEach { operation ->
            assertEquals(1, operation.closeCalls.get())
        }
        assertEquals(0, coordinator.activeRequestCount())
        coordinator.invalidate()
    }

    @Test
    fun `directory projection removes nested WSS URLs and preserves unknown fields`() {
        val secretWssUrl = "wss://front-secret.example/connect?ticket=must-not-cross"
        val operation = RecordingNativeBrokerOperation().apply {
            relayResult = NativeBrokerRelayResult(
                succeeded = true,
                brokerUrl = "https://broker.openrung.org/",
                relayJson =
                    """
                    {
                      "count": 1,
                      "server_time": "2026-07-26T00:00:00Z",
                      "future_root": {"mode": "preserved"},
                      "relays": [{
                        "id": "relay-a",
                        "future_relay": [1, 2, 3],
                        "wss_fronts": [{
                          "id": "front-a",
                          "url": "$secretWssUrl",
                          "protocol_version": 1
                        }]
                      }]
                    }
                    """.trimIndent(),
                signatureVerified = true,
            )
        }
        val coordinator =
            OpenRungBrokerRequestCoordinator(RecordingNativeBrokerOperationFactory(operation))
        val callbacks = RecordingCallbacks()

        coordinator.firstReachable(
            requestId = "directory-with-wss",
            primary = "https://broker.openrung.org/",
            limit = 5,
            clientId = "client-a",
            sessionId = "session-a",
            callbacks = callbacks.value,
        )

        val bridgedJson = callbacks.awaitResult()["relayJson"] as String
        assertFalse(bridgedJson.contains(secretWssUrl))
        assertFalse(bridgedJson.contains("wss_fronts"))
        val root = Json.parseToJsonElement(bridgedJson) as JsonObject
        assertEquals(
            JsonPrimitive("preserved"),
            (root["future_root"] as JsonObject)["mode"],
        )
        val relay = (root["relays"] as JsonArray).single() as JsonObject
        assertEquals(
            JsonArray(listOf(JsonPrimitive(1), JsonPrimitive(2), JsonPrimitive(3))),
            relay["future_relay"],
        )
        assertFalse(relay.containsKey("wss_fronts"))
        assertEquals(0, coordinator.activeRequestCount())
        coordinator.invalidate()
    }

    @Test
    fun `malformed relay projection rejects with local decode and cleans up`() {
        val operation = RecordingNativeBrokerOperation().apply {
            relayResult = NativeBrokerRelayResult(
                succeeded = true,
                brokerUrl = "https://broker.openrung.org/",
                relayJson = """{"relays":[{"wss_fronts":["wss://secret.example/"]}""",
                signatureVerified = true,
            )
        }
        val coordinator =
            OpenRungBrokerRequestCoordinator(RecordingNativeBrokerOperationFactory(operation))
        val callbacks = RecordingCallbacks()

        coordinator.firstReachable(
            requestId = "malformed-directory",
            primary = "https://broker.openrung.org/",
            limit = 5,
            clientId = "client-a",
            sessionId = "session-a",
            callbacks = callbacks.value,
        )

        val failure = callbacks.awaitFailure()
        assertEquals(BrokerNativeFailureKind.DECODE, failure.kind)
        assertFalse(failure.message.contains("secret.example"))
        assertEquals(1, operation.closeCalls.get())
        assertEquals(0, coordinator.activeRequestCount())
        coordinator.invalidate()
    }

    @Test
    fun `duplicate active request ID is rejected without touching the first request`() {
        val started = CountDownLatch(1)
        val release = CountDownLatch(1)
        val operation = RecordingNativeBrokerOperation().apply {
            telemetryBlock = {
                started.countDown()
                assertTrue(release.await(2, TimeUnit.SECONDS))
                NativeBrokerCommonResult(succeeded = true)
            }
        }
        val factory = RecordingNativeBrokerOperationFactory(operation)
        val coordinator = OpenRungBrokerRequestCoordinator(factory)
        val first = RecordingCallbacks()
        val duplicate = RecordingCallbacks()

        coordinator.sendTelemetryBatchJSON("same-id", "https://one.example/", "{}", first.value)
        assertTrue(started.await(2, TimeUnit.SECONDS))
        coordinator.sendTelemetryBatchJSON("same-id", "https://two.example/", "{}", duplicate.value)

        assertEquals(BrokerNativeFailureKind.VALIDATION, duplicate.awaitFailure().kind)
        assertEquals(1, factory.createCalls.get())
        assertEquals(1, coordinator.activeRequestCount())
        release.countDown()
        assertTrue(first.awaitResult().isEmpty())
        assertEquals(0, coordinator.activeRequestCount())
        coordinator.invalidate()
    }

    @Test
    fun `cancel is idempotent closes the operation and suppresses a racing success`() {
        val started = CountDownLatch(1)
        val release = CountDownLatch(1)
        val operation = RecordingNativeBrokerOperation().apply {
            telemetryBlock = {
                started.countDown()
                assertTrue(release.await(2, TimeUnit.SECONDS))
                NativeBrokerCommonResult(succeeded = true)
            }
            closeBlock = { release.countDown() }
        }
        val coordinator =
            OpenRungBrokerRequestCoordinator(RecordingNativeBrokerOperationFactory(operation))
        val callbacks = RecordingCallbacks()

        coordinator.sendTelemetryBatchJSON("cancel-me", "https://one.example/", "{}", callbacks.value)
        assertTrue(started.await(2, TimeUnit.SECONDS))
        assertTrue(coordinator.cancel("cancel-me"))
        assertFalse(coordinator.cancel("cancel-me"))

        assertEquals(BrokerNativeFailureKind.CANCELLED, callbacks.awaitFailure().kind)
        assertTrue(operation.closeCalls.get() >= 2)
        assertEquals(0, callbacks.resultCount())
        assertEquals(0, coordinator.activeRequestCount())
        coordinator.invalidate()
    }

    @Test
    fun `invalidate cancels and cleans every request and rejects later work as unavailable`() {
        val firstStarted = CountDownLatch(1)
        val firstRelease = CountDownLatch(1)
        val secondStarted = CountDownLatch(1)
        val secondRelease = CountDownLatch(1)
        val firstOperation = RecordingNativeBrokerOperation().apply {
            telemetryBlock = {
                firstStarted.countDown()
                firstRelease.await(2, TimeUnit.SECONDS)
                NativeBrokerCommonResult(succeeded = true)
            }
            closeBlock = { firstRelease.countDown() }
        }
        val secondOperation = RecordingNativeBrokerOperation().apply {
            speedTestBlock = {
                secondStarted.countDown()
                secondRelease.await(2, TimeUnit.SECONDS)
                NativeBrokerSpeedTestResult(succeeded = true)
            }
            closeBlock = { secondRelease.countDown() }
        }
        val factory = RecordingNativeBrokerOperationFactory(firstOperation, secondOperation)
        val coordinator = OpenRungBrokerRequestCoordinator(factory)
        val first = RecordingCallbacks()
        val second = RecordingCallbacks()

        coordinator.sendTelemetryBatchJSON("first", "https://one.example/", "{}", first.value)
        assertTrue(firstStarted.await(2, TimeUnit.SECONDS))
        coordinator.runSpeedTest("second", "https://two.example/", second.value)
        assertTrue(secondStarted.await(2, TimeUnit.SECONDS))

        coordinator.invalidate()

        assertEquals(BrokerNativeFailureKind.CANCELLED, first.awaitFailure().kind)
        assertEquals(BrokerNativeFailureKind.CANCELLED, second.awaitFailure().kind)
        assertTrue(firstOperation.closeCalls.get() >= 2)
        assertTrue(secondOperation.closeCalls.get() >= 2)
        assertEquals(0, coordinator.activeRequestCount())

        val later = RecordingCallbacks()
        coordinator.sendTelemetryBatchJSON("later", "https://later.example/", "{}", later.value)
        assertEquals(BrokerNativeFailureKind.UNAVAILABLE, later.awaitFailure().kind)
        assertEquals(2, factory.createCalls.get())
    }

    @Test
    fun `cancelling one concurrent request does not close or settle another`() {
        val firstStarted = CountDownLatch(1)
        val firstRelease = CountDownLatch(1)
        val secondStarted = CountDownLatch(1)
        val secondRelease = CountDownLatch(1)
        val firstOperation = RecordingNativeBrokerOperation().apply {
            telemetryBlock = {
                firstStarted.countDown()
                firstRelease.await(2, TimeUnit.SECONDS)
                NativeBrokerCommonResult(succeeded = true)
            }
            closeBlock = { firstRelease.countDown() }
        }
        val secondOperation = RecordingNativeBrokerOperation().apply {
            telemetryBlock = {
                secondStarted.countDown()
                secondRelease.await(2, TimeUnit.SECONDS)
                NativeBrokerCommonResult(succeeded = true)
            }
        }
        val coordinator = OpenRungBrokerRequestCoordinator(
            RecordingNativeBrokerOperationFactory(firstOperation, secondOperation),
        )
        val first = RecordingCallbacks()
        val second = RecordingCallbacks()

        coordinator.sendTelemetryBatchJSON("first", "https://one.example/", "{}", first.value)
        assertTrue(firstStarted.await(2, TimeUnit.SECONDS))
        coordinator.sendTelemetryBatchJSON("second", "https://two.example/", "{}", second.value)
        assertTrue(secondStarted.await(2, TimeUnit.SECONDS))

        assertTrue(coordinator.cancel("first"))
        assertEquals(BrokerNativeFailureKind.CANCELLED, first.awaitFailure().kind)
        assertEquals(0, secondOperation.closeCalls.get())
        assertEquals(0, second.failureCount())

        secondRelease.countDown()
        assertTrue(second.awaitResult().isEmpty())
        assertEquals(1, secondOperation.closeCalls.get())
        assertEquals(0, coordinator.activeRequestCount())
        coordinator.invalidate()
    }

    @Test
    fun `structured native failures preserve status retry and sanitized message`() {
        val operation = RecordingNativeBrokerOperation().apply {
            telemetryResult = NativeBrokerCommonResult(
                succeeded = false,
                errorKind = "rate_limited",
                errorText = "retry\r\nlater",
                httpStatus = 429,
                retryAfterMillis = 2_500,
            )
        }
        val coordinator =
            OpenRungBrokerRequestCoordinator(RecordingNativeBrokerOperationFactory(operation))
        val callbacks = RecordingCallbacks()

        coordinator.sendTelemetryBatchJSON("failure", "https://one.example/", "{}", callbacks.value)

        val failure = callbacks.awaitFailure()
        assertEquals(BrokerNativeFailureKind.RATE_LIMITED, failure.kind)
        assertEquals(429, failure.httpStatus)
        assertEquals(2_500L, failure.retryAfterMillis)
        assertFalse(failure.message.contains('\r'))
        assertFalse(failure.message.contains('\n'))
        assertTrue(failure.message.toByteArray(Charsets.UTF_8).size <= 256)
        assertEquals(0, coordinator.activeRequestCount())
        coordinator.invalidate()
    }
}

private class RecordingCallbacks {
    private val results = LinkedBlockingQueue<Map<String, Any>>()
    private val failures = LinkedBlockingQueue<BrokerBridgeFailure>()

    val value = BrokerRequestCallbacks(
        resolve = results::add,
        reject = failures::add,
    )

    fun awaitResult(): Map<String, Any> {
        val result = results.poll(3, TimeUnit.SECONDS)
        assertNotNull("request did not resolve", result)
        return checkNotNull(result)
    }

    fun awaitFailure(): BrokerBridgeFailure {
        val failure = failures.poll(3, TimeUnit.SECONDS)
        assertNotNull("request did not reject", failure)
        return checkNotNull(failure)
    }

    fun resultCount(): Int = results.size

    fun failureCount(): Int = failures.size
}
