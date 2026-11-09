package com.benjaminissa.issareader.app.ui.local

import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import com.benjaminissa.issareader.app.ui.SettingsFixture
import com.benjaminissa.issareader.ui.IssaTheme
import org.junit.After
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** The settings sheet "On this phone" opens, and the screens it pushes inside itself. */
@RunWith(RobolectricTestRunner::class)
@Config(qualifiers = "w402dp-h874dp-xxhdpi")
class LocalSettingsSheetTest {
    @get:Rule
    val compose = createComposeRule()

    private val fixture = SettingsFixture().withLocalBooks()

    @After
    fun tearDown() = fixture.close()

    /**
     * Back tapped twice before the sheet draws again goes back once. The
     * screen sliding away keeps its Back button live until the next frame, so
     * a second tap popped the sheet's own list too, and the empty stack took
     * the app down drawing it.
     */
    @Test
    fun `a double tap on Back goes back once`() {
        compose.setContent {
            IssaTheme(darkTheme = false) {
                LocalSettingsContent(fixture.environment, fixture.local, onDone = {}, onConnectServer = {}, spaceUsed = 0)
            }
        }
        compose.onNodeWithText("Controls & remapping").performClick()
        compose.onNodeWithText("Controls").assertExists()

        // Both taps inside one frame: nothing redraws between them.
        compose.mainClock.autoAdvance = false
        val back = compose.onNodeWithContentDescription("Back")
        back.performClick()
        back.performClick()
        compose.mainClock.autoAdvance = true
        compose.waitForIdle()

        compose.onNodeWithTag("screen.localSettings").assertExists()
    }
}
