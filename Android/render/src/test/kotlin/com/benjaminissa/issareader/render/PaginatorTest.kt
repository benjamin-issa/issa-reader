package com.benjaminissa.issareader.render

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The arithmetic half of `ChapterLayout`: cutting lines into pages, and the
 * lookups answered from pages and ranges alone. The Swift suites test these
 * through a laid-out chapter (`RenderTests`' `PaginatorTests` and
 * `PageBoundaryTests`, `TapToSeekTests`); those are ported against Android's
 * layout in `:render-android`. These hold the rules themselves, on lines whose
 * every number is known.
 */
class PaginatorTest {
    /** [count] lines of [height], flush, each [perLine] characters, starting at [top]. */
    private fun lines(count: Int, height: Double, perLine: Int, top: Double = 0.0, startAt: Int = 0) = (0 until count).map {
        LineBox(top + it * height, top + (it + 1) * height, startAt + it * perLine, startAt + (it + 1) * perLine)
    }

    @Test
    fun `a line that would cross the page edge starts the next page`() {
        val pages = Paginator.computePages(lines(10, 30.0, 40), pageHeight = 100.0, textLength = 400)
        // Three 30-point lines fit in 100; the fourth (90–120) would cross.
        assertEquals(listOf(0.0, 90.0, 180.0, 270.0), pages.map { it.yOffset })
        assertEquals(listOf(0, 120, 240, 360), pages.map { it.characterRange.location })
        assertEquals(Double.POSITIVE_INFINITY, pages.last().contentBottom, 0.0)
        assertEquals(90.0, pages.first().contentBottom, 0.0)
    }

    @Test
    fun `pages tile the chapter, and every page's content fits its height`() {
        val pages = Paginator.computePages(lines(57, 23.7, 61), pageHeight = 400.0, textLength = 57 * 61)
        var expected = 0
        for (page in pages) {
            assertEquals(expected, page.characterRange.location)
            expected = page.characterRange.end
            if (page.contentBottom.isFinite()) assertTrue(page.contentBottom - page.yOffset <= 400.0)
        }
        assertEquals(57 * 61, expected)
    }

    /** The anti-loop guard: a plate taller than a page gets a page of its own rather than stopping pagination. */
    @Test
    fun `a line taller than a page gets a page to itself`() {
        val tall = listOf(LineBox(0.0, 20.0, 0, 10), LineBox(20.0, 520.0, 10, 12), LineBox(520.0, 540.0, 12, 20))
        val pages = Paginator.computePages(tall, pageHeight = 300.0, textLength = 20)
        assertEquals(listOf(0, 10, 12), pages.map { it.characterRange.location })
        assertEquals(listOf(0.0, 20.0, 520.0), pages.map { it.yOffset })
    }

    @Test
    fun `an empty chapter is one empty page`() {
        val pages = Paginator.computePages(emptyList(), pageHeight = 300.0, textLength = 0)
        assertEquals(1, pages.size)
        assertEquals(TextRange(0, 0), pages.single().characterRange)
    }

    /**
     * The painted range is the lines between the page's top and its content
     * bottom, with no tolerance: the line ending exactly where the page begins
     * belongs to the page before.
     */
    @Test
    fun `a page paints exactly the lines it owns`() {
        val all = lines(10, 30.0, 40)
        val pages = Paginator.computePages(all, pageHeight = 100.0, textLength = 400)
        for (page in pages) assertEquals(page.characterRange, Paginator.paintedCharacterRange(all, page))
    }

    @Test
    fun `lookups by fragment, by offset and by progression`() {
        val pages = Paginator.computePages(lines(10, 30.0, 40), pageHeight = 100.0, textLength = 400)
        // A fragment that begins on page 0 and runs onto page 1 is on page 0.
        assertEquals(0, Paginator.pageContainingFragment(pages, TextRange(100, 50))?.index)
        assertEquals(1, Paginator.pageContainingFragment(pages, TextRange(130, 5))?.index)
        assertNull(Paginator.pageContainingFragment(pages, null))
        assertEquals(2, Paginator.pageContainingOffset(pages, 250)?.index)
        // Past the end, the last page.
        assertEquals(3, Paginator.pageContainingOffset(pages, 10_000)?.index)
        assertEquals(0.3, Paginator.progression(pages[1], 400), 1e-12)
        assertEquals(0.0, Paginator.progression(pages[1], 0), 0.0)
    }

    /** Nearest-enclosing wins, then length, then id; and a tap off every fragment finds the nearest on the page. */
    @Test
    fun `a tap's fragment is the innermost, deterministically`() {
        val page = RenderedPage(0, 0.0, 100.0, Double.POSITIVE_INFINITY, TextRange(0, 100))
        val ranges = mapOf(
            "para" to TextRange(0, 60),
            "s1" to TextRange(10, 20),
            "s2" to TextRange(40, 20),
            "twin-b" to TextRange(70, 10),
            "twin-a" to TextRange(70, 10),
        )
        assertEquals("s1", Paginator.fragmentId(15, page, ranges))
        assertEquals("para", Paginator.fragmentId(35, page, ranges))
        assertEquals("para", Paginator.fragmentId(15, page, ranges) { it != "s1" })
        assertEquals("twin-a", Paginator.fragmentId(75, page, ranges))
        // Between paragraphs, the nearest usable one; ties by id.
        assertEquals("twin-a", Paginator.fragmentId(85, page, ranges))
        // Clamped into the page: one past its end is its last character.
        val first = RenderedPage(0, 0.0, 100.0, 100.0, TextRange(0, 50))
        assertEquals("s2", Paginator.fragmentId(50, first, ranges) { it != "para" })
    }

    @Test
    fun `the first fragment beginning on a page, filtered`() {
        val chapter = parse(
            "<html><body><p><span id=\"s0\">One sentence here. </span><span id=\"s1\">Two more. </span>" +
                "<span id=\"s2\">Three.</span></p></body></html>",
        )
        val s1 = chapter.fragmentRanges.getValue("s1")
        // A page starting part-way into s0.
        val page = RenderedPage(1, 0.0, 100.0, Double.POSITIVE_INFINITY, TextRange(4, chapter.text.length - 4))
        assertEquals("s1", Paginator.firstFragment(chapter, page))
        assertEquals("s2", Paginator.firstFragment(chapter, page) { it != "s1" })
        assertNull(Paginator.firstFragment(chapter, page) { false })
        assertTrue(s1.location >= page.characterRange.location)
    }

    @Test
    fun `a long press selects a word, apostrophes and hyphens included`() {
        val text = "It's a well-known fact, isn’t it?"
        assertEquals(TextRange(0, 4), Paginator.wordRange(text, 1))
        assertEquals(TextRange(7, 10), Paginator.wordRange(text, 10))
        assertEquals(TextRange(24, 5), Paginator.wordRange(text, 26))
        // A press on the space after a word reaches back to that word, as the
        // Swift walk does; between two separators there is nothing.
        assertEquals(TextRange(0, 4), Paginator.wordRange(text, 4))
        assertNull("a separator alone is no word", Paginator.wordRange("a  b", 2))
        assertNull(Paginator.wordRange(text, 99))
    }

    @Test
    fun `a sentence is the narrated fragment when there is one, and a guess when not`() {
        val text = "First one. Second one here. Third."
        assertEquals(TextRange(11, 16), Paginator.sentenceRange(text, mapOf("s" to TextRange(11, 16)), 13))
        val guessed = Paginator.sentenceRange(text, emptyMap(), 13)!!
        assertTrue(text.substring(guessed.location, guessed.end).startsWith("Second one here."))
    }
}
