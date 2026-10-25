package com.benjaminissa.issareader.render.android

import com.benjaminissa.issareader.render.PageRect
import com.benjaminissa.issareader.render.ReaderStyle
import com.benjaminissa.issareader.render.TextRange
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import kotlin.math.abs
import kotlin.math.min

/**
 * The layout half of `RenderTests.swift`: `PaginatorTests`.
 *
 * Page counts here are Android's, not TextKit's — the line breaker and the
 * metrics differ even with the same font files — so no test pins a count; the
 * ones that did assert the invariants the count stood for instead (more than
 * one page for a long chapter, a narrower page never fewer).
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36])
class PaginatorLayoutTest {
    @Test
    fun `splits a chapter into pages that cover all of it`() {
        val content = aliceChapterLongerThan(4000)
        val layout = laidOut(content, 340.0, 560.0)
        assertTrue("a long chapter should need more than one page", layout.pages.size > 1)
        // Pages must tile the chapter: contiguous, no gaps, no overlaps.
        var expected = 0
        for (page in layout.pages) {
            assertEquals(expected, page.characterRange.location)
            expected = page.characterRange.end
        }
        assertEquals(content.text.length, expected)
    }

    @Test
    fun `a narrower page yields more pages`() {
        val layout = ChapterLayout(readalongChapter(), ReaderStyle(), testFonts)
        layout.layout(600.0, 400.0)
        val wide = layout.pages.size
        layout.layout(240.0, 200.0)
        val narrow = layout.pages.size
        assertTrue(narrow >= wide)
        assertTrue(narrow > 0)
    }

    @Test
    fun `resolves highlight rectangles for a narrated fragment`() {
        val layout = laidOut(readalongChapter(), 340.0, 560.0)
        val page = layout.pageContainingFragment("ch01-s1")!!
        val rects = layout.highlightRects("ch01-s1", page)
        assertTrue("a narrated sentence must resolve to at least one rectangle", rects.isNotEmpty())
        for (rect in rects) assertTrue(rect.width > 0 && rect.height > 0)
    }

    @Test
    fun `an unknown fragment yields no rectangles rather than crashing`() {
        val layout = laidOut(readalongChapter(), 340.0, 560.0)
        assertTrue(layout.highlightRects("does-not-exist", layout.pages.first()).isEmpty())
        assertNull(layout.pageContainingFragment("does-not-exist"))
    }

    @Test
    fun `every narrated fragment can be located on some page`() {
        val chapter = readalongChapter()
        val layout = laidOut(chapter, 300.0, 220.0)
        for (id in chapter.fragmentRanges.keys) assertNotNull("fragment $id is on no page", layout.pageContainingFragment(id))
    }

    /**
     * The contract the television's page turn rests on: turning the page while
     * narration plays seeks the voice to the first sentence *beginning* on the
     * new page. If it answered with the sentence merely visible at the top —
     * which usually began on the page before — the seek would turn the book
     * straight back.
     */
    @Test
    fun `the first fragment on a page never starts before the page does`() {
        val layout = laidOut(readalongChapter(), 300.0, 220.0)
        assertTrue("one page would not exercise a page break", layout.pages.size > 1)
        for (page in layout.pages.drop(1)) {
            val id = layout.firstFragment(page) ?: continue
            val range = layout.fragmentRange(id)!!
            assertTrue("$id starts before page ${page.index}", range.location >= page.characterRange.location)
        }
    }

    /**
     * The filter is what lets a caller say "the first *narrated* sentence":
     * element ids are not all sentences, so rejecting the answer afterwards
     * would leave a wrapper shadowing the sentence inside it.
     */
    @Test
    fun `rejecting the first fragment yields the next one beginning on the page`() {
        val layout = laidOut(readalongChapter(), 300.0, 220.0)
        var checked = 0
        for (page in layout.pages) {
            val first = layout.firstFragment(page) ?: continue
            val second = layout.firstFragment(page) { it != first } ?: continue
            checked += 1
            assertTrue(second != first)
            val firstRange = layout.fragmentRange(first)!!
            val secondRange = layout.fragmentRange(second)!!
            assertTrue(secondRange.location >= page.characterRange.location)
            assertTrue("the replacement must come after the id that was refused", secondRange.location > firstRange.location)
        }
        assertTrue("no page carried two fragments, so nothing was tested", checked > 0)
    }

    @Test
    fun `a filter that refuses everything finds nothing`() {
        val layout = laidOut(readalongChapter(), 340.0, 560.0)
        assertNull(layout.firstFragment(layout.pages.first()) { false })
    }
}

