package com.benjaminissa.issareader.app.ui.settings

import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import com.benjaminissa.issareader.app.ui.SettingsFixture
import com.benjaminissa.issareader.app.ui.shell.LocalAppEnvironment
import com.benjaminissa.issareader.ui.IssaTheme
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * "Show book title" in Reading › Pages: a phone's switch, left out on a tablet
 * (the iPad's rule, `994da30`), with the Pages note naming it only where it is.
 */
@RunWith(RobolectricTestRunner::class)
@Config(qualifiers = "w402dp-h1960dp-xxhdpi")
class BookTitleSwitchTest {
    @get:Rule
    val compose = createComposeRule()

    private val fixture = SettingsFixture().withLibrary().withLocalBooks()

    @After
    fun tearDown() = fixture.close()

    private fun show() = compose.setContent {
        IssaTheme(darkTheme = false) {
            CompositionLocalProvider(LocalAppEnvironment provides fixture.environment) {
                ReadingSettingsScreen(fixture.settings, onBack = {}, onOpenLicences = {}, reduceMotion = false)
            }
        }
    }

    private fun noteShown() =
        compose.onAllNodesWithText(ReadingSettings.BOOK_TITLE_NOTE, substring = true).fetchSemanticsNodes().isNotEmpty()

    @Test
    fun `a phone shows the switch, on, and the note that names it`() {
        show()
        compose.onNodeWithText("Show book title").performScrollTo().assertExists()
        assertTrue(noteShown())
        assertTrue(fixture.settings.showsBookTitle)
    }

    @Test
    fun `the switch writes the setting`() {
        show()
        compose.onNodeWithText("Show book title").performScrollTo().performClick()
        assertFalse(fixture.settings.showsBookTitle)
        compose.onNodeWithText("Show book title").performClick()
        assertTrue(fixture.settings.showsBookTitle)
    }

    @Test
    @Config(qualifiers = "sw600dp-w800dp-h1280dp-xhdpi")
    fun `a tablet has no switch and its note does not name one`() {
        show()
        assertEquals(0, compose.onAllNodesWithText("Show book title", substring = true).fetchSemanticsNodes().size)
        assertFalse(noteShown())
    }

    @Test
    fun `the note names the title only where the switch is, motion removed or not`() {
        assertTrue(ReadingSettings.pagesNote(false, true).endsWith(ReadingSettings.BOOK_TITLE_NOTE))
        assertTrue(ReadingSettings.pagesNote(true, true).endsWith(ReadingSettings.BOOK_TITLE_NOTE))
        assertFalse(ReadingSettings.pagesNote(false, false).contains("Show book title"))
        assertFalse(ReadingSettings.pagesNote(true, false).contains("Show book title"))
        assertTrue(ReadingSettings.offersBookTitle(599))
        assertFalse(ReadingSettings.offersBookTitle(600))
    }
}
