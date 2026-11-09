package com.benjaminissa.issareader.app.ui.settings

import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performScrollToNode
import com.benjaminissa.issareader.app.ui.SettingsFixture
import com.benjaminissa.issareader.app.ui.shell.LocalAppEnvironment
import com.benjaminissa.issareader.render.EInkNarrationMark
import com.benjaminissa.issareader.render.PageTurnStyle
import com.benjaminissa.issareader.ui.IssaTheme
import com.benjaminissa.issareader.ui.PaperList
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** Settings › Display, the warning in front of it, and what the Reading screen stops offering while it is on. */
@RunWith(RobolectricTestRunner::class)
@Config(qualifiers = "w402dp-h1960dp-xxhdpi")
class DisplaySettingsTest {
    @get:Rule
    val compose = createComposeRule()

    private val fixture = SettingsFixture().withLibrary().withLocalBooks()
    private val settings get() = fixture.settings

    @After
    fun tearDown() = fixture.close()

    private fun exists(text: String, substring: Boolean = false) =
        compose.onAllNodesWithText(text, substring = substring).fetchSemanticsNodes().isNotEmpty()

    private fun showSection() = compose.setContent {
        IssaTheme(darkTheme = false, eink = settings.einkMode) {
            PaperList { displaySection(settings) }
        }
    }

    @Test
    fun `off, the section explains itself and offers nothing else`() {
        showSection()
        assertTrue(exists("E-Ink mode"))
        assertTrue(exists(DisplaySettings.OFF_NOTE))
        assertFalse(exists("Narration mark"))
    }

    @Test
    fun `the switch does not move until the warning is answered`() {
        showSection()
        compose.onNodeWithTag("settings.einkMode").performClick()
        assertFalse(settings.einkMode)
        assertTrue(exists(DisplaySettings.WARNING_TITLE))
        assertTrue(exists("On a colour LCD or OLED screen the app will look plain and stark", substring = true))

        compose.onNodeWithText("Cancel").performClick()
        assertFalse(settings.einkMode)
        assertFalse(exists(DisplaySettings.WARNING_TITLE))
    }

    @Test
    fun `turning it on offers the mark, and turning it off asks nothing`() {
        showSection()
        compose.onNodeWithTag("settings.einkMode").performClick()
        compose.onNodeWithText("Turn on").performClick()
        assertTrue(settings.einkMode)
        assertTrue(exists("Narration mark"))
        assertTrue(exists(DisplaySettings.ON_NOTE, substring = true))
        assertFalse(exists(DisplaySettings.OFF_NOTE))

        compose.onNodeWithTag("settings.einkMode").performClick()
        assertFalse(exists(DisplaySettings.WARNING_TITLE))
        assertFalse(settings.einkMode)
    }

    /** By identity, and not on the first segment: one that always reached Underline would pass there. */
    @Test
    fun `each mark sets itself`() {
        settings.einkMode = true
        showSection()
        compose.onNodeWithText("Inverted").performClick()
        assertEquals(EInkNarrationMark.INVERTED, settings.einkNarrationMark)
        compose.onNodeWithText("Outline").performClick()
        assertEquals(EInkNarrationMark.OUTLINE, settings.einkNarrationMark)
        compose.onNodeWithText("Underline").performClick()
        assertEquals(EInkNarrationMark.UNDERLINE, settings.einkNarrationMark)
    }

    @Test
    fun `only a Boox hears about EinkWise, and only while the mode is on`() {
        assertTrue(DisplaySettings.footer(einkMode = true, manufacturer = "ONYX").contains(DisplaySettings.BOOX_NOTE))
        assertTrue(DisplaySettings.footer(einkMode = true, manufacturer = "Onyx").contains(DisplaySettings.BOOX_NOTE))
        assertFalse(DisplaySettings.footer(einkMode = true, manufacturer = "Google").contains(DisplaySettings.BOOX_NOTE))
        assertEquals(DisplaySettings.OFF_NOTE, DisplaySettings.footer(einkMode = false, manufacturer = "ONYX"))
    }

    @Test
    fun `the section is on the main list, after Playback and before the machinery`() {
        compose.setContent {
            IssaTheme(darkTheme = false) {
                CompositionLocalProvider(LocalAppEnvironment provides fixture.environment) {
                    SettingsRootList(fixture.app, settings, fixture.nowPlaying, fixture.local, account = null, onNavigate = {}, onOpenLocalBooks = {})
                }
            }
        }
        compose.onNode(hasTestTag("screen.settings")).performScrollToNode(hasTestTag("settings.einkMode"))
        fun top(text: String) = compose.onNodeWithText(text).fetchSemanticsNode().boundsInRoot.top
        assertTrue(top("Playback & reading") < top("Display"))
        assertTrue(top("Display") < top("Advanced"))
    }

    private fun showReading() = compose.setContent {
        IssaTheme(darkTheme = false, eink = settings.einkMode) {
            CompositionLocalProvider(LocalAppEnvironment provides fixture.environment) {
                ReadingSettingsScreen(settings, onBack = {}, onOpenLicences = {}, reduceMotion = false)
            }
        }
    }

    @Test
    fun `while it is on the page colours go, and the turn says why it is fixed`() {
        settings.pageTurn = PageTurnStyle.COVER
        settings.einkMode = true
        showReading()
        assertFalse(exists("Highlighter"))
        assertFalse(exists("Page colour", substring = true))
        compose.onNodeWithText("E-Ink mode is on, so pages change instantly.", substring = true).performScrollTo().assertIsDisplayed()
        // It reads None and opens no menu to change it.
        compose.onNodeWithText("None").performScrollTo().performClick()
        assertFalse(exists("Cover"))
        assertEquals("the choice stays stored", PageTurnStyle.COVER, settings.pageTurn)
    }

    @Test
    fun `off, they are all still there`() {
        showReading()
        assertTrue(exists("Highlighter"))
        assertTrue(exists("Page colour", substring = true))
        assertFalse(exists("E-Ink mode is on", substring = true))
    }

    @Test
    fun `the note gives E-Ink mode as the reason, whatever the system says`() {
        val either = ReadingSettings.pagesNote(animationsRemoved = true, showsBookTitleSwitch = false, einkMode = true)
        assertTrue(either.startsWith("E-Ink mode is on, so pages change instantly."))
        assertFalse(either.contains("Remove animations"))
        assertTrue(ReadingSettings.pagesNote(animationsRemoved = true).startsWith("Remove animations is on"))
        assertFalse(ReadingSettings.pagesNote(animationsRemoved = false).contains("instantly. To choose"))
    }
}