/**
 * Pagination and drawing have to agree about what is on a page. Ported from
 * `RenderTests.swift`'s `PageBoundaryTests`.
 *
 * They disagreed once: pagination refused to split a line across a boundary,
 * but drawing bounded itself by the page rectangle, so the next page's opening
 * line was painted at the bottom of the current one and clipped mid-glyph —
 * then repeated in full on the turn.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36])
class PageBoundaryTest {
    companion object {
        fun longChapterLayout(): ChapterLayout = laidOut(aliceChapterLongerThan(6000), 320.0, 480.0)

        /**
         * One paragraph with no internal breaks, long enough to run several
         * times the height of the page: the fixture that forces a paragraph
         * across pages.
         */
        fun oneGiantParagraphLayout(pageHeight: Double = 400.0): ChapterLayout {
            val sentence = "The lamplighter went from post to post along the empty street. "
            return laidOut(parse("<html><body><p>" + sentence.repeat(40) + "</p></body></html>"), 320.0, pageHeight)
        }

        /**
         * Sentence spans across several pages, so some span inevitably
         * straddles a page boundary.
         *
         * 370 tall where the Swift fixture is 400: at 400, Literata as Android
         * sets it puts every one of these sentences on exactly two lines and
         * every page holds twelve lines, so each page break falls between two
         * sentences and nothing straddles — a coincidence of metrics the
         * fixture must not rest on. At 370 a page holds eleven, and every
         * other break falls mid-sentence.
         */
        fun spannedParagraphLayout(): ChapterLayout {
            val sentence = "The lamplighter went from post to post along the empty street. "
            val body = "<p>" + (0 until 80).joinToString("") { "<span id=\"s$it\">$sentence</span>" } + "</p>"
            return laidOut(parse("<html><body>$body</body></html>"), 320.0, 370.0)
        }
    }

    @Test
    fun `a page paints only its own characters`() {
        val layout = longChapterLayout()
        assertTrue(layout.pages.size > 2)
        for (page in layout.pages) {
            val painted = layout.paintedCharacterRange(page)
            assertTrue("page ${page.index} paints characters before its own range", painted.location >= page.characterRange.location)
            assertTrue("page ${page.index} paints into the next page", painted.end <= page.characterRange.end + 1)
        }
    }

    @Test
    fun `pages tile the chapter with no gap and no overlap`() {
        val layout = longChapterLayout()
        var expected = 0
        for (page in layout.pages) {
            assertEquals(expected, page.characterRange.location)
            expected = page.characterRange.end
        }
        assertEquals(layout.text.length, expected)
    }

    @Test
    fun `page tops are strictly increasing, and the last runs to infinity`() {
        val layout = longChapterLayout()
        var previous = Double.NEGATIVE_INFINITY
        for (page in layout.pages) {
            assertTrue(page.yOffset > previous || page.index == 0)
            assertTrue(page.contentBottom > page.yOffset)
            previous = page.yOffset
        }
        assertEquals(Double.POSITIVE_INFINITY, layout.pages.last().contentBottom, 0.0)
    }

    /**
     * A paragraph too long to fit the remaining room on a page used to move
     * in its entirety to the next one; a paragraph longer than a page then had
     * no boundary anywhere that worked, and its tail was clipped silently.
     */
    @Test
    fun `no page's content runs past the height it was given`() {
        val layout = oneGiantParagraphLayout()
        assertTrue("the fixture should span several pages", layout.pages.size > 3)
        for (page in layout.pages.filter { it.contentBottom.isFinite() }) {
            val used = page.contentBottom - page.yOffset
            assertTrue("page ${page.index} holds ${used}pt of content in a 400pt page", used <= 400 + 0.5)
        }
    }

    @Test
    fun `no page wastes more than about a line's worth of room`() {
        val layout = oneGiantParagraphLayout()
        for (page in layout.pages.filter { it.contentBottom.isFinite() }) {
            val wasted = 400 - (page.contentBottom - page.yOffset)
            assertTrue("page ${page.index} leaves ${wasted}pt unused out of 400", wasted < 60)
        }
    }

    /**
     * The strongest check: every character of the chapter is painted on
     * exactly one page — proved here for `paintedCharacterRange`, which `draw`
     * and `spokenText` actually use.
     */
    @Test
    fun `the painted ranges of every page reconstruct the whole chapter, with no gap and no overlap`() {
        val layout = oneGiantParagraphLayout()
        var expected = 0
        for (page in layout.pages) {
            val painted = layout.paintedCharacterRange(page)
            if (painted.length <= 0) continue
            assertEquals("page ${page.index} painted range", expected, painted.location)
            expected = painted.end
        }
        assertEquals(layout.text.length, expected)
    }

    @Test
    fun `a real long chapter also never wastes more than about a line of room`() {
        val layout = longChapterLayout()
        for (page in layout.pages.filter { it.contentBottom.isFinite() }) {
            val wasted = 480 - (page.contentBottom - page.yOffset)
            assertTrue("page ${page.index} wastes ${wasted}pt", wasted < 60)
        }
    }

    /**
     * `highlightRects` and `rects(range)` were the last two callers still
     * bounding by the page's height after pages started ending mid-paragraph:
     * a narrated sentence continuing onto the next page painted a bar in the
     * blank band below this page's last line.
     */
    @Test
    fun `highlight rects stop at the page's drawn content, not its height`() {
        val layout = spannedParagraphLayout()
        assertTrue("the fixture should span several pages", layout.pages.size > 3)
        val straddlers = layout.fragmentRanges.filter { (_, range) ->
            layout.pages.count { range.intersection(it.characterRange).length > 0 } > 1
        }
        assertTrue("no span straddles a page boundary", straddlers.isNotEmpty())
        for (page in layout.pages) {
            val localBottom = if (page.contentBottom.isFinite()) page.contentBottom - page.yOffset else Double.MAX_VALUE
            for ((id, range) in layout.fragmentRanges) {
                for (rect in layout.highlightRects(id, page)) {
                    assertTrue("page ${page.index}: $id highlights at ${rect.minY}, below $localBottom", rect.minY < localBottom)
                }
                for (rect in layout.rects(range, page)) {
                    assertTrue("page ${page.index}: $id selection reaches ${rect.minY}", rect.minY < localBottom)
                }
            }
        }
    }

    /** No line is cut by a page edge: every line is wholly inside the band of the page that paints it. */
    @Test
    fun `no line is cut by a page edge`() {
        val layout = longChapterLayout()
        for (page in layout.pages) {
            val range = layout.paintedCharacterRange(page)
            if (range.length <= 0) continue
            for (rect in layout.rects(range, page)) {
                assertTrue("page ${page.index}: a line starts above the page", rect.minY >= -0.5)
                if (page.contentBottom.isFinite()) {
                    assertTrue("page ${page.index}: a line runs past the content bottom", rect.maxY <= page.contentBottom - page.yOffset + 0.5)
                }
            }
        }
    }
}

