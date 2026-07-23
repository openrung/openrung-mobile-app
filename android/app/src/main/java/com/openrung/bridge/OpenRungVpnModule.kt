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
import com.openrung.state.ConnectionStatus
import com.openrung.state.OpenRungStatusStore
import com.openrung.state.OpenRungUiState
import com.openrung.telemetry.ClientIdentity
import com.openrung.telemetry.TelemetryManager
import com.openrung.vpn.OpenRungVpnService
import com.openrung.vpn.SplitTunnelStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * Classic NativeModule implementing the OpenRungVpn bridge contract (docs/CONTRACT.md §3):
 * prepare/connect/disconnect/getState/getIdentity/setSplitTunnelConfig plus the
 * `openrungStateChanged` event mirroring [OpenRungStatusStore.uiState].
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
    fun connect(brokerUrl: String, targetCountry: String?, targetRelayId: String?, promise: Promise) {
        try {
            val context = reactContext.applicationContext
            ContextCompat.startForegroundService(
                context,
                OpenRungVpnService.connectIntent(context, brokerUrl, targetCountry, targetRelayId),
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

    /**
     * Persists the split-tunnel config JSON (contract §3). If the tunnel is up and the config
     * actually changed (string comparison against the stored value), the service reapplies it by
     * reconnecting to the same target. Resolves after persistence + reapply dispatch — not after
     * the reconnect completes.
     */
    @ReactMethod
    fun setSplitTunnelConfig(configJson: String, promise: Promise) {
        try {
            val context = reactContext.applicationContext
            // Only an EFFECTIVE change reapplies (writeAndReportEffectiveChange still persists the
            // raw string): a first push of a disabled config, or any change that nets to
            // the same emitted config, must never bounce a live tunnel. The service re-validates
            // the connection state before actually reconnecting.
            val effectiveChanged = SplitTunnelStore.writeAndReportEffectiveChange(context, configJson)
            val status = OpenRungStatusStore.uiState.value.status
            if (effectiveChanged &&
                (status == ConnectionStatus.PREPARING ||
                    status == ConnectionStatus.CONNECTING ||
                    status == ConnectionStatus.CONNECTED)
            ) {
                context.startService(OpenRungVpnService.reapplyIntent(context))
            }
            promise.resolve(null)
        } catch (error: Throwable) {
            promise.reject("E_SPLIT_TUNNEL_FAILED", error)
        }
    }

    @ReactMethod
    fun getState(promise: Promise) {
        promise.resolve(OpenRungStatusStore.uiState.value.toWritableMap())
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
        private const val VPN_REQUEST_CODE = 7001
        private const val NOTIFICATION_REQUEST_CODE = 7002
    }
}
