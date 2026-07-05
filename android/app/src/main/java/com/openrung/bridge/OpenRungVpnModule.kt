package com.openrung.bridge

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import androidx.core.content.ContextCompat
import com.facebook.react.bridge.ActivityEventListener
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.WritableMap
import com.facebook.react.modules.core.DeviceEventManagerModule
import com.facebook.react.modules.core.PermissionAwareActivity
import com.openrung.net.LatencyProber
import com.openrung.state.ConnectionStatus
import com.openrung.state.OpenRungStatusStore
import com.openrung.state.OpenRungUiState
import com.openrung.state.RuntimeLogStore
import com.openrung.state.TrafficStats
import com.openrung.telemetry.ClientIdentity
import com.openrung.telemetry.TelemetryManager
import com.openrung.vpn.OpenRungVpnService
import com.openrung.vpn.SplitTunnelConfig
import com.openrung.vpn.SplitTunnelMode
import com.openrung.vpn.SplitTunnelStore
import com.facebook.react.bridge.ReadableMap
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * Classic NativeModule implementing the OpenRungVpn bridge contract (docs/CONTRACT.md §3):
 * prepare/connect/disconnect/getState/getIdentity plus the `openrungStateChanged` event
 * mirroring [OpenRungStatusStore.uiState].
 */
