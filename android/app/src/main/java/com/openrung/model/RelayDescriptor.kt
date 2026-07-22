package com.openrung.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerializationException
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.descriptors.buildClassSerialDescriptor
import kotlinx.serialization.descriptors.element
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.put
import java.time.Instant

object RelayConstants {
    const val PROTOCOL_VLESS_REALITY_VISION = "vless-reality-vision"
    const val FLOW_VISION = "xtls-rprx-vision"
    const val EXIT_MODE_DIRECT = "direct"
    const val TRANSPORT_DIRECT = "direct"
    const val NODE_CLASS_FOUNDATION = "foundation"
    const val NODE_CLASS_VOLUNTEER = "volunteer"
}

/** A signed WSS/CDN front advertised by the relay directory. */
@Serializable(with = WssFrontDescriptorSerializer::class)
data class WssFrontDescriptor(
    val id: String,
    val url: String,
    @SerialName("protocol_version")
    val protocolVersion: Int,
)

/**
 * Keeps top-level relay decoding forward-compatible while making the security-sensitive signed
 * front shape exact. Otherwise `ignoreUnknownKeys` would discard a front field before wsscore's
 * strict validator could see and reject it.
 */
object WssFrontDescriptorSerializer : KSerializer<WssFrontDescriptor> {
    override val descriptor: SerialDescriptor = buildClassSerialDescriptor(
        "com.openrung.model.WssFrontDescriptor",
    ) {
        element<String>("id")
        element<String>("url")
        element<Int>("protocol_version")
    }

    override fun serialize(encoder: Encoder, value: WssFrontDescriptor) {
        val jsonEncoder = encoder as? JsonEncoder
            ?: throw SerializationException("WSS fronts require JSON encoding")
        jsonEncoder.encodeJsonElement(
            buildJsonObject {
                put("id", value.id)
                put("url", value.url)
                put("protocol_version", value.protocolVersion)
            },
        )
    }

    override fun deserialize(decoder: Decoder): WssFrontDescriptor {
        val jsonDecoder = decoder as? JsonDecoder
            ?: throw SerializationException("WSS fronts require JSON decoding")
        val value = jsonDecoder.decodeJsonElement() as? JsonObject
            ?: throw SerializationException("WSS front must be an object")
        val unknown = value.keys - ALLOWED_KEYS
        if (unknown.isNotEmpty()) {
            throw SerializationException("WSS front contains unknown fields: ${unknown.sorted()}")
        }

        fun requiredString(name: String): String {
            val primitive = value[name] as? JsonPrimitive
            if (primitive == null || !primitive.isString) {
                throw SerializationException("WSS front $name must be a string")
            }
            return primitive.content
        }

        val protocol = value["protocol_version"] as? JsonPrimitive
        if (protocol == null || protocol.isString || protocol.intOrNull == null) {
            throw SerializationException("WSS front protocol_version must be an integer")
        }
        return WssFrontDescriptor(
            id = requiredString("id"),
            url = requiredString("url"),
            protocolVersion = checkNotNull(protocol.intOrNull),
        )
    }

    private val ALLOWED_KEYS = setOf("id", "url", "protocol_version")
}

@Serializable
data class RelayDescriptor(
    val id: String,
    /** Friendly relay name (operator-supplied or generated); empty on older brokers. */
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
    /** Software version for any relay class; serialized name preserves the legacy broker wire field. */
    @SerialName("volunteer_version")
    val relayVersion: String,
    /** Trust class assigned by the signed directory; older descriptors are volunteer relays. */
    @SerialName("node_class")
    val nodeClass: String = RelayConstants.NODE_CLASS_VOLUNTEER,
    /** "direct" when clients reach this relay directly, "tunnel" when publicHost is a RelayHub. */
    val transport: String = "",
    /** Canonical, unique, sorted WSS/CDN fronts covered by the directory signature. */
    @SerialName("wss_fronts")
    val wssFronts: List<WssFrontDescriptor> = emptyList(),
    /** Whether the tunnel relay and its hub negotiated direct NAT punching. */
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
