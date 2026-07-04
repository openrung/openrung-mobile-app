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
    val brokerUrl: String = "",
    val relayLabel: String? = null,
    val lastError: String? = null,
    val logLines: List<String> = emptyList(),
    val recentRegions: List<RecentNode> = emptyList(),
) {
    val isWorking: Boolean
        get() = status == ConnectionStatus.PREPARING ||
            status == ConnectionStatus.CONNECTING ||
            status == ConnectionStatus.DISCONNECTING

    val isConnected: Boolean
        get() = status == ConnectionStatus.CONNECTED
}
