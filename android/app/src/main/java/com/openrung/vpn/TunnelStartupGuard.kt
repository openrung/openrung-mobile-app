package com.openrung.vpn

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.selects.select

/** Races the initial through-tunnel probe against the local engine's stop signal. */
internal suspend fun <T> awaitStartupProbeOrEngineStop(
    probe: suspend () -> T,
    awaitUnexpectedEngineStop: suspend () -> String,
): T = coroutineScope {
    // Result wrappers prevent an expected probe/monitor error from cancelling the sibling before
    // policy can resolve a simultaneous-ready tie. UNDISPATCHED also registers both waiters before
    // select, including already-completed engine signals.
    val probeResult = async(start = CoroutineStart.UNDISPATCHED) {
        try {
            Result.success(probe())
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            Result.failure(error)
        }
    }
    val engineStopped = async(start = CoroutineStart.UNDISPATCHED) {
        try {
            Result.success(awaitUnexpectedEngineStop())
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            Result.failure(error)
        }
    }

    fun throwEngineStop(result: Result<String>): Nothing {
        result.exceptionOrNull()?.let { throw LocalTunnelException("engine_monitor", it) }
        throw LocalTunnelException(
            "engine_stopped_during_probe",
            EngineStartException(result.getOrThrow(), null),
        )
    }

    try {
        select {
            probeResult.onAwait { result ->
                // select does not promise clause priority. If both children are ready, the local
                // engine stop must beat a remote-looking probe failure and prevent ticket minting.
                if (engineStopped.isCompleted) throwEngineStop(engineStopped.await())
                result.getOrThrow()
            }
            engineStopped.onAwait(::throwEngineStop)
        }
    } finally {
        probeResult.cancel()
        engineStopped.cancel()
    }
}
