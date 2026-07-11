package com.openrung.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.time.Instant

object RelayConstants {
    const val PROTOCOL_VLESS_REALITY_VISION = "vless-reality-vision"
    const val FLOW_VISION = "xtls-rprx-vision"
    const val EXIT_MODE_DIRECT = "direct"
}

@Serializable
data class RelayDescriptor(
    val id: String,
    /** Volunteer-chosen relay name (e.g. "silly-lemur"); empty on older brokers. */
    val label: String = "",
    @SerialName("public_host")
    val publicHost: String,
    @SerialName("public_port")
    val publicPort: Int,
    @SerialName("protocol")
    val relayProtocol: String,
    @SerialName("client_id")
    val clientId: String,
    @SerialName("reality_public_key")
    val realityPublicKey: String,
    @SerialName("short_id")
    val shortId: String,
    @SerialName("server_name")
    val serverName: String,
    val flow: String,
    @SerialName("exit_mode")
    val exitMode: String,
    @SerialName("max_sessions")
    val maxSessions: Int,
    @SerialName("max_mbps")
    val maxMbps: Int,
    @SerialName("volunteer_version")
    val volunteerVersion: String,
    /** "direct" for ordinary volunteers, "tunnel" when publicHost is a RelayHub. */
    val transport: String = "",
    /** Whether the tunnel volunteer and its hub negotiated direct NAT punching. */
    @SerialName("punch_capable")
    val punchCapable: Boolean = false,
    /** HTTPS base URL of the hub's punch coordinator; supplied by the signed directory. */
    @SerialName("punch_endpoint")
    val punchEndpoint: String = "",
    @SerialName("registered_at")
    val registeredAt: String,
    @SerialName("last_heartbeat_at")
    val lastHeartbeatAt: String,
    @SerialName("expires_at")
    val expiresAt: String,
    // Broker-served exit location, absent until the broker's geo lookup succeeds (older brokers
    // never send it). For tunnel (CGNAT) relays this is where traffic actually exits, which is
    // NOT publicHost (the relay hub) — never geolocate publicHost client-side.
    val city: String = "",
    val country: String = "",
    @SerialName("country_code")
    val countryCode: String = "",
    val latitude: Double? = null,
    val longitude: Double? = null,
) {
    fun isUsable(now: Instant): Boolean {
        val expires = runCatching { Instant.parse(expiresAt) }.getOrNull() ?: return false
        return relayProtocol == RelayConstants.PROTOCOL_VLESS_REALITY_VISION &&
            flow == RelayConstants.FLOW_VISION &&
            exitMode == RelayConstants.EXIT_MODE_DIRECT &&
            expires > now &&
            publicHost.isNotBlank() &&
            publicPort > 0 &&
            clientId.isNotBlank() &&
            realityPublicKey.isNotBlank() &&
            shortId.isNotBlank() &&
            serverName.isNotBlank()
    }

    /** Human-readable exit location such as "Tokyo, Japan", or "" while the broker has no geo. */
    fun locationLabel(): String = listOf(city, country).filter { it.isNotBlank() }.joinToString(", ")
}

@Serializable
data class RelayListResponse(
    val count: Int,
    @SerialName("server_time")
    val serverTime: String,
    val relays: List<RelayDescriptor>,
    // Relay-list signing fields (SPEC v1 §2.2). They live inside the signed body — not in
    // headers — so an attacker cannot rewrite freshness or channel binding without breaking the
    // signature. Defaults cover pre-signing brokers, which only ever reach the parser on the
    // signature-exempt loopback dev path (see com.openrung.net.RelayListVerifier).
    /** RFC3339 expiry of this snapshot: `server_time` + 30 min on the API channel. */
    @SerialName("not_after")
    val notAfter: String = "",
    /** Advisory id (first 8 SHA-256 bytes of the signing pubkey, hex) — routing hint only. */
    @SerialName("key_id")
    val keyId: String = "",
    /** "api" or "mirror"; verified to match the channel the response was fetched from. */
    val channel: String = "",
    /** API channel: echo of the requested `limit`, verified to kill variant steering. */
    val limit: Int? = null,
) {
    val serverInstant: Instant
        get() = Instant.parse(serverTime)
}

@Serializable
data class ErrorResponse(
    val error: String = "",
)
