package com.benjaminissa.issareader.app.ask

import android.content.Context
import android.content.pm.PackageManager
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * ML Kit does not start itself.
 *
 * `com.google.mlkit:common` declares `MlKitInitProvider`, a content provider
 * that initialises ML Kit at every process start, before any of the app's
 * code — and ML Kit reports diagnostics to Google from its first call. The
 * reader decided that with Ask off nothing goes to Google, so the app's
 * manifest removes the provider and `MlKitStartup` starts ML Kit by hand when
 * Ask is turned on. This reads the merged manifest the app is built with, so a
 * dependency that brings the provider back turns it red.
 */
@RunWith(RobolectricTestRunner::class)
class MlKitStartupManifestTest {
    private val context: Context get() = ApplicationProvider.getApplicationContext()

    private val providers: List<String>
        get() = context.packageManager
            .getPackageInfo(context.packageName, PackageManager.GET_PROVIDERS)
            .providers.orEmpty()
            .map { it.name }

    @Test
    fun `the merged manifest has no ML Kit start-up provider`() {
        assertFalse(
            "MlKitInitProvider would start ML Kit at every launch, Ask on or off",
            providers.any { it == "com.google.mlkit.common.internal.MlKitInitProvider" },
        )
        assertFalse(providers.any { it.startsWith("com.google.mlkit") || it.startsWith("com.google.firebase") })
    }

    /** That the list read above is the real one, so the absence means something. */
    @Test
    fun `the providers the app does declare are there`() {
        assertTrue(providers.toString(), "androidx.core.content.FileProvider" in providers)
    }
}
