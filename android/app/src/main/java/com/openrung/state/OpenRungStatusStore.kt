package com.openrung.state

import android.content.Context
import com.openrung.config.AppConfig
import com.openrung.model.RecentNode
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.time.LocalTime
import java.time.format.DateTimeFormatter

object OpenRungStatusStore {
    private const val KEY_STATUS = "status"
    private const val KEY_BROKER_URL = "broker_url"
    private const val KEY_RELAY_LABEL = "relay_label"
    private const val KEY_LAST_ERROR = "last_error"
    private const val KEY_LOG_LINES = "log_lines"
    private const val KEY_RECENT_NODES = "recent_nodes"
    private const val MAX_LOG_LINES = 80

    private val timeFormatter = DateTimeFormatter.ofPattern("HH:mm:ss")
    private val json = Json { ignoreUnknownKeys = true }
    private val state = MutableStateFlow(OpenRungUiState(brokerUrl = AppConfig.DEFAULT_BROKER_URL))
    private var appContext: Context? = null

    val uiState: StateFlow<OpenRungUiState> = state.asStateFlow()

    // Live traffic samples ride a separate flow: they tick every ~2s while connected and are
    // deliberately NOT part of OpenRungUiState (whose every change is persisted to
    // SharedPreferences and re-emitted with the full log + recents payload).
    private val traffic = MutableStateFlow<TrafficStats?>(null)
    val trafficState: StateFlow<TrafficStats?> = traffic.asStateFlow()

    fun setTraffic(stats: TrafficStats) {
        traffic.value = stats
    }

    fun clearTraffic() {
        traffic.value = null
    }

    fun initialize(context: Context) {
        if (appContext != null) return
        appContext = context.applicationContext
        RuntimeLogStore.initialize(context.applicationContext)
        val prefs = context.getSharedPreferences(AppConfig.STATUS_PREFS, Context.MODE_PRIVATE)
        val restoredStatus = runCatching {
            ConnectionStatus.valueOf(prefs.getString(KEY_STATUS, ConnectionStatus.DISCONNECTED.name)!!)
        }.getOrDefault(ConnectionStatus.DISCONNECTED)
        state.value = OpenRungUiState(
            status = if (restoredStatus == ConnectionStatus.CONNECTED) ConnectionStatus.DISCONNECTED else restoredStatus,
            brokerUrl = prefs.getString(KEY_BROKER_URL, AppConfig.DEFAULT_BROKER_URL) ?: AppConfig.DEFAULT_BROKER_URL,
            // A cold start always reconnects fresh, so never restore a stale relay label (would leak a prior relay).
            relayLabel = null,
            lastError = prefs.getString(KEY_LAST_ERROR, null),
            logLines = prefs.getString(KEY_LOG_LINES, null)?.lines()?.filter { it.isNotBlank() }.orEmpty(),
            recentRegions = loadRecents(prefs.getString(KEY_RECENT_NODES, null)),
        )
    }

    fun setBrokerUrl(brokerUrl: String) {
        state.update { it.copy(brokerUrl = brokerUrl) }
        persist()
    }

    /** Updates only the relay label (e.g. resolved geo location) without emitting a status log line. */
    fun setRelayLabel(relayLabel: String?) {
        state.update { it.copy(relayLabel = relayLabel) }
        persist()
    }

    fun setStatus(
        status: ConnectionStatus,
        relayLabel: String? = state.value.relayLabel,
        lastError: String? = state.value.lastError,
    ) {
        state.update {
            it.copy(
                status = status,
                relayLabel = relayLabel,
                lastError = lastError,
            )
        }
        appendLog(status.label)
    }

    private val ConnectionStatus.label: String
        get() = appContext?.getString(labelResId) ?: name.lowercase()

    fun appendLog(message: String) {
        val timestamp = LocalTime.now().format(timeFormatter)
        state.update {
            it.copy(logLines = (it.logLines + "[$timestamp] $message").takeLast(MAX_LOG_LINES))
        }
        // Every live line is also scrubbed into the persisted runtime log (contract §3);
        // this captures libbox debug output routed through appendLog too.
        RuntimeLogStore.append(message)
        persist()
    }

    fun fail(message: String) {
        val context = appContext
        val logMessage = context?.getString(com.openrung.R.string.log_error_prefix, message) ?: "error: $message"
        RuntimeLogStore.append(logMessage)
        state.update {
            it.copy(
                status = ConnectionStatus.FAILED,
                lastError = message,
                relayLabel = null,
                logLines = (it.logLines + "[${LocalTime.now().format(timeFormatter)}] $logMessage")
                    .takeLast(MAX_LOG_LINES),
            )
        }
        persist()
    }

    fun clearError() {
        state.update { it.copy(lastError = null) }
        persist()
    }

    /**
     * Records a location the user just connected through so it appears in the "Recents" row.
     * Deduplicates by country (most recent first) and caps the list to [AppConfig.MAX_RECENTS].
     */
    fun recordRecent(node: RecentNode) {
        state.update { current ->
            val deduped = (listOf(node) + current.recentRegions.filterNot { it.countryCode == node.countryCode })
                .take(AppConfig.MAX_RECENTS)
            current.copy(recentRegions = deduped)
        }
        persist()
    }

    private fun loadRecents(serialized: String?): List<RecentNode> {
        if (serialized.isNullOrBlank()) return emptyList()
        return runCatching {
            json.decodeFromString(ListSerializer(RecentNode.serializer()), serialized)
        }.getOrDefault(emptyList())
    }

    private fun persist() {
        val context = appContext ?: return
        val current = state.value
        context.getSharedPreferences(AppConfig.STATUS_PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_STATUS, current.status.name)
            .putString(KEY_BROKER_URL, current.brokerUrl)
            .putString(KEY_RELAY_LABEL, current.relayLabel)
            .putString(KEY_LAST_ERROR, current.lastError)
            .putString(KEY_LOG_LINES, current.logLines.joinToString("\n"))
            .putString(KEY_RECENT_NODES, json.encodeToString(ListSerializer(RecentNode.serializer()), current.recentRegions))
            .apply()
    }
}
