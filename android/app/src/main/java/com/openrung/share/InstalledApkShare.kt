package com.openrung.share

import android.content.ClipData
import android.content.ClipDescription
import android.content.Context
import android.content.Intent
import android.net.Uri
import com.openrung.BuildConfig
import java.io.File

/** Builds the tightly-scoped URI and share intent for this app's installed monolithic APK. */
internal object InstalledApkShare {
    const val APK_MIME_TYPE = "application/vnd.android.package-archive"
    const val PROVIDER_AUTHORITY_SUFFIX = ".apk-share"

    fun requireShareableApk(context: Context): File {
        val applicationInfo = context.applicationInfo
        return requireShareableApk(applicationInfo.sourceDir, applicationInfo.splitSourceDirs)
    }

    fun requireShareableApk(sourceDir: String?, splitSourceDirs: Array<String>?): File {
        if (!splitSourceDirs.isNullOrEmpty()) {
            throw ApkShareException(
                error = ApkShareError.SPLIT_INSTALL,
                message = "the installed app uses split APKs; sharing base.apk alone would be incomplete",
            )
        }

        val sourcePath = sourceDir?.takeIf(String::isNotBlank)
            ?: throw ApkShareException(
                error = ApkShareError.APK_UNAVAILABLE,
                message = "the installed APK path is unavailable",
            )
        val sourceApk = File(sourcePath)
        if (!sourceApk.isFile || !sourceApk.canRead()) {
            throw ApkShareException(
                error = ApkShareError.APK_UNAVAILABLE,
                message = "the installed APK is not readable",
            )
        }
        return sourceApk
    }

    fun displayName(): String {
        val safeVersion = BuildConfig.VERSION_NAME.replace(Regex("[^A-Za-z0-9._-]"), "_")
        return "OpenRung-$safeVersion.apk"
    }

    fun contentUri(context: Context): Uri =
        Uri.Builder()
            .scheme("content")
            .authority(context.packageName + PROVIDER_AUTHORITY_SUFFIX)
            .appendPath(displayName())
            .build()

    fun createSendIntent(context: Context): Intent {
        // Fail before opening the chooser rather than sending an unusable base APK from a split install.
        requireShareableApk(context)
        val uri = contentUri(context)
        return Intent(Intent.ACTION_SEND).apply {
            type = APK_MIME_TYPE
            putExtra(Intent.EXTRA_STREAM, uri)
            clipData = ClipData(
                ClipDescription(displayName(), arrayOf(APK_MIME_TYPE)),
                ClipData.Item(uri),
            )
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
    }
}

internal enum class ApkShareError(val code: String) {
    SPLIT_INSTALL("E_SPLIT_APK_INSTALL"),
    APK_UNAVAILABLE("E_APK_UNAVAILABLE"),
}

internal class ApkShareException(
    val error: ApkShareError,
    message: String,
) : IllegalStateException(message) {
    val code: String
        get() = error.code
}
