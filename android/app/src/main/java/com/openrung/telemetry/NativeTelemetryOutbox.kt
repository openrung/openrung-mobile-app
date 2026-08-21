package com.openrung.telemetry

import android.content.Context
import android.os.Build
import com.openrung.BuildConfig
import com.openrung.net.NativeBrokerResult
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.OpenRungTelemetryFlushResult
import io.nekohasekai.libbox.OpenRungTelemetryOutbox

/**
 * Boundary to the bound native telemetry outbox — the shared Go implementation that owns the
 * on-disk NDJSON queue, its cap and compaction, the pre-upgrade backlog migration, and the
 * identity-homogeneous upload batching (`android/punchbridge/telemetry_binding.go`). A seam so
 * JVM tests, which cannot load the gomobile engine, can install a fake; the queue policy itself
 * is pinned by the Go suite against the real binding.
 */
interface TelemetryOutboxHandle {
    /** Persists one event (a [TelemetryEvent] as JSON); false when the event was undecodable. */
    fun enqueue(eventJson: String): Boolean

    /**
     * One-time import of a legacy JSON-array backlog. Returns the accepted count once the events
     * are DURABLY persisted, 0 for a blob holding nothing importable (import complete), and -1
     * when nothing durable landed — the caller must keep its copy for a later retry.
     */
    fun enqueueBatch(eventsJson: String): Int

    /** Back-patches attributes onto the queued events of one session (the geo patch). */
    fun applySessionAttributes(sessionId: String, attributesJson: String)

    /**
     * Prepares one single-use, cancelable upload attempt. The manager creates one per request
     * and closes it from its cancellation handler; the begin/close gate lives inside the bound
     * upload's own mutex, so a close that lands before the request begins wins and the native
     * call never starts — a terminal flush deadline is never held hostage by an unresponsive
     * broker, whichever side of the start the cancellation lands on.
     */
    fun beginUpload(): TelemetryUploadHandle
}

/** One single-use, cancelable native upload (see [TelemetryOutboxHandle.beginUpload]). */
interface TelemetryUploadHandle {
    /**
     * Uploads at most one batch from the queue head, removing it on success. Blocking network
     * I/O — call on a worker dispatcher. The caller loops with a fresh upload per batch until
     * [NativeTelemetryFlushResult.pendingCount] reaches zero, keeping cancellation between
     * requests.
     */
    fun flushNextBatch(brokerUrl: String): NativeTelemetryFlushResult

    /**
     * Uploads one heartbeat, letting the queue head piggyback only when it carries the
     * heartbeat's own client/session identity. Blocking network I/O.
     */
    fun sendHeartbeat(brokerUrl: String, heartbeatJson: String): NativeTelemetryFlushResult

    /**
     * Idempotent: cancels a blocked request (which returns promptly with the cancelled outcome
     * and commits nothing), prevents a not-yet-started one from ever starting, and waits until
     * any in-flight attempt has returned. The outbox itself stays open.
     */
    fun close()
}

/**
 * One native flush outcome. Implements [NativeBrokerResult] so failures convert through the same
 * bounded [com.openrung.net.BrokerNativeFailure] contract as every other native broker call.
 */
data class NativeTelemetryFlushResult(
    override val succeeded: Boolean,
    override val errorKind: String = "",
    override val errorText: String = "",
    override val httpStatus: Int = 0,
    override val retryAfterMillis: Long = 0,
    val pendingCount: Int = 0,
) : NativeBrokerResult

/**
 * Boundary for every generated call, not only construction: a partially stale
 * native artifact can expose the constructor yet lack a newer method, so each
 * interaction with the gomobile engine degrades to the unavailable path
 * instead of throwing a LinkageError out of a telemetry call site — which is
 * often a failure handler. Mirrors NativeBrokerTransport.generatedCall.
 */
private inline fun <T> generatedTelemetryCall(fallback: T, call: () -> T): T = try {
    call()
} catch (error: LinkageError) {
    fallback
}

private val unavailableNativeTelemetryFlushResult =
    NativeTelemetryFlushResult(succeeded = false, errorKind = "unavailable")

/** Production handle over the gomobile outbox object. */
internal class NativeTelemetryOutbox(context: Context) : TelemetryOutboxHandle {
    private val outbox: OpenRungTelemetryOutbox? = try {
        Libbox.newOpenRungTelemetryOutboxForAndroid(
            context.filesDir.absolutePath,
            OUTBOX_FILE_NAME,
            BuildConfig.VERSION_NAME,
            Build.VERSION.SDK_INT.toString(),
        )
    } catch (error: LinkageError) {
        // The gomobile engine can be unloadable (a missing ABI split, a stale
        // install). Telemetry must degrade to the unavailable path, never take
        // down the service — record() runs inside failure handlers where a
        // throw would replace the real error. Mirrors NativeBrokerTransport's
        // constructor seam.
        null
    }

    override fun enqueue(eventJson: String): Boolean =
        generatedTelemetryCall(false) { outbox?.enqueue(eventJson) ?: false }

    override fun enqueueBatch(eventsJson: String): Int =
        // An unavailable binding never confirms durability: keep the caller's copy.
        generatedTelemetryCall(-1) { outbox?.enqueueBatchJSON(eventsJson) ?: -1 }

    override fun applySessionAttributes(sessionId: String, attributesJson: String) {
        generatedTelemetryCall(Unit) { outbox?.applySessionAttributes(sessionId, attributesJson) ?: Unit }
    }

    override fun beginUpload(): TelemetryUploadHandle =
        NativeUpload(generatedTelemetryCall(null) { outbox?.beginUpload() })

    private class NativeUpload(
        private val upload: io.nekohasekai.libbox.OpenRungTelemetryUpload?,
    ) : TelemetryUploadHandle {
        override fun flushNextBatch(brokerUrl: String): NativeTelemetryFlushResult =
            generatedTelemetryCall(unavailableNativeTelemetryFlushResult) {
                upload?.flushNextBatch(brokerUrl).toFlushResult()
            }

        override fun sendHeartbeat(brokerUrl: String, heartbeatJson: String): NativeTelemetryFlushResult =
            generatedTelemetryCall(unavailableNativeTelemetryFlushResult) {
                upload?.sendHeartbeat(brokerUrl, heartbeatJson).toFlushResult()
            }

        override fun close() {
            generatedTelemetryCall(Unit) { upload?.close() ?: Unit }
        }
    }

    companion object {
        /** The NDJSON outbox the pre-binding Kotlin manager wrote; same name, so no migration. */
        const val OUTBOX_FILE_NAME = "openrung_telemetry_outbox.jsonl"
    }
}

private fun OpenRungTelemetryFlushResult?.toFlushResult(): NativeTelemetryFlushResult {
    if (this == null) {
        return NativeTelemetryFlushResult(succeeded = false, errorKind = "unavailable")
    }
    return NativeTelemetryFlushResult(
        succeeded = succeeded(),
        errorKind = errorKind(),
        errorText = errorText(),
        httpStatus = httpStatus(),
        retryAfterMillis = retryAfterMillis(),
        pendingCount = pendingCount(),
    )
}
