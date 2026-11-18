package com.openrung.widget

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.net.VpnService
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import androidx.core.content.ContextCompat
import com.openrung.config.AppConfig
import com.openrung.state.ConnectionStatus
import com.openrung.state.OpenRungStatusStore
import com.openrung.vpn.ConnectcoreProcessHost
import com.openrung.vpn.OpenRungVpnService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import java.util.Locale

/**
 * The home-screen widget's process-wide state (docs/ANDROID_WIDGET.md). The tunnel runs in this
 * process, so the widget follows [OpenRungStatusStore] directly and is redrawn the moment what it
 * shows changes; there is no reload budget to manage. Main thread only.
 */
object OpenRungWidget {
    private const val TAG = "OpenRungWidget"
    private const val PREFS = "openrung_widget"
    private const val KEY_LANGUAGE_TAG = "language_tag"

    /** How long a widget Connect shows Connecting before the engine has said anything. */
    internal const val PENDING_CONNECT_MS = 10_000L

    private val main = Handler(Looper.getMainLooper())
    private var started = false

    /** A widget Connect not yet answered: when it was made and the status it was made from. */
    private var pendingConnect: Pair<Long, ConnectionStatus>? = null
    private var connectedSince: Long? = null
    private var lastFace: WidgetFace? = null
    private var lastRendered: WidgetDisplay? = null

    /** Set when the system refused a background start; Connect then opens the app instead. */
    private var backgroundStartRefused = false

    /** Follows the status store for the life of the process. Called from `Application.onCreate`. */
    fun start(context: Context) {
        if (started) return
        started = true
        val app = context.applicationContext
        OpenRungStatusStore.initialize(app)
        CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate).launch {
            // Only what the widget shows; log lines (most emissions) never reach it.
            OpenRungStatusStore.uiState
                .map { listOf(it.status, it.relayName, it.relayLabel, it.recentRegions.firstOrNull()) }
                .distinctUntilChanged()
                .collect { render(app) }
        }
    }

    /** Redraws every placed widget when what it shows changed, or always with [force]. */
    fun render(context: Context, force: Boolean = false) {
        val display = currentDisplay(context)
        if (!force && display == lastRendered) return
        val manager = AppWidgetManager.getInstance(context) ?: return
        val ids = manager.getAppWidgetIds(ComponentName(context, ConnectWidgetProvider::class.java))
        if (ids.isEmpty()) return
        manager.updateAppWidget(ids, WidgetViews.build(context, display))
        lastRendered = display
    }

    /**
     * The widget's Connect: an automatically chosen relay (no country, no relay), and only while
     * nothing is up or starting. The service re-checks that on its queue (`onlyIfIdle`), so a tap
     * that races another connect never replaces it. Returns whether a start was requested.
     */
    fun requestConnect(context: Context): Boolean {
        val state = OpenRungStatusStore.uiState.value
        val face = WidgetFace.of(state.status, ConnectcoreProcessHost.isActive, pendingConnect != null)
        if (!face.offersConnect || VpnService.prepare(context) != null) {
            render(context)
            return false
        }
        val started = try {
            ContextCompat.startForegroundService(
                context,
                OpenRungVpnService.connectIntent(context, AppConfig.DEFAULT_BROKER_URL, onlyIfIdle = true),
            )
            true
        } catch (error: RuntimeException) {
            // ForegroundServiceStartNotAllowedException and kin: the next tap opens the app.
            Log.w(TAG, "background connect refused", error)
            backgroundStartRefused = true
            false
        }
        if (started) {
            backgroundStartRefused = false
            pendingConnect = SystemClock.elapsedRealtime() to state.status
            main.postDelayed({ render(context) }, PENDING_CONNECT_MS)
        }
        render(context)
        return started
    }

    /** The widget's Disconnect; a tap that finds no tunnel in this process only redraws. */
    fun requestDisconnect(context: Context) {
        if (ConnectcoreProcessHost.isActive) {
            try {
                context.startService(OpenRungVpnService.disconnectIntent(context))
            } catch (error: RuntimeException) {
                Log.w(TAG, "disconnect refused", error)
            }
        }
        render(context)
    }

    /** Mirrors the in-app language selection ('' = system); redraws only when it changed. */
    fun setLanguageTag(context: Context, tag: String) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (prefs.getString(KEY_LANGUAGE_TAG, "") == tag) return
        prefs.edit().putString(KEY_LANGUAGE_TAG, tag).apply()
        render(context)
    }

    private fun currentDisplay(context: Context): WidgetDisplay {
        val state = OpenRungStatusStore.uiState.value
        val now = SystemClock.elapsedRealtime()
        pendingConnect?.let { (at, from) ->
            if (state.status != from || now - at >= PENDING_CONNECT_MS) pendingConnect = null
        }
        val face = WidgetFace.of(state.status, ConnectcoreProcessHost.isActive, pendingConnect != null)
        if (face != WidgetFace.CONNECTED) {
            connectedSince = null
        } else if (lastFace != WidgetFace.CONNECTED || connectedSince == null) {
            connectedSince = now
        }
        lastFace = face
        val stored = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY_LANGUAGE_TAG, "").orEmpty()
        return WidgetDisplay(
            face = face,
            relay = if (face == WidgetFace.CONNECTED) WidgetRelay.line(state) else null,
            connectedSince = connectedSince,
            languageTag = WidgetLanguage.resolve(stored, Locale.getDefault().toLanguageTag()),
            connectsInBackground = !backgroundStartRefused && VpnService.prepare(context) == null,
        )
    }
}
