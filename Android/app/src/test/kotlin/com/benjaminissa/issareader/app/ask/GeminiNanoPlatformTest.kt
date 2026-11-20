package com.benjaminissa.issareader.app.ask

import android.content.Context
import android.content.pm.PackageInfo
import androidx.test.core.app.ApplicationProvider
import com.benjaminissa.issareader.ask.android.MlKitStartup
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf

/**
 * The up-front disable reads the package manager and nothing of ML Kit: a
 * phone without AICore has no Gemini Nano to ask about.
 */
@RunWith(RobolectricTestRunner::class)
class GeminiNanoPlatformTest {
    private val context: Context get() = ApplicationProvider.getApplicationContext()

    @Test
    fun `AICore absent means no system service, and ML Kit is not started to find out`() {
        assertFalse(GeminiNanoPlatform(context).hasSystemService)
        assertFalse(MlKitStartup.isStarted)
    }

    @Test
    fun `AICore installed means the system service is there`() {
        shadowOf(context.packageManager).installPackage(PackageInfo().apply { packageName = "com.google.android.aicore" })
        assertTrue(GeminiNanoPlatform(context).hasSystemService)
        assertFalse(MlKitStartup.isStarted)
    }

    @Test
    fun `the manifest names AICore, so Android 11 lets the lookup see it`() {
        val queries = java.io.File("src/main/AndroidManifest.xml").readText()
        assertTrue(queries.contains("<package android:name=\"com.google.android.aicore\" />"))
    }
}
