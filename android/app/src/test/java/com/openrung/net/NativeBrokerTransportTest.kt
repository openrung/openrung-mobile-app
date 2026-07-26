package com.openrung.net

import android.os.Build
import com.openrung.BuildConfig
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.coroutines.CoroutineContext

class NativeBrokerTransportTest {
    @Test
    fun `Android factory selects production app and API metadata without loading Go`() {
        val operation = RecordingNativeBrokerOperation()
        var metadata: Pair<String, String>? = null
        val factory = AndroidNativeBrokerOperationFactory(
            constructor = AndroidBrokerOperationConstructor { appVersion, apiLevel ->
                metadata = appVersion to apiLevel
                operation
            },
        )

        assertSame(operation, factory.create())
        assertEquals(BuildConfig.VERSION_NAME to Build.VERSION.SDK_INT.toString(), metadata)
    }

    @Test
    fun `React Native factory selects production app and Android token without loading Go`() {
        val operation = RecordingNativeBrokerOperation()
        var metadata: Pair<String, String>? = null
        val factory = AndroidReactNativeBrokerOperationFactory(
            constructor = ReactNativeBrokerOperationConstructor { appVersion, osToken ->
                metadata = appVersion to osToken
                operation
            },
        )

        assertSame(operation, factory.create())
        assertEquals(BuildConfig.VERSION_NAME to "android", metadata)
    }

    @Test
    fun `React Native factory maps stale binding linkage to unavailable without fallback`() {
        val factory = AndroidReactNativeBrokerOperationFactory(
            constructor = ReactNativeBrokerOperationConstructor { _, _ ->
                throw NoSuchMethodError("stale React Native constructor")
            },
            appVersion = "1.0",
        )

        val failure = try {
            factory.create()
            throw AssertionError("expected unavailable")
        } catch (error: BrokerNativeFailure) {
            error
        }
        assertEquals(BrokerNativeFailureKind.UNAVAILABLE, failure.kind)
        assertFalse(failure.message.orEmpty().contains("stale React Native constructor"))
    }

    @Test
    fun `speed and manifest snapshots retain all platform owned fields`() {
        val speed = NativeBrokerSpeedTestResult(
            succeeded = true,
            bytes = 1_048_576,
            ttfbMillis = 17,
            downloadDurationMillis = 81,
            totalDurationMillis = 101,
            mbps = 83.05,
        )
        val manifest = NativeBrokerManifestResult(
            succeeded = true,
            bodyJson = """{"payload":"exact"}""",
            sourceUrl = "https://broker.openrung.org/api/v1/app-manifest",
        )

        assertEquals(1_048_576L, speed.bytes)
        assertEquals(17L, speed.ttfbMillis)
        assertEquals(81L, speed.downloadDurationMillis)
        assertEquals(101L, speed.totalDurationMillis)
        assertEquals(83.05, speed.mbps, 0.0)
        assertEquals("""{"payload":"exact"}""", manifest.bodyJson)
        assertEquals("https://broker.openrung.org/api/v1/app-manifest", manifest.sourceUrl)
        assertFalse(manifest.toString().contains("exact"))
    }

    @Test
    fun `missing or stale AAR linkage is local unavailable with no fallback`() {
        val factory = AndroidNativeBrokerOperationFactory(
            constructor = AndroidBrokerOperationConstructor { _, _ ->
                throw UnsatisfiedLinkError("missing native constructor")
            },
            appVersion = "1.0",
            apiLevel = "36",
        )

        val failure = try {
            factory.create()
            throw AssertionError("expected unavailable")
        } catch (error: BrokerNativeFailure) {
            error
        }
        assertEquals(BrokerNativeFailureKind.UNAVAILABLE, failure.kind)
        assertTrue(failure.isLocalPlatformFailure)
        assertFalse(failure.message.orEmpty().contains("missing native constructor"))
    }

