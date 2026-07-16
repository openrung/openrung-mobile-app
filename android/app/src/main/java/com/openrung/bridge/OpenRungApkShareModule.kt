package com.openrung.bridge

import android.content.Intent
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.UiThreadUtil
import com.openrung.share.ApkShareException
import com.openrung.share.InstalledApkShare

/** Android-only bridge that opens the system sharesheet for the installed OpenRung APK. */
class OpenRungApkShareModule(
    private val reactContext: ReactApplicationContext,
) : ReactContextBaseJavaModule(reactContext) {
    override fun getName(): String = NAME

    @ReactMethod
    fun shareApk(chooserTitle: String, promise: Promise) {
        UiThreadUtil.runOnUiThread {
            try {
                val activity = reactContext.currentActivity
                    ?: run {
                        promise.reject(ERROR_NO_ACTIVITY, "no foreground activity to open the share sheet")
                        return@runOnUiThread
                    }
                val sendIntent = InstalledApkShare.createSendIntent(reactContext.applicationContext)
                val chooser = Intent.createChooser(sendIntent, chooserTitle)
                activity.startActivity(chooser)
                // Android does not report whether the chosen target completed the transfer.
                promise.resolve(null)
            } catch (error: ApkShareException) {
                promise.reject(error.code, error.message, error)
            } catch (error: Throwable) {
                promise.reject(ERROR_SHARE_FAILED, "unable to open the APK share sheet", error)
            }
        }
    }

    companion object {
        const val NAME = "OpenRungApkShare"
        private const val ERROR_NO_ACTIVITY = "E_NO_ACTIVITY"
        private const val ERROR_SHARE_FAILED = "E_SHARE_FAILED"
    }
}
