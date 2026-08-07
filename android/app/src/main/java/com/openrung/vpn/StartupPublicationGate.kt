package com.openrung.vpn

import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/**
 * The single startup gate for visible CONNECTED publication. A failed or superseded tunnel
 * startup never invokes [publishConnected]; callers receive the original failure instead.
 */
internal suspend fun <T> publishConnectedAfterVerifiedStartup(
    startAndVerify: suspend () -> T,
    publishConnected: (T) -> Unit,
): T {
    val verified = startAndVerify()
    currentCoroutineContext().ensureActive()
    publishConnected(verified)
    return verified
}
