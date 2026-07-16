package com.openrung.share

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.File
import java.io.FileNotFoundException

/**
 * Read-only provider for exactly one file: this package's installed, monolithic APK.
 *
 * Streaming [android.content.pm.ApplicationInfo.sourceDir] avoids keeping a second copy of the
 * large APK in app storage. URI validation is deliberately exact, and all mutation APIs are
 * rejected. The manifest keeps the provider non-exported; a receiver gets access only through the
 * temporary read grant attached to the system share intent.
 */
class InstalledApkProvider : ContentProvider() {
    override fun onCreate(): Boolean = true

    override fun getType(uri: Uri): String {
        requireApk(uri)
        return InstalledApkShare.APK_MIME_TYPE
    }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor {
        val apk = requireApk(uri)
        val requestedColumns = projection ?: DEFAULT_PROJECTION
        val columns = requestedColumns.filter { it == OpenableColumns.DISPLAY_NAME || it == OpenableColumns.SIZE }
        val values = columns.map { column ->
            when (column) {
                OpenableColumns.DISPLAY_NAME -> InstalledApkShare.displayName()
                OpenableColumns.SIZE -> apk.length()
                else -> error("unreachable")
            }
        }
        return MatrixCursor(columns.toTypedArray(), 1).apply {
            addRow(values)
        }
    }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r") {
            throw FileNotFoundException("the shared APK is read-only")
        }
        return ParcelFileDescriptor.open(requireApk(uri), ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? =
        throw UnsupportedOperationException("the shared APK is read-only")

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = throw UnsupportedOperationException("the shared APK is read-only")

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int =
        throw UnsupportedOperationException("the shared APK is read-only")

    private fun requireApk(uri: Uri): File {
        val providerContext = context ?: throw FileNotFoundException("provider context unavailable")
        val expectedAuthority = providerContext.packageName + InstalledApkShare.PROVIDER_AUTHORITY_SUFFIX
        if (
            uri.scheme != "content" ||
            uri.authority != expectedAuthority ||
            uri.pathSegments != listOf(InstalledApkShare.displayName())
        ) {
            throw FileNotFoundException("unknown APK URI")
        }
        return try {
            InstalledApkShare.requireShareableApk(providerContext)
        } catch (error: ApkShareException) {
            throw FileNotFoundException(error.message).apply { initCause(error) }
        }
    }

    private companion object {
        val DEFAULT_PROJECTION = arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
    }
}
