package com.openrung.net

/**
 * Closed taxonomy for establishment failures returned by the Go binding. Never forward the
 * binding's raw reason to telemetry: declined messages and future native values are unbounded.
 * Mirrors iOS `PunchNativeFailureReason` so `punch_failed.reason` stays identical across platforms.
 */
enum class PunchNativeFailureReason(val wireValue: String) {
    CLIENT("client"),
    CONFIGURATION("config"),
    SOCKET("socket"),
    SOCKET_PROTECTION("protect"),
    NONCE("nonce"),
    DISCOVERY("discovery"),
    REQUEST("request"),
    DECLINED("declined"),
    SESSION("session"),
    TOKEN("token"),
    CERTIFICATE("certificate"),
    PUNCH("punch"),
    QUIC("quic"),
    BRIDGE("bridge"),
    TRANSPORT("transport"),
    CANCELLED("cancelled");

    companion object {
        fun fromNative(nativeReason: String): PunchNativeFailureReason {
            val normalized = nativeReason.trim().lowercase()
            if (normalized.startsWith("declined:")) return DECLINED
            return when (normalized) {
                "client" -> CLIENT
                "config" -> CONFIGURATION
                "socket" -> SOCKET
                "protect" -> SOCKET_PROTECTION
                "nonce" -> NONCE
                "discovery" -> DISCOVERY
                "request" -> REQUEST
                "session" -> SESSION
                "token" -> TOKEN
                "certificate" -> CERTIFICATE
                "punch" -> PUNCH
                "quic" -> QUIC
                "bridge", "adapter" -> BRIDGE
                "cancelled" -> CANCELLED
                else -> TRANSPORT
            }
        }
    }
}