    @Test
    fun `blank and future error kinds normalize to unknown and text is sanitized bounded`() {
        listOf("", "future_kind").forEach { rawKind ->
            val result = NativeBrokerCommonResult(
                succeeded = false,
                errorKind = rawKind,
                errorText = "unsafe\r\n\t" + "😀".repeat(200),
            )
            val failure = try {
                requireNativeBrokerSuccess(result, "native request")
                throw AssertionError("expected failure")
            } catch (error: BrokerNativeFailure) {
                error
            }
            assertEquals(BrokerNativeFailureKind.UNKNOWN, failure.kind)
            assertFalse(failure.message.orEmpty().contains('\r'))
            assertFalse(failure.message.orEmpty().contains('\n'))
            assertTrue(failure.message.orEmpty().toByteArray(Charsets.UTF_8).size <= 256)
        }
    }

    @Test
    fun `cancellation before blocking invocation starts closes off Main`() = runBlocking {
        val dispatcher = GateFirstDispatchDispatcher()
        val closeThreads = mutableListOf<String>()
        val operation = RecordingNativeBrokerOperation().apply {
            telemetryResult = NativeBrokerCommonResult(succeeded = true)
            closeBlock = {
                synchronized(closeThreads) { closeThreads += Thread.currentThread().name }
                dispatcher.releaseFirst()
            }
        }
        val observed = CompletableDeferred<Throwable>()
        val request = launch(Dispatchers.Default) {
            try {
                runNativeBrokerOperation(
                    factory = RecordingNativeBrokerOperationFactory(operation),
                    ioDispatcher = dispatcher,
                ) {
                    it.sendTelemetryBatchJSON("https://broker.example/", """{"events":[]}""")
                }
            } catch (error: Throwable) {
                observed.complete(error)
                throw error
            }
        }

        assertTrue(dispatcher.firstScheduled.await(2, TimeUnit.SECONDS))
        request.cancel(CancellationException("cancel before native worker"))
        request.join()

        assertTrue(observed.await() is CancellationException)
        assertTrue(operation.telemetryCalls.isEmpty())
        assertTrue(operation.closeCalls.get() >= 2)
        assertTrue(closeThreads.all { it != "main" })
    }

    @Test
    fun `cancellation during blocked call dispatches Close and returns cancellation`() = runBlocking {
        val started = CountDownLatch(1)
        val released = CountDownLatch(1)
        val closeThreads = mutableListOf<String>()
        val operation = RecordingNativeBrokerOperation().apply {
            telemetryBlock = {
                started.countDown()
                assertTrue("Close did not unblock native call", released.await(2, TimeUnit.SECONDS))
                NativeBrokerCommonResult(succeeded = false, errorKind = "cancelled")
            }
            closeBlock = {
                synchronized(closeThreads) { closeThreads += Thread.currentThread().name }
                released.countDown()
            }
        }
        val observed = CompletableDeferred<Throwable>()
        val request = launch(Dispatchers.Default) {
            try {
                runNativeBrokerOperation(RecordingNativeBrokerOperationFactory(operation)) {
                    it.sendTelemetryBatchJSON("https://broker.example/", """{"events":[]}""")
                }
            } catch (error: Throwable) {
                observed.complete(error)
                throw error
            }
        }

        assertTrue(started.await(2, TimeUnit.SECONDS))
        request.cancel(CancellationException("disconnect"))
        request.join()

        assertTrue(observed.await() is CancellationException)
        assertTrue(operation.closeCalls.get() >= 2)
        assertTrue(closeThreads.isNotEmpty())
        assertTrue(closeThreads.all { it != "main" })
    }

