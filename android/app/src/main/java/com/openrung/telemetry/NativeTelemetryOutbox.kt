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

    fun pendingCount(): Int

    /**
     * Uploads at most one batch from the queue head, removing it on success. Blocking network
     * I/O — call on a worker dispatcher. The caller loops until [NativeTelemetryFlushResult
     * .pendingCount] reaches zero, keeping cancellation between requests.
     */
    fun flushNextBatch(brokerUrl: String): NativeTelemetryFlushResult

    /**
     * Uploads one heartbeat, letting the queue head piggyback only when it carries the
     * heartbeat's own client/session identity. Blocking network I/O.
     */
    fun sendHeartbeat(brokerUrl: String, heartbeatJson: String): NativeTelemetryFlushResult

    /**
     * Cancels every in-flight upload without closing the outbox: blocked [flushNextBatch] and
     * [sendHeartbeat] calls return promptly with the cancelled outcome and commit nothing.
     * Called from the manager's cancellation handler so a terminal flush deadline is never held
     * hostage by an unresponsive broker.
     */
    fun abortUploads()
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
    val sentCount: Int = 0,
    val pendingCount: Int = 0,
) : NativeBrokerResult

/** Production handle over the gomobile outbox object. */
internal class NativeTelemetryOutbox(context: Context) : TelemetryOutboxHandle {
    private val outbox: OpenRungTelemetryOutbox? = Libbox.newOpenRungTelemetryOutboxForAndroid(
        context.filesDir.absolutePath,
        OUTBOX_FILE_NAME,
        BuildConfig.VERSION_NAME,
        Build.VERSION.SDK_INT.toString(),
    )

    override fun enqueue(eventJson: String): Boolean = outbox?.enqueue(eventJson) ?: false

    override fun enqueueBatch(eventsJson: String): Int =
        // An unavailable binding never confirms durability: keep the caller's copy.
        outbox?.enqueueBatchJSON(eventsJson) ?: -1

    override fun applySessionAttributes(sessionId: String, attributesJson: String) {
        outbox?.applySessionAttributes(sessionId, attributesJson)
    }

    override fun pendingCount(): Int = outbox?.pendingCount() ?: 0

    override fun flushNextBatch(brokerUrl: String): NativeTelemetryFlushResult =
        outbox?.flushNextBatch(brokerUrl).toFlushResult()

    override fun sendHeartbeat(brokerUrl: String, heartbeatJson: String): NativeTelemetryFlushResult =
        outbox?.sendHeartbeat(brokerUrl, heartbeatJson).toFlushResult()

    override fun abortUploads() {
        outbox?.abortUploads()
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
            sentCount = sentCount(),
            pendingCount = pendingCount(),
        )
    }

    companion object {
        /** The NDJSON outbox the pre-binding Kotlin manager wrote; same name, so no migration. */
        const val OUTBOX_FILE_NAME = "openrung_telemetry_outbox.jsonl"
    }
}
