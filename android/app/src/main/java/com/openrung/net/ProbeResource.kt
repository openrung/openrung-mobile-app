package com.openrung.net

import kotlinx.coroutines.*

/** Close a blocking socket on cancellation, and join its worker before returning to Go. */
internal suspend fun <T, R> withProbeResource(open: () -> T, close: (T) -> Unit, exchange: (T) -> R): R = coroutineScope {
    val resource = open()
    val closer = launch(Dispatchers.IO, start = CoroutineStart.UNDISPATCHED) {
        try { awaitCancellation() } finally { close(resource) }
    }
    try {
        withContext(Dispatchers.IO) {
            try { exchange(resource) } catch (error: Exception) {
                // Socket.close wakes blocking I/O with SocketException. Preserve
                // cancellation so it cannot be reported as a remote path failure.
                currentCoroutineContext().ensureActive()
                throw error
            }
        }
    } finally {
        withContext(NonCancellable) { closer.cancelAndJoin() }
    }
}
