package com.openrung.state

import androidx.annotation.StringRes
import com.openrung.R
import com.openrung.model.RecentNode

enum class ConnectionStatus(@StringRes val labelResId: Int) {
    DISCONNECTED(R.string.status_disconnected),
    PREPARING(R.string.status_preparing),
    CONNECTING(R.string.status_connecting),
    CONNECTED(R.string.status_connected),
    DISCONNECTING(R.string.status_disconnecting),
    FAILED(R.string.status_failed),
}

data class OpenRungUiState(
    val status: ConnectionStatus = ConnectionStatus.DISCONNECTED,
    val relayLabel: String? = null,
    val relayName: String? = null,
    /** Node class of the connected relay ("foundation" or "volunteer"); null unless CONNECTED. */
    val relayClass: String? = null,
    val lastError: String? = null,
    val logLines: List<String> = emptyList(),
    val recentRegions: List<RecentNode> = emptyList(),
)
