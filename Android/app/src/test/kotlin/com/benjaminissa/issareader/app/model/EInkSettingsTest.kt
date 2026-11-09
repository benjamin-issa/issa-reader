package com.benjaminissa.issareader.app.model

import com.benjaminissa.issareader.core.InMemoryKeyValueStore
import com.benjaminissa.issareader.render.EInkNarrationMark
import com.benjaminissa.issareader.render.HighlighterChoice
import com.benjaminissa.issareader.render.HighlighterPreset
import com.benjaminissa.issareader.render.PageTurn
import com.benjaminissa.issareader.render.PageTurnStyle
import com.benjaminissa.issareader.render.ReaderStyle
import com.benjaminissa.issareader.render.ReaderTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * E-Ink mode's two settings, and the promise that the mode overrides the
 * reader's choices without touching them.
 */
class EInkSettingsTest {
    private val defaults = InMemoryKeyValueStore()
    private val settings = PlaybackSettings(defaults)

    @Test
    fun `it is off until asked for, and nothing is stored until then`() {
        assertFalse(settings.einkMode)
        assertNull(defaults.getBooleanOrNull(PlaybackSettings.EINK_MODE_KEY))
    }

    @Test
    fun `the switch outlives the app`() {
        settings.einkMode = true
        assertEquals(true, defaults.getBooleanOrNull("issa.einkMode"))
        assertTrue(PlaybackSettings(defaults).einkMode)
        settings.einkMode = false
        assertFalse(PlaybackSettings(defaults).einkMode)
    }

    @Test
    fun `the mark is an underline until chosen, and the choice outlives the app`() {
        assertEquals(EInkNarrationMark.UNDERLINE, settings.einkNarrationMark)
        settings.einkNarrationMark = EInkNarrationMark.INVERTED
        assertEquals("inverted", defaults.getString("issa.einkNarrationMark"))
        assertEquals(EInkNarrationMark.INVERTED, PlaybackSettings(defaults).einkNarrationMark)
    }

    @Test
    fun `a mark this build cannot read is an underline`() {
        defaults.putString(PlaybackSettings.EINK_NARRATION_MARK_KEY, "sparkles")
        assertEquals(EInkNarrationMark.UNDERLINE, PlaybackSettings(defaults).einkNarrationMark)
    }

    @Test
    fun `the page is E-Ink's while it is on, and the stored style is not`() {
        settings.readerStyle = ReaderStyle(theme = ReaderTheme.SEPIA)
        settings.einkMode = true
        assertEquals(ReaderTheme.EINK, settings.pageStyle("book").theme)
        assertEquals(ReaderTheme.EINK, settings.pageTheme)
        assertEquals(ReaderTheme.SEPIA, settings.readerStyle.theme)
        assertEquals(ReaderTheme.SEPIA, settings.style("book").theme)
        assertEquals("nothing wrote it through", ReaderTheme.SEPIA, PlaybackSettings(defaults).readerStyle.theme)
    }

    @Test
    fun `off, the page is the reader's`() {
        settings.readerStyle = ReaderStyle(theme = ReaderTheme.NIGHT)
        assertEquals(settings.style("book"), settings.pageStyle("book"))
        assertEquals(ReaderTheme.NIGHT, settings.pageTheme)
    }

    /** What the handoff's acceptance list asks of turning it off, with a change made while it was on. */
    @Test
    fun `turning it off restores the page colour, the highlighter and the page turn`() {
        val marker = HighlighterChoice.Preset(HighlighterPreset.ROSE)
        settings.readerStyle = ReaderStyle(theme = ReaderTheme.SEPIA, highlighters = mapOf(ReaderTheme.SEPIA to marker))
        settings.pageTurn = PageTurnStyle.COVER

        settings.einkMode = true
        assertEquals("the reader's turn goes", PageTurnStyle.INSTANT, PageTurn.effectiveStyle(settings.pageTurn, reduceMotion = settings.einkMode))
        assertEquals("and stays chosen", PageTurnStyle.COVER, settings.pageTurn)
        // A font changed from the reader while the mode is on writes through
        // the stored style, not the one the page is drawn in.
        settings.readerStyle = settings.readerStyle.copy(fontSize = 21.0)
        settings.einkMode = false

        val after = PlaybackSettings(defaults)
        assertEquals(ReaderTheme.SEPIA, after.pageStyle("book").theme)
        assertEquals(marker, after.readerStyle.highlighters[ReaderTheme.SEPIA])
        assertEquals(PageTurnStyle.COVER, after.pageTurn)
        assertEquals("and the change is kept", 21.0, after.readerStyle.fontSize, 0.0)
    }
}
