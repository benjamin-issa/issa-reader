package com.benjaminissa.issareader.app.ui.ask

import com.benjaminissa.issareader.ask.AskAnswer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Locale

/**
 * What the sheet is allowed to claim about who wrote an answer. Swift's
 * `AskOriginLabelTests`, with Gemini Nano.
 *
 * The pill said "Generated on device" under every answered state, and only one
 * of the three has a model behind them. The other two are the "not yet"
 * sentinel — a constant in this repository — and `KinshipExtractor`'s
 * sentence, which is a name read straight out of a paragraph the reader has
 * already passed.
 */
class AskOriginLabelTest {
    @Test
    fun `a model's answer says a model wrote it, on this machine`() {
        val label = assertNotNull(AskOriginLabel.forState(AskOriginState.Answered(AskAnswer.Origin.MODEL)))
        assertEquals("Generated on device · Gemini Nano", label.phrase)
        assertEquals("sparkles", label.glyph)
    }

    /** A hardcoded refusal is not generated prose, and a disclosure under it is a claim about text no machine composed. */
    @Test
    fun `a withheld answer discloses nothing, because nothing was written`() {
        assertNull(AskOriginLabel.forState(AskOriginState.Answered(AskAnswer.Origin.WITHHELD)))
    }

    /** Quieter, not absent: the only answer whose citation is provably the sentence it came from. */
    @Test
    fun `the book's own sentence says it came from the book`() {
        val label = assertNotNull(AskOriginLabel.forState(AskOriginState.Answered(AskAnswer.Origin.BOOK)))
        assertEquals("From the book", label.phrase)
        assertFalse(label.phrase.contains("Gemini Nano"))
        assertNotEquals("sparkles", label.glyph)
    }

    /** Nothing said "on device" while the reader was deciding whether to type — the moment the fact could change their mind. */
    @Test
    fun `a blank field still says where the answer will come from`() {
        val label = assertNotNull(AskOriginLabel.forState(AskOriginState.Unanswered))
        assertEquals("On device · Gemini Nano", label.phrase)
        assertEquals("sparkles", label.glyph)
    }

    /** "Generated" is a statement about words on screen, and before a question is asked there are none. */
    @Test
    fun `nothing is claimed to have been written until something has been`() {
        val composing = assertNotNull(AskOriginLabel.forState(AskOriginState.Unanswered))
        val answered = assertNotNull(AskOriginLabel.forState(AskOriginState.Answered(AskAnswer.Origin.MODEL)))
        assertNotEquals(answered.phrase, composing.phrase)
        assertFalse(composing.phrase.lowercase(Locale.ROOT).contains("generated"))
        assertFalse(composing.spoken.lowercase(Locale.ROOT).contains("generated"))
        // …and it still says the thing the reader is being told: on device.
        assertTrue(composing.phrase.lowercase(Locale.ROOT).contains("on device"))
    }

    @Test
    fun `every label a reader can see is also one a screen reader can read`() {
        for (state in listOf(AskOriginState.Unanswered, AskOriginState.Answered(AskAnswer.Origin.MODEL), AskOriginState.Answered(AskAnswer.Origin.BOOK))) {
            val label = AskOriginLabel.forState(state)
            assertNotNull("$state should be disclosed", label)
            // Not the phrase itself: the middle dot is punctuation a screen
            // reader has no good reading of, and the glyph would be read separately.
            assertTrue(label!!.spoken.isNotEmpty())
            assertFalse(label.spoken.contains("·"))
        }
    }

    private fun <T : Any> assertNotNull(value: T?): T {
        assertNotNull(null, value)
        return value!!
    }
}
