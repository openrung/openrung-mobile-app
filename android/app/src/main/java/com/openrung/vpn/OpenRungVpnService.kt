package com.openrung.vpn

import android.app.*
import android.content.*
import android.net.*
import android.os.Handler
import android.os.Looper
import android.os.Build
import androidx.core.app.NotificationCompat
import com.openrung.MainActivity
import com.openrung.R
import com.openrung.BuildConfig
import com.openrung.config.AppConfig
import com.openrung.net.SplitTunnelRules
import com.openrung.net.ProbeTargets
import com.openrung.net.SingBoxConfiguration
import com.openrung.state.ConnectionStatus
import com.openrung.state.OpenRungStatusStore
import io.nekohasekai.libbox.OpenRungRunTelemetry
import kotlinx.serialization.json.*
import java.io.File

/** Android lifecycle and platform mechanics. Connect/recovery policy lives in connectcore. */
class OpenRungVpnService : VpnService() {
    @Volatile private var lastStartId = -1
    @Volatile private var observer: EngineNetworkObserver? = null
    private val runs = java.util.concurrent.CopyOnWriteArraySet<AndroidEngineRun>()
    override fun onCreate() {
        super.onCreate()
        OpenRungStatusStore.initialize(applicationContext)
        createNotificationChannel()
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        lastStartId = startId
        when (intent?.action) {
            ACTION_CONNECT -> {
                startForeground(NOTIFICATION_ID, notification(getString(R.string.vpn_notification_preparing)))
                ConnectcoreProcessHost.connect(this, startId, intent.getStringExtra(EXTRA_BROKER_URL).orEmpty().ifBlank { AppConfig.DEFAULT_BROKER_URL },
                    intent.getStringExtra(EXTRA_TARGET_COUNTRY), intent.getStringExtra(EXTRA_TARGET_RELAY_ID))
            }
            ACTION_REAPPLY -> ConnectcoreProcessHost.reapply(this, startId)
            ACTION_DISCONNECT -> ConnectcoreProcessHost.stop(this, startId)
            else -> ConnectcoreProcessHost.stop(this, startId) // killed-process restart never resurrects an unstored target
        }
        return START_STICKY
    }
    override fun onRevoke() { ConnectcoreProcessHost.stop(this, lastStartId); super.onRevoke() }
    override fun onDestroy() {
        ConnectcoreProcessHost.destroyed(this, lastStartId)
        super.onDestroy()
    }
    internal fun finish(id: Int) = Handler(Looper.getMainLooper()).post {
        // Only remove the foreground notification if this command still owns the service.
        if (id == lastStartId && stopSelfResult(id)) stopForeground(STOP_FOREGROUND_REMOVE)
    }
    internal fun terminateAfterFailedTeardown() {
        Handler(Looper.getMainLooper()).post {
            try {
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf() // Cancel START_STICKY resurrection before killing both TUN fd owners.
            } finally {
                android.os.Process.killProcess(android.os.Process.myPid())
            }
        }
    }
    internal fun reportFailure(message: String) { OpenRungStatusStore.fail(message); showStatus(ConnectionStatus.FAILED) }
    internal fun showStatus(status: ConnectionStatus, location: String? = null) = updateNotification(
        if (status == ConnectionStatus.CONNECTED) getString(R.string.vpn_notification_connected,
            location ?: getString(R.string.relay_location_unknown)) else getString(status.labelResId),
    )
    internal fun observe(changed: (EngineNetworkSnapshot) -> Unit) { closeObservation(); observer = EngineNetworkObserver(this, changed) }
    internal fun closeObservation() { observer?.close(); observer = null }
    internal fun networkSnapshot(): EngineNetworkSnapshot = observer?.current ?: EngineNetworkObserver.snapshot(this)
    internal fun networkAttributes(): Map<String,String> = observer?.current?.attributes.orEmpty()
    internal fun physicalNetwork(): Network? = observer?.current?.defaultNetwork
    internal fun physicalInterface(): EnginePhysicalInterface? = observer?.current?.defaultInterface
    internal fun newRun(telemetry: OpenRungRunTelemetry): AndroidEngineRun = AndroidEngineRun(this, telemetry) { runs.remove(it) }.also { runs.add(it) }
    internal fun refreshRunInterfaces() { runs.forEach { it.refreshInterfaces() } }
    internal fun settingsJSON(): String = buildJsonObject {
        put("tunnel_ipv4_address", SingBoxConfiguration.DEFAULT_TUNNEL_IPV4_ADDRESS)
        put("tunnel_ipv6_address", "fdfe:dcba:9876::1/126")
        put("mtu", 1400); put("log_level", if (BuildConfig.DEBUG) "info" else "warn")
        put("route_find_process", true)
        putJsonArray("probe_domain_suffixes") { ProbeTargets.RULE_DOMAIN_SUFFIXES.forEach { add(it) } }
        currentSplitTunnelRules()?.let { rules -> putJsonObject("split_tunnel") {
            put("bypass_lan", rules.bypassLan)
            putJsonArray("bypass_countries") { rules.bypassCountries.forEach { add(it) } }
            putJsonArray("excluded_packages") { rules.excludedPackages.forEach { add(it) } }
            put("rule_set_directory", rules.ruleSetDirectory)
        } }
    }.toString()
    private val stagedRuleSetDirectory by lazy { stageRuleSetAssets() }