    @Test
    fun `success racing cancellation cannot be committed`() = runBlocking {
        val ready = CountDownLatch(1)
        val allowReturn = CountDownLatch(1)
        val operation = RecordingNativeBrokerOperation().apply {
            telemetryBlock = {
                ready.countDown()
                assertTrue(allowReturn.await(2, TimeUnit.SECONDS))
                NativeBrokerCommonResult(succeeded = true)
            }
            closeBlock = { allowReturn.countDown() }
        }
        var committed = false
        val observed = CompletableDeferred<Throwable>()
        val request = launch(Dispatchers.Default) {
            try {
                runNativeBrokerOperation(RecordingNativeBrokerOperationFactory(operation)) {
                    it.sendTelemetryBatchJSON("https://broker.example/", """{"events":[]}""")
                }
                committed = true
            } catch (error: Throwable) {
                observed.complete(error)
                throw error
            }
        }

        assertTrue(ready.await(2, TimeUnit.SECONDS))
        request.cancel(CancellationException("cancel at native success"))
        allowReturn.countDown()
        request.join()

        assertTrue(observed.await() is CancellationException)
        assertFalse(committed)
        assertTrue(operation.closeCalls.get() >= 2)
    }

    @Test
    fun `cancelling one operation does not close or cancel another`() = runBlocking {
        val firstStarted = CountDownLatch(1)
        val firstReleased = CountDownLatch(1)
        val secondStarted = CountDownLatch(1)
        val secondReleased = CountDownLatch(1)
        val first = RecordingNativeBrokerOperation().apply {
            telemetryBlock = {
                firstStarted.countDown()
                firstReleased.await(2, TimeUnit.SECONDS)
                NativeBrokerCommonResult(succeeded = false, errorKind = "cancelled")
            }
            closeBlock = { firstReleased.countDown() }
        }
        val second = RecordingNativeBrokerOperation().apply {
            telemetryBlock = {
                secondStarted.countDown()
                secondReleased.await(2, TimeUnit.SECONDS)
                NativeBrokerCommonResult(succeeded = true)
            }
        }
        val firstRequest = launch(Dispatchers.Default) {
            runNativeBrokerOperation(RecordingNativeBrokerOperationFactory(first)) {
                it.sendTelemetryBatchJSON("https://one.example/", """{"events":[]}""")
            }
        }
        val secondResult = CompletableDeferred<NativeBrokerCommonResult?>()
        val secondRequest = launch(Dispatchers.Default) {
            secondResult.complete(
                runNativeBrokerOperation(RecordingNativeBrokerOperationFactory(second)) {
                    it.sendTelemetryBatchJSON("https://two.example/", """{"events":[]}""")
                },
            )
        }

        assertTrue(firstStarted.await(2, TimeUnit.SECONDS))
        assertTrue(secondStarted.await(2, TimeUnit.SECONDS))
        firstRequest.cancel()
        firstRequest.join()
        assertEquals(0, second.closeCalls.get())

        secondReleased.countDown()
        secondRequest.join()
        assertTrue(secondResult.await()?.succeeded == true)
        assertEquals(1, second.closeCalls.get())
    }

    @Test
    fun `ticket result snapshot string redacts both credential fields`() {
        val result = NativeBrokerWssTicketResult(
            succeeded = true,
            ticket = "secret-ticket",
            url = "wss://secret-front.example/path",
            expiresAtMillis = 123,
        ).toString()

        assertFalse(result.contains("secret-ticket"))
        assertFalse(result.contains("secret-front.example"))
        assertTrue(result.contains("ticket=<redacted>"))
        assertTrue(result.contains("url=<redacted>"))
    }
}

/**
 * Holds the first dispatched continuation and runs subsequent dispatches independently. It lets a
 * test cancel after operation creation but before the synchronous selector begins.
 */
private class GateFirstDispatchDispatcher : CoroutineDispatcher() {
    val firstScheduled = CountDownLatch(1)
    private val firstGate = CountDownLatch(1)
    private val dispatches = AtomicInteger()

    override fun dispatch(context: CoroutineContext, block: Runnable) {
        val index = dispatches.getAndIncrement()
        Thread(
            {
                if (index == 0) {
                    firstScheduled.countDown()
                    firstGate.await(2, TimeUnit.SECONDS)
                }
                block.run()
            },
            "native-broker-test-$index",
        ).start()
    }

    fun releaseFirst() {
        firstGate.countDown()
    }
}
