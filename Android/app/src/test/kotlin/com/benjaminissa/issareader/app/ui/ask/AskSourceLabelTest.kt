package com.benjaminissa.issareader.app.ui.ask

import com.benjaminissa.issareader.ask.AskSource
import com.benjaminissa.issareader.ask.Passage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.text.BreakIterator

/**
 * The two strings under an answer's source chips. Swift's `AskSourceLabelTests`.
 *
 * Both have a wrong answer that ships silently — a chip cut mid-word reads as
 * a rendering fault, and a card headed by an empty string reads as a missing
 * chapter.
 */
class AskSourceLabelTest {
    private fun source(ordinal: Int = 1, spine: Int = 0, text: String) = AskSource(
        ordinal = ordinal,
        passage = Passage(
            spineIndex = spine,
            ordinal = 0,
            start = 0,
            end = text.length,
            words = text.split(Regex("\\s+")).count { it.isNotEmpty() },
            text = text,
        ),
    )

    // The chip

    @Test
    fun `a short excerpt is quoted whole`() {
        assertEquals("“a White Rabbit”", AskSourceLabel.chip(source(text = "a White Rabbit")))
    }

    @Test
    fun `a long excerpt is cut at a word boundary, never mid-word`() {
        // "…a White Rab…" reads as a rendering fault rather than a quotation,
        // and there are up to three of these on one line.
        val excerpt = "when suddenly a White Rabbit with pink eyes ran close by her"
        val chip = AskSourceLabel.chip(source(text = excerpt))
        assertTrue(chip.startsWith("“when suddenly"))
        assertTrue(chip.endsWith("…”"))
        val quoted = chip.drop(1).dropLast(2)
        assertTrue(characters(quoted) <= 32)
        assertFalse(quoted.endsWith(" "))
        // Every word in it is a whole word of the excerpt.
        val words = excerpt.split(" ")
        for (word in quoted.split(" ")) assertTrue(word, word in words)
    }

    @Test
    fun `the newlines a passage carries from the page never reach the chip`() {
        // A passage keeps the whitespace the chapter's tiling gave it, and a chip is one line.
        assertEquals("“Down, down, down.”", AskSourceLabel.chip(source(text = "  Down,\n   down,\n  down.  ")))
    }

    @Test
    fun `an excerpt with nothing readable in it falls back to its number`() {
        assertEquals("4", AskSourceLabel.chip(source(ordinal = 4, text = "   \n  ")))
    }

    /** Counted as a reader counts, so an accented or emoji-laden excerpt is not cut short or mid-character. */
    @Test
    fun `the limit counts characters as a reader sees them`() {
        val excerpt = "Café " + "👩‍👩‍👧".repeat(10) + " and the rest of the line"
        val chip = AskSourceLabel.chip(source(text = excerpt))
        assertTrue(chip.endsWith("…”"))
        assertTrue(characters(chip.drop(1).dropLast(2)) <= 32)
    }

    // The card's heading

    @Test
    fun `the chapter's own name is what the card is headed with`() {
        assertEquals("Chapter I", AskSourceLabel.heading(source(spine = 2, text = "…"), "Chapter I"))
    }

    @Test
    fun `a book that never named the chapter is headed by the section the model was shown`() {
        // The same number the excerpt carried in the prompt — `[1] (Section 3)`.
        assertEquals("Section 3", AskSourceLabel.heading(source(spine = 2, text = "…"), null))
        // A navigation entry with a blank title is a real EPUB, and it must not
        // produce a card headed by nothing at all.
        assertEquals("Section 1", AskSourceLabel.heading(source(spine = 0, text = "…"), "  "))
    }

    private fun characters(text: String): Int {
        val iterator = BreakIterator.getCharacterInstance()
        iterator.setText(text)
        var count = 0
        while (iterator.next() != BreakIterator.DONE) count += 1
        return count
    }
}