class OpenRungVpnModule(
    private val reactContext: ReactApplicationContext,
) : ReactContextBaseJavaModule(reactContext), ActivityEventListener {

    private val moduleScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var preparePromise: Promise? = null

    init {
        reactContext.addActivityEventListener(this)
        OpenRungStatusStore.initialize(reactContext.applicationContext)
        TelemetryManager.initialize(reactContext.applicationContext)
        moduleScope.launch {
            OpenRungStatusStore.uiState.collect { state -> emitStateChanged(state) }
        }
        moduleScope.launch {
            // Contract: samples while connected + ONE zeroed emission when the stream ends
            // (flow value returns to null), so the JS side clears without special-casing.
            var hadStats = false
            OpenRungStatusStore.trafficState.collect { stats ->
                if (stats != null) {
                    hadStats = true
                    emitTrafficChanged(stats)
                } else if (hadStats) {
                    hadStats = false
                    emitTrafficChanged(
                        TrafficStats(0, 0, 0, 0, System.currentTimeMillis()),
                    )
                }
            }
        }
    }

    override fun getName(): String = NAME

    override fun invalidate() {
        moduleScope.cancel()
        reactContext.removeActivityEventListener(this)
        super.invalidate()
    }

    @ReactMethod
    fun prepare(promise: Promise) {
        val activity = reactContext.currentActivity
        if (activity == null) {
            promise.reject("E_NO_ACTIVITY", "no foreground activity to request VPN consent")
            return
        }
        // POST_NOTIFICATIONS keeps the foreground-service notification visible on API 33+.
        // The grant result is intentionally ignored: the VPN works without it.
        requestNotificationPermission(activity)
        val consentIntent = VpnService.prepare(reactContext.applicationContext)
        if (consentIntent == null) {
            promise.resolve(true)
            return
        }
        preparePromise?.reject("E_PREPARE_SUPERSEDED", "superseded by a newer prepare() call")
        preparePromise = promise
        try {
            activity.startActivityForResult(consentIntent, VPN_REQUEST_CODE)
        } catch (error: Throwable) {
            preparePromise = null
            promise.reject("E_PREPARE_FAILED", error)
        }
    }

    override fun onActivityResult(activity: Activity, requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != VPN_REQUEST_CODE) return
        preparePromise?.resolve(resultCode == Activity.RESULT_OK)
        preparePromise = null
    }

    override fun onNewIntent(intent: Intent) = Unit

    @ReactMethod
    fun connect(brokerUrl: String, targetCountry: String?, promise: Promise) {
        try {
            val context = reactContext.applicationContext
            ContextCompat.startForegroundService(
                context,
                OpenRungVpnService.connectIntent(context, brokerUrl, targetCountry),
            )
            promise.resolve(null)
        } catch (error: Throwable) {
            promise.reject("E_CONNECT_FAILED", error)
        }
    }

    @ReactMethod
    fun disconnect(promise: Promise) {
        try {
            val context = reactContext.applicationContext
            context.startService(OpenRungVpnService.disconnectIntent(context))
            promise.resolve(null)
        } catch (error: Throwable) {
            promise.reject("E_DISCONNECT_FAILED", error)
        }
    }

    @ReactMethod
    fun getState(promise: Promise) {
        promise.resolve(OpenRungStatusStore.uiState.value.toWritableMap())
    }

    @ReactMethod
    fun getTrafficStats(promise: Promise) {
        promise.resolve(OpenRungStatusStore.trafficState.value?.toWritableMap())
    }

    @ReactMethod
    fun measureLatency(targets: com.facebook.react.bridge.ReadableArray, timeoutMs: Double, promise: Promise) {
        moduleScope.launch(Dispatchers.IO) {
            runCatching {
                val parsed = buildList {
                    for (i in 0 until targets.size()) {
                        val target = targets.getMap(i) ?: continue
                        val id = target.getString("id") ?: continue
                        val host = target.getString("host") ?: continue
                        val port = if (target.hasKey("port")) target.getInt("port") else continue
                        add(Triple(id, host, port))
                    }
                }
                LatencyProber(reactContext.applicationContext).measure(parsed, timeoutMs.toInt())
            }.onSuccess { measurement ->
                val map = Arguments.createMap()
                map.putBoolean("viaTunnel", measurement.viaTunnel)
                val results = Arguments.createArray()
                measurement.results.forEach { result ->
                    val entry = Arguments.createMap()
                    entry.putString("id", result.id)
                    if (result.latencyMs != null) entry.putDouble("latencyMs", result.latencyMs.toDouble()) else entry.putNull("latencyMs")
                    entry.putBoolean("reachable", result.reachable)
                    results.pushMap(entry)
                }
                map.putArray("results", results)
                promise.resolve(map)
            }.onFailure { promise.reject("E_MEASURE_LATENCY_FAILED", it) }
        }
    }

    @ReactMethod
    fun getInstalledApps(promise: Promise) {
        moduleScope.launch(Dispatchers.IO) {
            runCatching {
                val pm = reactContext.packageManager
                val flags = PackageManager.GET_PERMISSIONS
                val packages = if (Build.VERSION.SDK_INT >= 33) {
                    pm.getInstalledPackages(PackageManager.PackageInfoFlags.of(flags.toLong()))
                } else {
                    @Suppress("DEPRECATION")
                    pm.getInstalledPackages(flags)
                }
                val ownPackage = reactContext.packageName
                val array = Arguments.createArray()
                packages.asSequence()
                    // Only apps that can actually use the network are worth listing; drop ourselves.
                    .filter { it.requestedPermissions?.contains(Manifest.permission.INTERNET) == true }
                    .filter { it.packageName != ownPackage }
                    .map { info ->
                        val appInfo = info.applicationInfo
                        val label = appInfo?.let { pm.getApplicationLabel(it).toString() } ?: info.packageName
                        val isSystem = appInfo != null &&
                            (appInfo.flags and android.content.pm.ApplicationInfo.FLAG_SYSTEM) != 0
                        Triple(info.packageName, label, isSystem)
                    }
                    .sortedBy { it.second.lowercase() }
                    .forEach { (packageName, label, isSystem) ->
                        val entry = Arguments.createMap()
                        entry.putString("packageName", packageName)
                        entry.putString("label", label)
                        entry.putBoolean("isSystem", isSystem)
                        array.pushMap(entry)
                    }
                array
            }.onSuccess { promise.resolve(it) }
                .onFailure { promise.reject("E_LIST_APPS_FAILED", it) }
        }
    }

    @ReactMethod
    fun getSplitTunnelConfig(promise: Promise) {
        val config = SplitTunnelStore.read(reactContext.applicationContext)
        promise.resolve(config.toWritableMap())
    }

    @ReactMethod
    fun setSplitTunnelConfig(config: ReadableMap, promise: Promise) {
        try {
            val mode = SplitTunnelMode.fromWireName(config.getString("mode"))
            val packagesArray = config.getArray("packages")
            val packages = buildSet {
                if (packagesArray != null) {
                    for (i in 0 until packagesArray.size()) {
                        packagesArray.getString(i)?.let { add(it) }
                    }
                }
            }
            val next = SplitTunnelConfig(mode = mode, packages = packages)
            val previous = SplitTunnelStore.read(reactContext.applicationContext)
            SplitTunnelStore.write(reactContext.applicationContext, next)

            val changed = next != previous
            val status = OpenRungStatusStore.uiState.value.status
            val active = status == ConnectionStatus.CONNECTED ||
                status == ConnectionStatus.CONNECTING ||
                status == ConnectionStatus.PREPARING
            val result = Arguments.createMap()
            result.putBoolean("needsReconnect", changed && active)
            promise.resolve(result)
        } catch (error: Throwable) {
            promise.reject("E_SET_SPLIT_TUNNEL_FAILED", error)
        }
    }

    @ReactMethod
    fun getPersistedLog(promise: Promise) {
        moduleScope.launch(Dispatchers.IO) {
            val lines = RuntimeLogStore.readLines()
            val array = Arguments.createArray()
            lines.forEach(array::pushString)
            promise.resolve(array)
        }
    }

    @ReactMethod
    fun clearPersistedLog(promise: Promise) {
        moduleScope.launch(Dispatchers.IO) {
            RuntimeLogStore.clear()
            promise.resolve(null)
        }
    }

    @ReactMethod
    fun getIdentity(promise: Promise) {
        val identity = Arguments.createMap()
        identity.putString("clientId", ClientIdentity.getOrCreate(reactContext.applicationContext))
        val sessionId = TelemetryManager.activeSession()?.id
        if (sessionId != null) identity.putString("sessionId", sessionId) else identity.putNull("sessionId")
        promise.resolve(identity)
    }

    /** RN NativeEventEmitter interop no-op. */
    @ReactMethod
    fun addListener(eventName: String?) = Unit

    /** RN NativeEventEmitter interop no-op. */
    @ReactMethod
    fun removeListeners(count: Double) = Unit

    private fun requestNotificationPermission(activity: Activity) {
        if (Build.VERSION.SDK_INT < 33) return
        val alreadyGranted = ContextCompat.checkSelfPermission(
            activity,
            Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
        if (alreadyGranted) return
        val permissionAware = activity as? PermissionAwareActivity ?: return
        permissionAware.requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_REQUEST_CODE,
        ) { _, _, _ -> true }
    }

    private fun emitStateChanged(state: OpenRungUiState) {
        if (!reactContext.hasActiveReactInstance()) return
        reactContext
            .getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java)
            .emit(EVENT_STATE_CHANGED, state.toWritableMap())
    }

    private fun emitTrafficChanged(stats: TrafficStats) {
        if (!reactContext.hasActiveReactInstance()) return
        reactContext
            .getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java)
            .emit(EVENT_TRAFFIC_CHANGED, stats.toWritableMap())
    }

    private fun SplitTunnelConfig.toWritableMap(): WritableMap {
        val map = Arguments.createMap()
        map.putString("mode", mode.wireName)
        val array = Arguments.createArray()
        packages.forEach(array::pushString)
        map.putArray("packages", array)
        return map
    }

    private fun TrafficStats.toWritableMap(): WritableMap {
        val map = Arguments.createMap()
        map.putDouble("upBps", upBps.toDouble())
        map.putDouble("downBps", downBps.toDouble())
        map.putDouble("upTotalBytes", upTotalBytes.toDouble())
        map.putDouble("downTotalBytes", downTotalBytes.toDouble())
        map.putDouble("updatedAtMs", updatedAtMs.toDouble())
        return map
    }

    private fun OpenRungUiState.toWritableMap(): WritableMap {
        val map = Arguments.createMap()
        map.putString("status", status.name.lowercase())
        if (relayLabel != null) map.putString("relayLabel", relayLabel) else map.putNull("relayLabel")
        if (lastError != null) map.putString("lastError", lastError) else map.putNull("lastError")
        val logs = Arguments.createArray()
        logLines.forEach(logs::pushString)
        map.putArray("logLines", logs)
        val recents = Arguments.createArray()
        recentRegions.forEach { node ->
            val entry = Arguments.createMap()
            entry.putString("countryCode", node.countryCode)
            entry.putString("label", node.label)
            entry.putDouble("latitude", node.latitude)
            entry.putDouble("longitude", node.longitude)
            recents.pushMap(entry)
        }
        map.putArray("recents", recents)
        return map
    }

    companion object {
        const val NAME = "OpenRungVpn"
        private const val EVENT_STATE_CHANGED = "openrungStateChanged"
        private const val EVENT_TRAFFIC_CHANGED = "openrungTrafficChanged"
        private const val VPN_REQUEST_CODE = 7001
        private const val NOTIFICATION_REQUEST_CODE = 7002
    }
}
