package com.benjaminissa.issareader.app.ui.ask

import com.benjaminissa.issareader.ask.AskAnswerer
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Where a question goes. The sheet offers the reader's default again when the
 * availability check lands and when the book finishes opening; either can come
 * after the reader has picked, and must not move the question somewhere they
 * did not choose.
 */
class AskChoiceTest {
    @Test
    fun `a default offered after the reader picked does not move their pick`() {
        val choice = AskChoice()
        choice.offerDefault(AskAnswerer.DEVICE)
        choice.pick(AskAnswerer.OPENAI)
        // The check lands, and the book finishes opening.
        choice.offerDefault(AskAnswerer.ANTHROPIC)
        choice.offerDefault(AskAnswerer.DEVICE)
        assertEquals(AskAnswerer.OPENAI, choice.answerer)
    }

    @Test
    fun `before the reader picks, the default follows what the check found`() {
        val choice = AskChoice()
        choice.startOver(AskAnswerer.DEVICE)
        choice.offerDefault(AskAnswerer.ANTHROPIC)
        assertEquals(AskAnswerer.ANTHROPIC, choice.answerer)
    }

    @Test
    fun `a new question starts at the default again`() {
        val choice = AskChoice()
        choice.pick(AskAnswerer.OPENAI)
        choice.startOver(AskAnswerer.DEVICE)
        assertEquals(AskAnswerer.DEVICE, choice.answerer)
        choice.offerDefault(AskAnswerer.ANTHROPIC)
        assertEquals("and a late default applies again, until the reader picks", AskAnswerer.ANTHROPIC, choice.answerer)
    }
}
