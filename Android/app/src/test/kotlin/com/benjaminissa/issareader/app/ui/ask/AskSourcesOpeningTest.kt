package com.benjaminissa.issareader.app.ui.ask

import com.benjaminissa.issareader.app.ui.ask.AskSourcesOpening.Opened
import com.benjaminissa.issareader.ask.AskSource
import com.benjaminissa.issareader.ask.Passage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Which excerpt the sources row opens by itself, and what it does when the
 * reader disagrees. Swift's `AskSourcesOpeningTests`.
 *
 * Two faults, both from one ambiguous sentinel: a closed card and an untouched
 * one were the same value, and a second answer rendered into the same row kept
 * the first answer's ordinal.
 */
class AskSourcesOpeningTest {
    private fun sources(ordinals: List<Int>, spine: Int = 2): List<AskSource> = ordinals.map { ordinal ->
        AskSource(
            ordinal = ordinal,
            passage = Passage(
                spineIndex = spine,
                ordinal = ordinal,
                start = ordinal * 100,
                end = ordinal * 100 + 50,
                words = 10,
                text = "excerpt $ordinal of spine $spine",
            ),
        )
    }

    /** The reason the row exists: the extra sentence comes from the book, and nobody was tapping to get it. */
    @Test
    fun `an answer nobody has touched shows its first excerpt`() {
        assertEquals(1, AskSourcesOpening.ordinal(Opened.Untouched, sources(listOf(1, 2, 3))))
        // Citations are not promised to start at 1 or to be contiguous.
        assertEquals(2, AskSourcesOpening.ordinal(Opened.Untouched, sources(listOf(2, 5))))
        assertNull(AskSourcesOpening.ordinal(Opened.Untouched, emptyList()))
    }

    @Test
    fun `a card the reader closed stays closed`() {
        val sources = sources(listOf(1, 2, 3))
        val afterClosing = AskSourcesOpening.tapping(1, Opened.Untouched, sources)
        assertEquals(Opened.Closed, afterClosing)
        assertNull(AskSourcesOpening.ordinal(afterClosing, sources))
        // Which is the part `Int?` could not express: closing must not land back
        // on the state that opens the first card again.
        assertNotEquals(Opened.Untouched, afterClosing)
    }

    @Test
    fun `tapping a different chip moves the card rather than closing it`() {
        val sources = sources(listOf(1, 2, 3))
        val opened = AskSourcesOpening.tapping(3, Opened.Untouched, sources)
        assertEquals(Opened.Source(3), opened)
        assertEquals(3, AskSourcesOpening.ordinal(opened, sources))
        assertEquals(Opened.Closed, AskSourcesOpening.tapping(3, opened, sources))
        // And a closed row opens the one that was tapped, not the first one.
        assertEquals(Opened.Source(2), AskSourcesOpening.tapping(2, Opened.Closed, sources))
    }

    /** The row is reused for the next answer, so the state is reset by the answer changing. */
    @Test
    fun `a new answer opens its own first excerpt, not the last answer's ordinal`() {
        val first = sources(listOf(1, 2, 3), spine = 2)
        val second = sources(listOf(1, 2, 3), spine = 9)
        val reader = AskSourcesOpening.tapping(3, Opened.Untouched, first)
        assertEquals(3, AskSourcesOpening.ordinal(reader, first))
        // After the reset the new answer behaves as an untouched one.
        assertEquals(1, AskSourcesOpening.ordinal(Opened.Untouched, second))
    }

    /** Even without a reset, an ordinal the answer on screen does not have reads as nothing open. */
    @Test
    fun `an ordinal this answer does not have opens nothing`() {
        assertNull(AskSourcesOpening.ordinal(Opened.Source(7), sources(listOf(1, 2, 3))))
        assertEquals(2, AskSourcesOpening.ordinal(Opened.Source(2), sources(listOf(1, 2, 3))))
        // And tapping the chip it belongs to still opens it, rather than
        // reading as "already open" and closing.
        assertEquals(Opened.Source(2), AskSourcesOpening.tapping(2, Opened.Source(7), sources(listOf(1, 2, 3))))
    }
}
