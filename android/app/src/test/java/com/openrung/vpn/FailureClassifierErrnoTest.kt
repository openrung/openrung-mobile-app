package com.openrung.vpn

import android.app.Application
import android.system.ErrnoException
import android.system.OsConstants
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.net.ConnectException

/**
 * Errno-based classifier cases. These need real `android.system.OsConstants` values and a working
 * [ErrnoException] constructor, which a plain stubbed `android.jar` does not provide (every
 * OsConstants value reads as 0 there) — so they run under Robolectric. The rest of the classifier's
 * behavior is covered by the plain-JUnit [FailureClassifierTest].
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

    @Test
    fun `ECONNREFUSED in the cause chain classifies as connection_refused`() {
        assertEquals("connection_refused", FailureClassifier.classify(wrapped(OsConstants.ECONNREFUSED)))
    }

    @Test
    fun `ECONNRESET classifies as connection_reset`() {
        assertEquals("connection_reset", FailureClassifier.classify(wrapped(OsConstants.ECONNRESET)))
    }

    @Test
    fun `ENETUNREACH and EHOSTUNREACH classify as network_unreachable`() {
        assertEquals("network_unreachable", FailureClassifier.classify(wrapped(OsConstants.ENETUNREACH)))
        assertEquals("network_unreachable", FailureClassifier.classify(wrapped(OsConstants.EHOSTUNREACH)))
    }

    @Test
    fun `ETIMEDOUT classifies as timeout`() {
        // Not handled by the errno refused/reset/unreachable switch; falls through to generic timeout.
        assertEquals("timeout", FailureClassifier.classify(wrapped(OsConstants.ETIMEDOUT)))
    }

    @Test
    fun `EACCES and EPERM classify as permission_denied`() {
        assertEquals("permission_denied", FailureClassifier.classify(errno(OsConstants.EACCES)))
        assertEquals("permission_denied", FailureClassifier.classify(errno(OsConstants.EPERM)))
    }

    @Test
    fun `errno root cause wins over an engine-start wrapper`() {
        // EngineStartException alone classifies as process_exited; the real ECONNREFUSED root cause
        // has higher precedence (socket errno before engine-exit), so it wins.
        val error = EngineStartException("engine failed", errno(OsConstants.ECONNREFUSED))
        assertEquals("connection_refused", FailureClassifier.classify(error))
    }
}
