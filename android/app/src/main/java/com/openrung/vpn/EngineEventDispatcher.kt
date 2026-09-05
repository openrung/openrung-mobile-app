package com.openrung.vpn

import io.nekohasekai.libbox.OpenRungEngineListener
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

/** A B1 callback copied onto the Android service queue before any native state changes. */
internal data class EngineEvent(val sequence: Long, val kind: String, val payload: JsonObject)

/**
 * Process-lifetime gomobile listener. [post] must enqueue asynchronously on the service queue;
 * neither parsing nor a receiver may run inline on the Go callback goroutine (it holds Go locks).
 *
 * Attach/detach run on that same queue. Before attaching a successor, the host must join the
 * previous engine Stop: this gate discards queued deliveries, not future callbacks from a run
 * the host left alive. Engine sequence numbers persist across service owners and sessions.
 */
internal class EngineEventDispatcher(
    private val post: (() -> Unit) -> Unit,
    private val onInvalidEvent: (String) -> Unit,
) : OpenRungEngineListener {
    private class Owner(val receive: (EngineEvent) -> Unit)
    @Volatile private var owner: Owner? = null
    private var lastSequence = 0L // service queue only

    fun attach(receive: (EngineEvent) -> Unit) {
        owner = Owner(receive)
    }

    fun detach() {
        owner = null
    }

    override fun onEvent(eventJSON: String?) {
        val destination = owner ?: return
        post {
            if (owner !== destination) return@post
            val event = runCatching { decode(eventJSON) }.getOrElse {
                // Diagnostic excludes payloads, which may contain connection details.
                onInvalidEvent("invalid connectcore event envelope")
                return@post
            }
            if (event.sequence <= lastSequence) return@post
            lastSequence = event.sequence
            destination.receive(event)
        }
    }

    private fun decode(raw: String?): EngineEvent {
        requireNotNull(raw)
        val envelope = Json.parseToJsonElement(raw) as? JsonObject ?: error("object required")
        require(envelope["version"]?.jsonPrimitive?.intOrNull == 1)
        val sequence = envelope["sequence"]?.jsonPrimitive?.longOrNull ?: error("sequence required")
        require(sequence > 0)
        val kind = envelope["kind"]?.jsonPrimitive?.contentOrNull ?: error("kind required")
        require(kind in setOf("state", "notice", "log"))
        val payload = envelope["payload"] as? JsonObject ?: error("payload required")
        return EngineEvent(sequence, kind, payload)
    }
}
