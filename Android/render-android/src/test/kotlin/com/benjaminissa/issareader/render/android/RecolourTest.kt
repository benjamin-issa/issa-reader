package com.benjaminissa.issareader.render.android

import com.benjaminissa.issareader.render.ReaderTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Switching theme repaints the page; it does not rebuild it. Ported from
 * `RecolourTests.swift`.
 *
 * A theme change alters the ink and no metric. The Swift reader once treated
 * it as a typography change, and the reparse it triggered meant an inflate, an
 * XML parse and a decode of every plate in the chapter, on the main thread,
 * every time the reader switched theme — or the system slid into dark mode on
 * its own, at sunset. On Android the ink is the paint's alone, so "every run
 * repainted" is one paint, and the case for it here is that the page draws in
 * the new ink.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36])
class RecolourTest {
    private fun longChapter(): ChapterLayout = laidOut(aliceChapterLongerThan(6000), 320.0, 480.0)

    /** The consequence if this were false: the reader taps Night in the middle of a sentence and lands somewhere else. */
    @Test
    fun `the reader does not move`() {
        val layout = longChapter()
        val before = layout.pages
        assertTrue("a one-page chapter would prove nothing", before.size > 2)
        layout.recolour(ReaderTheme.NIGHT.text)
        assertEquals("nothing was repainted, so nothing below is evidence", ReaderTheme.NIGHT.text.argb, layout.ink)
        assertEquals(before, layout.pages)
    }

    /**
     * The text itself is untouched — only its ink. A repaint that dropped the
     * fragment ids would silently kill tap-to-play and every saved highlight.
     */
    @Test
    fun `the words, the ids and the pictures all survive`() {
        val layout = longChapter()
        val text = layout.text
        val ids = layout.fragmentRanges
        val idsInText = layout.chapter.runs.mapNotNull { it.fragmentId }
        assertTrue("the fixture has to carry ids for this to test anything", idsInText.isNotEmpty())
        // Night, not sepia: sepia's ink is paper's ink, so a repaint to it is
        // indistinguishable from no repaint.
        layout.recolour(ReaderTheme.NIGHT.text)
        assertEquals(ReaderTheme.NIGHT.text.argb, layout.ink)
        assertEquals(text, layout.text)
        assertEquals(ids, layout.fragmentRanges)
        assertEquals(idsInText, layout.chapter.runs.mapNotNull { it.fragmentId })
    }

    /**
     * The one a pure attribute check would miss: does the geometry the pages
     * describe still draw — and in the new ink.
     */
    @Test
    fun `the page still draws after a repaint, in the new ink`() {
        val layout = longChapter()
        val page = layout.pages.drop(2).first()
        val before = inkCoverage(layout, page)
        assertTrue("the fixture page has to have ink on it to start with", before > 0.001)
        // Slate: dark enough to count against a white canvas, and different
        // enough from paper's ink to prove the repaint happened.
        layout.recolour(ReaderTheme.SLATE.text)
        assertEquals(ReaderTheme.SLATE.text.argb, layout.ink)
        val after = inkCoverage(layout, page)
        assertTrue("the page went blank: coverage $before → $after", after > 0.001)

        // And the ink drawn is the new one: some pixel is slate's colour.
        val bitmap = render(layout, page, 320, 480)
        val pixels = IntArray(320 * 480)
        bitmap.getPixels(pixels, 0, 320, 0, 0, 320, 480)
        assertTrue("no pixel carries the new ink", pixels.any { it == ReaderTheme.SLATE.text.argb })
    }

    /**
     * Every run, not just the first. The Swift parser writes the ink per
     * attribute run, so a repaint that reached only part of the chapter would
     * leave a page of black type on a black page. Here the ink is one paint,
     * and the check is in pixels: after a repaint, nothing on the page is
     * drawn in the old ink.
     */
    @Test
    fun `every run is repainted`() {
        val layout = longChapter()
        val page = layout.pages.drop(2).first()
        val old = ReaderTheme.PAPER.text.argb
        fun pixels(): IntArray {
            val bitmap = render(layout, page, 320, 480)
            return IntArray(320 * 480).also { bitmap.getPixels(it, 0, 320, 0, 0, 320, 480) }
        }
        assertTrue("the page has to start in paper's ink", pixels().any { it == old })
        layout.recolour(ReaderTheme.SLATE.text)
        val after = pixels()
        assertTrue("some run kept the old ink", after.none { it == old })
        assertTrue(after.any { it == ReaderTheme.SLATE.text.argb })
    }

    /** A repaint must not shift what a page paints, which is what `draw` and the spoken page text both read. */
    @Test
    fun `a repainted page still paints its own characters`() {
        val layout = longChapter()
        layout.recolour(ReaderTheme.SLATE.text)
        for (page in layout.pages) {
            val painted = layout.paintedCharacterRange(page)
            assertTrue("page ${page.index} paints characters before its own range", painted.location >= page.characterRange.location)
            assertTrue("page ${page.index} paints into the next page", painted.end <= page.characterRange.end + 1)
        }
    }
}
