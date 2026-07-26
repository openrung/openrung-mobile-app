package com.openrung.net

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class BrokerClientTest {
    @Test
    fun `discovery forwards primary limit and paired identity exactly and retains winner`() = runBlocking {
        val operation = RecordingNativeBrokerOperation().apply {
            relayResult = NativeBrokerRelayResult(
                succeeded = true,
                brokerUrl = "https://winner.example/",
                relayJson = RELAY_JSON,
                keyId = "verified-key",
                signatureVerified = true,
            )
        }
        val factory = RecordingNativeBrokerOperationFactory(operation)

        val fetch = BrokerClient.firstReachable(
            primary = " https://custom.example/base ",
            limit = 20,
            clientId = "client-a",
            sessionId = "session-a",
            operationFactory = factory,
        )

        assertEquals(
            FirstReachableCall(
                primary = " https://custom.example/base ",
                limit = 20,
                clientId = "client-a",
                sessionId = "session-a",
            ),
            operation.firstReachableCalls.single(),
        )
        assertEquals("https://winner.example/", fetch.brokerUrl)
        assertEquals(0, fetch.response.count)
        assertEquals("2026-07-26T00:00:00Z", fetch.response.serverTime)
        assertEquals(1, operation.closeCalls.get())
    }

    @Test
    fun `absent identity fields are forwarded as empty strings`() = runBlocking {
        val operation = RecordingNativeBrokerOperation().apply {
            relayResult = NativeBrokerRelayResult(
                succeeded = true,
                brokerUrl = "https://winner.example/",
                relayJson = RELAY_JSON,
            )
        }

        BrokerClient.firstReachable(
            primary = "",
            limit = 5,
            clientId = null,
            sessionId = null,
            operationFactory = RecordingNativeBrokerOperationFactory(operation),
        )

        assertEquals("", operation.firstReachableCalls.single().clientId)
        assertEquals("", operation.firstReachableCalls.single().sessionId)
    }

    @Test
    fun `malformed verified relay JSON is one local decode failure with no retry`() = runBlocking {
        val operation = RecordingNativeBrokerOperation().apply {
            relayResult = NativeBrokerRelayResult(
                succeeded = true,
                brokerUrl = "https://winner.example/",
                relayJson = "{\"count\":",
            )
        }
        val failure = assertSuspendThrows<BrokerNativeFailure> {
            BrokerClient.firstReachable(
                primary = "https://primary.example/",
                limit = 5,
                clientId = "client-a",
                sessionId = "session-a",
                operationFactory = RecordingNativeBrokerOperationFactory(operation),
            )
        }

        assertEquals(BrokerNativeFailureKind.DECODE, failure.kind)
        assertTrue(failure.isLocalPlatformFailure)
        assertEquals(1, operation.firstReachableCalls.size)
        assertEquals(1, operation.closeCalls.get())
        assertTrue(!failure.message.orEmpty().contains("{\"count\":"))
    }

    @Test
    fun `failed native discovery retains typed structured fields`() = runBlocking {
        val operation = RecordingNativeBrokerOperation().apply {
            relayResult = NativeBrokerRelayResult(
                succeeded = false,
                errorKind = "http_status",
                errorText = "front unavailable",
                httpStatus = 503,
                retryAfterMillis = 7_000,
            )
        }
        val failure = assertSuspendThrows<BrokerNativeFailure> {
            BrokerClient.firstReachable(
                primary = "https://primary.example/",
                limit = 5,
                clientId = null,
                sessionId = null,
                operationFactory = RecordingNativeBrokerOperationFactory(operation),
            )
        }

        assertEquals(BrokerNativeFailureKind.HTTP_STATUS, failure.kind)
        assertEquals(503, failure.httpStatus)
        assertEquals(7_000L, failure.retryAfterMillis)
    }

    @Test
    fun `nil discovery result is local unavailable`() = runBlocking {
        val operation = RecordingNativeBrokerOperation().apply { relayResult = null }
        val failure = assertSuspendThrows<BrokerNativeFailure> {
            BrokerClient.firstReachable(
                primary = "https://primary.example/",
                limit = 5,
                clientId = null,
                sessionId = null,
                operationFactory = RecordingNativeBrokerOperationFactory(operation),
            )
        }

        assertEquals(BrokerNativeFailureKind.UNAVAILABLE, failure.kind)
        assertTrue(failure.isLocalPlatformFailure)
        assertEquals(1, operation.closeCalls.get())
    }

    @Test
    fun `factory creates exactly the supplied operation`() {
        val operation = RecordingNativeBrokerOperation()
        val factory = RecordingNativeBrokerOperationFactory(operation)
        assertSame(operation, factory.create())
        assertEquals(1, factory.createCalls.get())
    }

    companion object {
        private const val RELAY_JSON =
            """{"count":0,"server_time":"2026-07-26T00:00:00Z","relays":[]}"""
    }
}
