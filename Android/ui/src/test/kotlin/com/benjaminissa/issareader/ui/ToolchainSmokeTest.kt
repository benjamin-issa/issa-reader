package com.benjaminissa.issareader.ui

import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class ToolchainSmokeTest {
    @Test
    fun sharedFontAssetsArePackaged() {
        val names = bundledFontNames(ApplicationProvider.getApplicationContext())
        assertTrue(names.toString(), "Literata-Regular.ttf" in names && "OFL-Literata.txt" in names)
    }
}
