package com.benjaminissa.issareader.core.model

import com.benjaminissa.issareader.core.CurrentBookSnapshot
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Saying how far through a book you are: one quantity, one formatter. Ported
 * from `ReadingProgressTests.swift`.
 *
 * The bug: the reader's footer and the widget rounded while the book screen and
 * the Continue card truncated, so a book at 13.7% read 14% in one place and 13%
 * in the other — always exactly one apart, and never closing.
 */
class ReadingProgressTest {
    /** The half-percent band reads the same everywhere it is shown. */
    @Test
    fun roundsRatherThanTruncates() {
        assertEquals(14, ReadingProgress.percent(0.135))
        assertEquals(14, ReadingProgress.percent(0.137))
        assertEquals(14, ReadingProgress.percent(0.1399))
        // And below the half, it still rounds down.
        assertEquals(13, ReadingProgress.percent(0.134))
    }

    /** A book that is all but finished reads 100. */
    @Test
    fun nearlyDoneRoundsUp() {
        assertEquals(100, ReadingProgress.percent(0.996))
        assertEquals(100, ReadingProgress.percent(1.0))
    }

    /** An unstarted book reads zero, not one. */
    @Test
    fun unstartedIsZero() {
        assertEquals(0, ReadingProgress.percent(0.0))
        assertEquals(0, ReadingProgress.percent(0.004))
    }

    /** A broken clock reads zero rather than crashing: the book clock has produced NaN before. */
    @Test
    fun nonFiniteIsZero() {
        assertEquals(0, ReadingProgress.percent(Double.NaN))
        assertEquals(0, ReadingProgress.percent(Double.POSITIVE_INFINITY))
    }

    /** A value outside 0...1 is clamped, not wrapped. */
    @Test
    fun clampsOutOfRange() {
        assertEquals(100, ReadingProgress.percent(1.4))
        assertEquals(0, ReadingProgress.percent(-0.2))
    }

    /** The label is the number with a percent sign. */
    @Test
    fun labelMatchesTheNumber() {
        assertEquals("14%", ReadingProgress.percentText(0.137))
        assertEquals("0%", ReadingProgress.percentText(0.0))
    }

    /** The widget snapshot agrees with every other surface. */
    @Test
    fun snapshotAgrees() {
        val snapshot = CurrentBookSnapshot(bookId = "u", title = "T", author = "A", progress = 0.137)
        assertEquals(ReadingProgress.percent(0.137), snapshot.percent)
        assertEquals(14, snapshot.percent)
    }
}