/**
 * Segments grouped into the lines they sit on. Ported from `RenderTests.swift`'s
 * `SegmentLineTests`. On Android the grouping is not inferred from baselines —
 * the layout knows which line each rectangle came from — but the property the
 * Swift suite pins is the same: one group per band of type, and no band in two
 * groups.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36])
class SegmentLineTest {
    companion object {
        /**
         * Every group must be one band of type: its pieces overlap each other
         * almost entirely. And no two groups may be the same band, or one line
         * has been reported as two.
         */
        fun assertOneBandPerGroup(lines: List<List<PageRect>>, what: String) {
            for (line in lines) {
                val first = line.firstOrNull() ?: throw AssertionError("$what: an empty group")
                for (rect in line.drop(1)) {
                    val overlap = min(first.maxY, rect.maxY) - maxOf(first.minY, rect.minY)
                    assertTrue("$what: $rect is not on the same line as $first", overlap > min(first.height, rect.height) / 2)
                }
            }
            val bands = lines.mapNotNull { it.firstOrNull() }
            for (outer in bands.indices) {
                for (inner in bands.indices) {
                    if (inner <= outer) continue
                    assertTrue("$what: ${bands[outer]} and ${bands[inner]} are the same line in two groups", abs(bands[outer].midY - bands[inner].midY) > 1)
                }
            }
        }
    }

    /**
     * Hundreds of real selections out of *Alice*, justified. TextKit splits a
     * justified line's flush-right remainder into a second, near-zero-width
     * segment on 14 of 436 lines, and the Swift suite also counts those; the
     * Android layout does not split a line except where its direction changes,
     * so that count is TextKit's and is not asserted here — the split case
     * is `a line split by a run of the other direction is still one group`.
     */
    @Test
    fun `every segment of one line of a real chapter comes back in one group`() {
        val content = aliceChapterLongerThan(4000, ReaderStyle(justification = ReaderStyle.Justification.ALWAYS))
        val layout = laidOut(content, 300.0, 480.0)
        var groups = 0
        for (page in layout.pages.take(6)) {
            var location = page.characterRange.location
            while (location < page.characterRange.end) {
                val range = TextRange(location, min(140, page.characterRange.end - location))
                val lines = layout.lines(range, page)
                if (lines.isNotEmpty()) {
                    assertOneBandPerGroup(lines, "selection at $location")
                    groups += lines.size
                    // The flat wrapper is exactly the groups flattened, so no
                    // caller wanting geometry lost a rectangle to the grouping.
                    assertEquals(layout.rects(range, page), lines.flatten())
                }
                location += 37
            }
        }
        assertTrue("the sweep should have covered plenty of lines (was $groups)", groups > 300)
    }

    /**
     * The direct test of the grouping: one line, genuinely two segments, the
     * split forced by a run of the other direction. The Swift fixture wraps
     * onto three lines in TextKit; how many it wraps onto here depends on the
     * line breaker, so the assertion is on the line that holds the change.
     */
    @Test
    fun `a line split by a run of the other direction is still one group`() {
        val chapter = handBuilt(
            listOf(
                "He wrote " to { this },
                "אבג דה" to { this },
                " on the page and then went out for a very long walk indeed." to { this },
            ),
        ).let { it.copy(fragmentRanges = mapOf("s0" to TextRange(0, it.text.length)), runs = it.runs.map { run -> run.copy(fragmentId = "s0") }) }
        val layout = laidOut(chapter, 240.0, 560.0)
        val page = layout.pageContainingFragment("s0")!!
        val lines = layout.highlightLines("s0", page)
        assertTrue("the fixture wraps, was ${lines.size} lines", lines.size >= 2)
        assertOneBandPerGroup(lines, "bidirectional line")
        val first = lines.first()
        assertTrue("the line either side of the direction change is more than one segment", first.size >= 2)
        assertTrue("and they all sit on the same line", first.all { it.minY == first[0].minY })
        assertEquals(layout.highlightRects("s0", page), lines.flatten())
    }

    /**
     * The page-boundary guards run before the grouping, so a fragment that
     * leaves this page and comes back cannot file its first segment back on
     * the page under a line that was dropped.
     */
    @Test
    fun `a fragment crossing a page boundary groups only what the page keeps`() {
        val layout = PageBoundaryTest.spannedParagraphLayout()
        assertTrue("the fixture should span several pages", layout.pages.size > 3)
        for (page in layout.pages) {
            val localBottom = if (page.contentBottom.isFinite()) page.contentBottom - page.yOffset else Double.MAX_VALUE
            for (id in layout.fragmentRanges.keys.sorted()) {
                val lines = layout.highlightLines(id, page)
                assertOneBandPerGroup(lines, "page ${page.index}, $id")
                for (rect in lines.flatten()) assertTrue(rect.minY < localBottom)
            }
        }
    }
}
