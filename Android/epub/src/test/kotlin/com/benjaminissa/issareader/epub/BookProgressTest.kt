package com.benjaminissa.issareader.epub

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/**
 * How far through the book.
 *
 * Book progress used to count spine items equally, so a two-page front-matter
 * wrapper weighed as much as a forty-page chapter. That was tolerable while the
 * number only fed a hidden Handoff payload; it is now shown to the reader, and
 * saved to the server as `totalProgression`. Ported from `BookProgressTests.swift`.
 */
class BookProgressTest {
    /**
     * Sizes chosen to be lopsided the way a real EPUB is: three tiny wrappers
     * around one long chapter. The real package's shape, with known weights.
     */
    private fun book(sizes: List<Int>): EpubPackage {
        val real = openFixture("alice")
        return real.copy(
            spine = real.spine.take(sizes.size),
            frontMatter = emptySet(),
            spineWeights = sizes.map { it.toDouble() },
        )
    }

    @Test
    fun weightsBySize() {
        // cover 500 · title 500 · chapter 99_000
        val book = book(listOf(500, 500, 99_000))

        // Halfway through the long final chapter is ~50% of the book, not the
        // 83% that counting three equal items would have produced.
        val weighted = book.bookProgress(spineIndex = 2, within = 0.5)
        assertTrue("got $weighted", weighted > 0.5 && weighted < 0.52)

        val byIndex = (2.0 + 0.5) / 3.0
        assertTrue(abs(byIndex - 0.833) < 0.01)
        assertTrue("the two must differ substantially", weighted < byIndex - 0.3)
    }

    @Test
    fun endpoints() {
        val book = book(listOf(1_000, 2_000, 3_000))
        assertEquals(0.0, book.bookProgress(spineIndex = 0, within = 0.0), 0.0)
        assertTrue(abs(book.bookProgress(spineIndex = 2, within = 1.0) - 1) < 0.0001)
    }

    @Test
    fun monotonic() {
        val book = book(listOf(800, 40_000, 1_200, 25_000))
        var previous = -1.0
        for (index in 0 until 4) {
            for (within in listOf(0.0, 0.5, 0.99)) {
                val value = book.bookProgress(spineIndex = index, within = within)
                assertTrue("went backwards at $index/$within", value >= previous)
                previous = value
            }
        }
    }

    /**
     * A book whose central directory reports nothing must still produce a
     * sensible number rather than a division by zero.
     */
    @Test
    fun fallsBackWithoutSizes() {
        val book = book(listOf(0, 0, 0))
        assertTrue(abs(book.bookProgress(spineIndex = 1, within = 0.5) - 0.5) < 0.0001)
    }

    /** An out-of-range index and a wild fraction are clamped. */
    @Test
    fun clamped() {
        val book = book(listOf(1_000, 1_000))
        assertEquals(0.0, book.bookProgress(spineIndex = 99, within = 0.5), 0.0)
        assertTrue(book.bookProgress(spineIndex = 0, within = 5.0) <= 1)
        assertTrue(book.bookProgress(spineIndex = 0, within = -5.0) >= 0)
    }
}
