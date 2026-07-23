package com.openrung.bridge

import android.content.Intent
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Android-only bridge listing installed launcher apps for the split-tunneling "Bypassed apps"
 * picker. Requires the MAIN/LAUNCHER `<queries>` element in AndroidManifest.xml so the query
 * works under API 30+ package-visibility rules.
 */
class OpenRungAppListModule(
    private val reactContext: ReactApplicationContext,
) : ReactContextBaseJavaModule(reactContext) {

    // Label loading walks every launcher app's resources; keep it off the UI and JS threads.
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()

    override fun getName(): String = NAME

    override fun invalidate() {
        executor.shutdown()
        super.invalidate()
    }

    @ReactMethod
    fun getInstalledApps(promise: Promise) {
        executor.execute {
            try {
                val packageManager = reactContext.packageManager
                val launcherIntent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
                val apps = packageManager.queryIntentActivities(launcherIntent, 0)
                    .asSequence()
                    .mapNotNull { it.activityInfo?.applicationInfo }
                    .distinctBy { it.packageName }
                    .filterNot { it.packageName == reactContext.packageName }
                    .map { info -> info.packageName to info.loadLabel(packageManager).toString() }
                    .sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { (_, label) -> label })
                    .toList()
                val result = Arguments.createArray()
                apps.forEach { (packageName, label) ->
                    val entry = Arguments.createMap()
                    entry.putString("packageName", packageName)
                    entry.putString("label", label)
                    result.pushMap(entry)
                }
                promise.resolve(result)
            } catch (error: Throwable) {
                promise.reject(ERROR_APP_LIST_FAILED, "unable to list installed launcher apps", error)
            }
        }
    }

    companion object {
        const val NAME = "OpenRungAppList"
        private const val ERROR_APP_LIST_FAILED = "E_APP_LIST_FAILED"
    }
}