    private fun currentSplitTunnelRules(): SplitTunnelRules? {
        val config = SplitTunnelStore.read(applicationContext) ?: return null
        if (!config.enabled) return null
        val ruleSetDirectory = stagedRuleSetDirectory
        // An automatic country selection is re-derived from the device's CURRENT time zone here,
        // not taken from the stored snapshot. This method runs on every connect attempt including
        // the recovery reconnects that follow a physical-network change, so a phone that
        // auto-selected China in Shanghai stops bypassing geosite-cn as soon as it rebuilds in
        // Berlin — even if the app has not been opened since, and even if the RN foreground
        // re-check never got the chance to run or lost the race with an in-flight recovery.
        val requestedCountries = config.resolvedBypassCountries()
        // Normalize to the canonical ir,cn order and keep only countries whose BOTH .srs files
        // made it to disk (the generator's contract).
        val bypassCountries = SplitTunnelRules.SUPPORTED_COUNTRIES.filter { country ->
            if (country !in requestedCountries) return@filter false
            val staged = File(ruleSetDirectory, "geosite-$country.srs").isFile &&
                File(ruleSetDirectory, "geoip-$country.srs").isFile
            if (!staged) {
                OpenRungStatusStore.appendLog(getString(R.string.log_split_ruleset_missing, country))
            }
            staged
        }
        // Drop packages that are no longer installed: VpnService.Builder.addDisallowedApplication
        // throws NameNotFoundException for an unknown package, which would abort every connect
        // attempt (fail-open violation). A stale entry degrades to full-tunnel for that app.
        val excludedPackages = config.excludedPackages.filter { pkg ->
            runCatching { packageManager.getApplicationInfo(pkg, 0) }.isSuccess
        }
        if (!config.bypassLan && bypassCountries.isEmpty() && excludedPackages.isEmpty()) {
            // Nothing effective: pass null so the emitted configuration stays byte-identical.
            return null
        }
        return SplitTunnelRules(
            bypassLan = config.bypassLan,
            bypassCountries = bypassCountries,
            excludedPackages = excludedPackages,
            ruleSetDirectory = ruleSetDirectory.absolutePath,
        )
    }

    /**
     * Copies the bundled .srs rule sets once per service owner, shared by all
     * candidates and recovery attempts. A new owner refreshes assets after app updates.
     * Each copy is best-effort; a missing file just drops that country above.
     */
    private fun stageRuleSetAssets(): File {
        val directory = File(filesDir, "libbox/rulesets")
        directory.mkdirs()
        SplitTunnelRules.SUPPORTED_COUNTRIES.forEach { country ->
            listOf("geosite-$country.srs", "geoip-$country.srs").forEach { name ->
                val destination = File(directory, name)
                val temp = File(directory, "$name.tmp")
                val copied = runCatching {
                    assets.open("rulesets/$name").use { input ->
                        temp.outputStream().use(input::copyTo)
                    }
                }.isSuccess
                if (copied) {
                    // Only a fully-copied temp becomes the live file, so a mid-copy IO failure
                    // (e.g. no disk space) can never leave a truncated .srs that passes the isFile
                    // gate above and then aborts every connect (CONTRACT §1 fail-open).
                    destination.delete()
                    if (!temp.renameTo(destination)) temp.delete()
                } else {
                    // Discard the partial temp; any previously staged good copy is left intact.
                    temp.delete()
                }
            }
        }
        return directory
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            NOTIFICATION_CHANNEL_ID,
            getString(R.string.vpn_notification_channel),
            NotificationManager.IMPORTANCE_LOW,
        )
        manager.createNotificationChannel(channel)
    }

    private fun updateNotification(message: String) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, notification(message))
    }

    private fun notification(message: String): Notification {
        val launchIntent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_vpn)
            .setContentTitle(getString(R.string.vpn_notification_title))
            .setContentText(message)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
    }

    companion object {
        private const val ACTION_CONNECT = "com.openrung.action.CONNECT"
        private const val ACTION_DISCONNECT = "com.openrung.action.DISCONNECT"
        private const val ACTION_REAPPLY = "com.openrung.action.REAPPLY"
        private const val EXTRA_BROKER_URL = "broker_url"
        private const val EXTRA_TARGET_COUNTRY = "target_country"
        private const val EXTRA_TARGET_RELAY_ID = "target_relay_id"
        private const val NOTIFICATION_CHANNEL_ID = "openrung_vpn"
        private const val NOTIFICATION_ID = 2001

        fun connectIntent(
            context: Context,
            brokerUrl: String,
            targetCountry: String? = null,
            targetRelayId: String? = null,
        ): Intent =
            Intent(context, OpenRungVpnService::class.java).apply {
                action = ACTION_CONNECT
                putExtra(EXTRA_BROKER_URL, brokerUrl)
                targetCountry?.let { putExtra(EXTRA_TARGET_COUNTRY, it) }
                targetRelayId?.let { putExtra(EXTRA_TARGET_RELAY_ID, it) }
            }

        fun disconnectIntent(context: Context): Intent =
            Intent(context, OpenRungVpnService::class.java).apply {
                action = ACTION_DISCONNECT
            }

        fun reapplyIntent(context: Context): Intent =
            Intent(context, OpenRungVpnService::class.java).apply {
                action = ACTION_REAPPLY
            }
    }
}
