package com.openrung.share

import android.app.Application
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.OpenableColumns
import androidx.core.content.IntentCompat
import com.openrung.BuildConfig
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.io.File
import java.io.FileNotFoundException

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class InstalledApkShareTest {
    private lateinit var context: Context
    private lateinit var originalSourceDir: String
    private var originalSplitSourceDirs: Array<String>? = null

    @Before
    fun setUp() {
        context = RuntimeEnvironment.getApplication()
        originalSourceDir = context.applicationInfo.sourceDir
        originalSplitSourceDirs = context.applicationInfo.splitSourceDirs
    }

    @After
    fun tearDown() {
        context.applicationInfo.sourceDir = originalSourceDir
        context.applicationInfo.splitSourceDirs = originalSplitSourceDirs
    }

    @Test
    fun `monolithic installed APK is accepted`() {
        val sourceApk = fakeInstalledApk(byteArrayOf(1, 2, 3, 4))

        assertEquals(
            sourceApk.canonicalFile,
            InstalledApkShare.requireShareableApk(sourceApk.path, null).canonicalFile,
        )
        assertEquals(
            sourceApk.canonicalFile,
            InstalledApkShare.requireShareableApk(sourceApk.path, emptyArray()).canonicalFile,
        )
    }

    @Test
    fun `split install is rejected instead of sharing incomplete base APK`() {
        val sourceApk = fakeInstalledApk(byteArrayOf(1, 2, 3, 4))

        val error = assertThrows(ApkShareException::class.java) {
            InstalledApkShare.requireShareableApk(
                sourceApk.path,
                arrayOf("/data/app/com.openrung.mobile/split_config.arm64_v8a.apk"),
            )
        }

        assertEquals(ApkShareError.SPLIT_INSTALL.code, error.code)
    }

    @Test
    fun `missing installed APK is rejected with stable error`() {
        val error = assertThrows(ApkShareException::class.java) {
            InstalledApkShare.requireShareableApk("/does/not/exist/base.apk", null)
        }

        assertEquals(ApkShareError.APK_UNAVAILABLE.code, error.code)
    }

    @Test
    fun `share intent carries exact APK URI MIME and temporary read grant`() {
        fakeInstalledApk(byteArrayOf(9, 8, 7, 6))

        val intent = InstalledApkShare.createSendIntent(context)
        val uri = IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)

        assertEquals(Intent.ACTION_SEND, intent.action)
        assertEquals(InstalledApkShare.APK_MIME_TYPE, intent.type)
        assertEquals(InstalledApkShare.contentUri(context), uri)
        assertEquals(uri, intent.clipData?.getItemAt(0)?.uri)
        assertEquals(InstalledApkShare.APK_MIME_TYPE, intent.clipData?.description?.getMimeType(0))
        assertTrue(intent.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0)
        assertFalse(intent.flags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION != 0)
    }

    @Test
    fun `provider exposes friendly metadata and streams installed APK byte for byte`() {
        val expectedBytes = byteArrayOf(0x50, 0x4b, 3, 4, 10, 20, 30)
        fakeInstalledApk(expectedBytes)
        val uri = InstalledApkShare.contentUri(context)

        assertEquals(InstalledApkShare.APK_MIME_TYPE, context.contentResolver.getType(uri))
        context.contentResolver.query(uri, null, null, null, null).use { cursor ->
            assertNotNull(cursor)
            assertTrue(cursor!!.moveToFirst())
            assertEquals(
                "OpenRung-${BuildConfig.VERSION_NAME}.apk",
                cursor.getString(cursor.getColumnIndexOrThrow(OpenableColumns.DISPLAY_NAME)),
            )
            assertEquals(
                expectedBytes.size.toLong(),
                cursor.getLong(cursor.getColumnIndexOrThrow(OpenableColumns.SIZE)),
            )
        }
        val actualBytes = context.contentResolver.openInputStream(uri)!!.use { it.readBytes() }
        assertArrayEquals(expectedBytes, actualBytes)
    }

    @Test
    fun `provider is private read-only and rejects every other URI`() {
        fakeInstalledApk(byteArrayOf(1, 2, 3, 4))
        val authority = context.packageName + InstalledApkShare.PROVIDER_AUTHORITY_SUFFIX
        val providerInfo = context.packageManager.resolveContentProvider(
            authority,
            PackageManager.GET_META_DATA,
        )
        assertNotNull(providerInfo)
        assertFalse(providerInfo!!.exported)
        assertTrue(providerInfo.grantUriPermissions)

        val validUri = InstalledApkShare.contentUri(context)
        assertThrows(FileNotFoundException::class.java) {
            context.contentResolver.openFileDescriptor(validUri, "w")
        }

        val unknownUri = validUri.buildUpon().appendPath("private-file").build()
        assertThrows(FileNotFoundException::class.java) {
            context.contentResolver.openInputStream(unknownUri)
        }
    }

    private fun fakeInstalledApk(bytes: ByteArray): File {
        val sourceApk = File(context.cacheDir, "installed-test.apk").apply { writeBytes(bytes) }
        context.applicationInfo.sourceDir = sourceApk.path
        context.applicationInfo.splitSourceDirs = null
        return sourceApk
    }
}
