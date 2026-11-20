package com.benjaminissa.issareader.app.ui.reader

import androidx.activity.ComponentActivity
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onRoot
import com.benjaminissa.issareader.render.ReaderStyle
import com.benjaminissa.issareader.ui.IssaTheme
import com.benjaminissa.issareader.ui.Palette
import com.benjaminissa.issareader.ui.PaperList
import com.benjaminissa.issareader.ui.paperSection
import com.github.takahirom.roborazzi.captureRoboImage
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * The Margins row on its own, light, dark and E Ink, with a preset selected
 * and with a stored margin past the slider's end. Written to
 * `app/build/reader-shots/` when the suite runs with `-Proborazzi.test.record=true`.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(qualifiers = "w402dp-h300dp-xxhdpi")
class MarginRowScreenshotTest {
    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()

    private fun shot(name: String, margin: Double, dark: Boolean = false, eink: Boolean = false) {
        compose.setContent { Row(margin, dark, eink) }
        compose.waitForIdle()
        compose.onRoot().captureRoboImage("build/reader-shots/$name.png")
    }

    @Composable
    private fun Row(margin: Double, dark: Boolean, eink: Boolean) {
        IssaTheme(darkTheme = dark, eink = eink) {
            Box(Modifier.fillMaxSize().background(Palette.paper)) {
                PaperList {
                    paperSection(key = "m", header = "This book") {
                        row { MarginControl(ReaderStyle(pageMargin = margin), onStyle = {}) }
                    }
                }
            }
        }
    }

    @Test
    fun light() = shot("margins-row-light", 12.0)

    @Test
    fun dark() = shot("margins-row-dark", 48.0, dark = true)

    @Test
    fun eink() = shot("margins-row-eink", 4.0, eink = true)

    @Test
    fun einkStandard() = shot("margins-row-eink-standard", 24.0, eink = true)

    @Test
    fun pastTheTrack() = shot("margins-row-past-track", 100.0)
}
