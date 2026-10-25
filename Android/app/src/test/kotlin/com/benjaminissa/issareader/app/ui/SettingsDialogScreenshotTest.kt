package com.benjaminissa.issareader.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.createComposeRule
import com.benjaminissa.issareader.app.ui.settings.ChoiceDialog
import com.benjaminissa.issareader.app.ui.settings.DialogChoice
import com.benjaminissa.issareader.ui.IssaTheme
import com.benjaminissa.issareader.ui.Palette
import com.github.takahirom.roborazzi.captureScreenRoboImage
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** The sign-out question, which is a dialog window of its own and so is captured with the whole screen. */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(qualifiers = "w402dp-h874dp-xxhdpi")
class SettingsDialogScreenshotTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun signOut() {
        compose.setContent {
            IssaTheme(darkTheme = false) {
                Box(Modifier.fillMaxSize().background(Palette.paper))
                ChoiceDialog(
                    title = "Sign out?",
                    choices = listOf(
                        DialogChoice("Sign out and keep downloads") {},
                        DialogChoice("Sign out and delete downloads", destructive = true) {},
                    ),
                    onDismiss = {},
                )
            }
        }
        compose.waitForIdle()
        captureScreenRoboImage("build/settings-shots/settings-sign-out-402.png")
    }
}
