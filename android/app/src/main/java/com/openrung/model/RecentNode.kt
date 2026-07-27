package com.openrung.model

import kotlinx.serialization.Serializable

/** A location the user has previously connected through, shown in the main-screen "Recents" row. */
@Serializable
data class RecentNode(
    val countryCode: String,
    val label: String,
    /** Friendly broker label, falling back to relay id; empty on entries saved by older builds. */
    val relayName: String = "",
    val latitude: Double,
    val longitude: Double,
)
