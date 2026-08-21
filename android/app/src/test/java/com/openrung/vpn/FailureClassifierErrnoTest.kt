package com.openrung.vpn

import android.app.Application
import android.system.ErrnoException
import android.system.OsConstants
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.net.ConnectException

/**
 * Errno-based adapter cases. These need real `android.system.OsConstants` values and a working
 * [ErrnoException] constructor, which a plain stubbed `android.jar` does not provide (every
 * OsConstants value reads as 0 there) — so they run under Robolectric. The rest of the adapter's
 * extraction is covered by the plain-JUnit [FailureClassifierTest]; the errno→token mapping itself
 * lives in the shared Go classifier and is pinned by `android/punchbridge/failure_binding_test.go`.
 *
 * `application = Application` keeps Robolectric from booting the real [com.openrung.MainApplication],
 * whose `onCreate` initializes React Native / SoLoader and can't run in a JVM unit test.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class FailureClassifierErrnoTest {

    private fun errno(code: Int): ErrnoException = ErrnoException("connect", code)

    /** Mirrors how Android surfaces a socket errno: a ConnectException with the errno as its cause. */
    private fun wrapped(code: Int): Throwable =
        ConnectException("failed to connect to /1.2.3.4:443").apply { initCause(errno(code)) }

    private fun facts(error: Throwable): JsonObject =
        Json.parseToJsonElement(FailureClassifier.describeFailure(error)).jsonObject

    private fun errnoFacts(code: Int): JsonObject = buildJsonObject { put("errno", code) }

    @Test
    fun `an errno in the cause chain is extracted as the raw platform number`() {
        // The binding runs in the same bionic libc namespace, so the number, not a symbol, is the
        // honest wire value. One row per condition the shared ladder distinguishes.
        listOf(
            OsConstants.ECONNREFUSED,
            OsConstants.ECONNRESET,
            OsConstants.ENETUNREACH,
            OsConstants.EHOSTUNREACH,
            OsConstants.ETIMEDOUT,
        ).forEach { code ->
            assertEquals("errno=$code", errnoFacts(code), facts(wrapped(code)))
        }
    }

    @Test
    fun `EACCES and EPERM are extracted like any other errno`() {
        // The shared ladder maps them to permission_denied at its permission rung; no
        // permission_denied fact is claimed here because no SecurityException is present.
        assertEquals(errnoFacts(OsConstants.EACCES), facts(errno(OsConstants.EACCES)))
        assertEquals(errnoFacts(OsConstants.EPERM), facts(errno(OsConstants.EPERM)))
    }

    @Test
    fun `an errno root cause is reported alongside an engine-start wrapper`() {
        // EngineStartException alone means engine-exit; a real ECONNREFUSED root cause has higher
        // precedence in the shared ladder (socket errno before engine-exit), so both facts go in
        // and the Go binding tests pin that the errno wins.
        val error = EngineStartException("engine failed", errno(OsConstants.ECONNREFUSED))
        assertEquals(
            buildJsonObject {
                put("errno", OsConstants.ECONNREFUSED)
                put("process_exited", true)
            },
            facts(error),
        )
    }

    @Test
    fun `dead local network errno beats an outer ConnectException and cannot unlock WSS`() {
        listOf(OsConstants.ENETDOWN, OsConstants.ENETUNREACH).forEach { code ->
            assertFalse("errno=$code", isGenuineRemoteDataPathFailure(wrapped(code)))
        }
    }

    @Test
    fun `only remote socket errnos remain eligible through a ConnectException wrapper`() {
        val eligible = listOf(
            OsConstants.ECONNABORTED,
            OsConstants.ECONNREFUSED,
            OsConstants.ECONNRESET,
            OsConstants.EHOSTUNREACH,
            OsConstants.ENETRESET,
            OsConstants.EPIPE,
            OsConstants.ETIMEDOUT,
        )
        eligible.forEach { code ->
            assertTrue("errno=$code", isGenuineRemoteDataPathFailure(wrapped(code)))
        }

        // A typed errno is authoritative: generic ConnectException must not turn any unrecognized
        // local/platform errno into a remote-path signal either.
        listOf(OsConstants.EADDRNOTAVAIL, OsConstants.ENONET).forEach { code ->
            assertFalse("errno=$code", isGenuineRemoteDataPathFailure(wrapped(code)))
        }
    }
}
