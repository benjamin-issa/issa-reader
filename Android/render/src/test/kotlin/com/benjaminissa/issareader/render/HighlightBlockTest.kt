package com.benjaminissa.issareader.render

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * The highlight block's geometry. Ported from `HighlightBlockTests.swift`: the
 * cases about rows, runs, straightening, the outline and its rounding. The
 * two that rasterise (the seam's alpha) and the three that lay out a real
 * chapter run against Android's own `Path` and layout in `:render-android`'s
 * `HighlightBlockDrawingTest`.
 *
 * The read-along highlight used to be filled once per line, each line's
 * rectangle grown by `insetBy(dx: -2, dy: -1)`. Consecutive lines are flush,
 * so the two pads overlapped by 2 pt at every seam and a translucent colour was
 * composited over itself there — a dark band across the middle of every
 * wrapped sentence.
 */
class HighlightBlockTest {
    companion object {
        private fun rect(x: Double, y: Double, width: Double, height: Double) = PageRect(x, y, width, height)

        /**
         * A three-line sentence that starts part-way along one line and ends
         * part-way along another: a step on the left at the top, a step on the
         * right at the bottom.
         */
        val first = rect(120.0, 0.0, 200.0, 26.0)
        val middle = rect(0.0, 26.0, 320.0, 26.0)
        val last = rect(0.0, 52.0, 90.0, 26.0)
        val staircase = listOf(listOf(first), listOf(middle), listOf(last))

        /** A line carrying a tall inline run, with the next genuine line close under it. A(y 0–10) and B(y 0–20) are one line; C(y 12–22) is the next. */
        val inlineRun = listOf(
            listOf(rect(0.0, 0.0, 100.0, 10.0), rect(100.0, 0.0, 60.0, 20.0)),
            listOf(rect(0.0, 12.0, 200.0, 10.0)),
        )

        /** A 60 pt initial beside the first of three 20 pt lines. */
        val dropCapital = listOf(
            listOf(rect(0.0, 0.0, 40.0, 60.0), rect(44.0, 0.0, 200.0, 20.0)),
            listOf(rect(0.0, 20.0, 240.0, 20.0)),
            listOf(rect(0.0, 40.0, 120.0, 20.0)),
        )

        /** 18 pt reading size: 3 pt of padding at each end, 1 pt above and below, a 4 pt corner. */
        val style = HighlightBlock.Style.forFontSize(18.0)

        fun union(rects: List<PageRect>): PageRect = rects.drop(1).fold(rects.first()) { all, next -> all.union(next) }

        /**
         * The bounding box the block is obliged to have: the rows as padded at
         * their ends, with the block's vertical padding above the first and
         * below the last, and nowhere in between.
         */
        fun expectedBounds(lines: List<List<PageRect>>, style: HighlightBlock.Style): PageRect {
            val box = union(HighlightBlock.rows(lines, style.horizontal))
            return box.copy(y = box.y - style.vertical, height = box.height + style.vertical * 2)
        }

        fun assertClose(actual: PageRect?, expected: PageRect, what: String) {
            actual!!
            assertTrue("$what: minX ${actual.minX}", abs(actual.minX - expected.minX) < 0.01)
            assertTrue("$what: minY ${actual.minY}", abs(actual.minY - expected.minY) < 0.01)
            assertTrue("$what: maxX ${actual.maxX}", abs(actual.maxX - expected.maxX) < 0.01)
            assertTrue("$what: maxY ${actual.maxY}", abs(actual.maxY - expected.maxY) < 0.01)
        }
    }

    private fun PagePath.has(x: Double, y: Double) = PagePoint(x, y) in this

    // Style

    @Test
    fun `the reading size decides how much air the block leaves`() {
        val phone = HighlightBlock.Style.forFontSize(18.0)
        assertEquals(3.0, phone.horizontal, 0.0)
        assertEquals(1.0, phone.vertical, 0.0)
        assertEquals(4.0, phone.cornerRadius, 0.0)

        // The television reads at 40 pt, where a phone's 3 pt pad vanishes.
        val television = HighlightBlock.Style.forFontSize(40.0)
        assertEquals(6.0, television.horizontal, 0.0)
        assertEquals(2.0, television.vertical, 0.0)
        assertEquals(9.0, television.cornerRadius, 0.0)

        // A nonsense size must not put NaN into a path: that blanks the page.
        val broken = HighlightBlock.Style.forFontSize(Double.NaN)
        assertTrue(broken.horizontal.isFinite() && broken.vertical.isFinite() && broken.cornerRadius.isFinite())
        val negative = HighlightBlock.Style(horizontal = -4.0, vertical = Double.POSITIVE_INFINITY, cornerRadius = -1.0)
        assertTrue(negative.horizontal == 0.0 && negative.vertical == 0.0 && negative.cornerRadius == 0.0)
    }

    // One line

    /** Inside a rounded rectangle, analytically: the reference the Swift test asks CoreGraphics for. */
    private fun inRoundedRect(x: Double, y: Double, box: PageRect, radius: Double): Boolean {
        if (x < box.minX || x > box.maxX || y < box.minY || y > box.maxY) return false
        val cx = min(max(x, box.minX + radius), box.maxX - radius)
        val cy = min(max(y, box.minY + radius), box.maxY - radius)
        return (x - cx) * (x - cx) + (y - cy) * (y - cy) <= radius * radius
    }

    @Test
    fun `a single line is exactly the rounded rectangle it used to be`() {
        val line = rect(40.0, 10.0, 200.0, 26.0)
        val block = HighlightBlock.path(lines = listOf(listOf(line)), style = style)
        val padded = rect(40 - style.horizontal, 10 - style.vertical, 200 + style.horizontal * 2, 26 + style.vertical * 2)

        assertClose(block.boundingBox, padded, "single line bounds")
        assertEquals(1, block.subpathCount)

        // Compared by what they cover rather than by their curve segments,
        // and only at points that are unambiguously in or out of the reference
        // shape — three quarters of a point clear of its edge in every
        // direction.
        var checked = 0
        var x = 30.0
        while (x <= 250.0) {
            var y = 0.0
            while (y <= 46.0) {
                val inside = inRoundedRect(x, y, padded, style.cornerRadius)
                val unambiguous = listOf(-0.75, 0.75).all { dx ->
                    listOf(-0.75, 0.75).all { dy -> inRoundedRect(x + dx, y + dy, padded, style.cornerRadius) == inside }
                }
                if (unambiguous) {
                    assertEquals("disagreed at $x, $y", inside, block.has(x, y))
                    checked += 1
                }
                y += 0.5
            }
            x += 0.5
        }
        assertTrue("the grid should have covered the shape", checked > 10_000)
    }

    // The staircase

    @Test
    fun `a wrapped sentence is one subpath covering exactly the padded rows`() {
        val block = HighlightBlock.path(lines = staircase, style = style)
        assertEquals("a wrapped sentence is one shape, not three", 1, block.subpathCount)
        // 3 pt at each end of every row, 1 pt above the first and below the
        // last, and nothing added at the two seams.
        assertClose(block.boundingBox, rect(-3.0, -1.0, 326.0, 80.0), "staircase")
        assertClose(block.boundingBox, expectedBounds(staircase, style), "derived")
    }

    @Test
    fun `the seam and its neighbours are inside, the notches beside them are not`() {
        val block = HighlightBlock.path(lines = staircase, style = style)
        // x = 200 lies inside every one of the first two rows, so the seam
        // between them and the half point either side of it are all covered.
        for (y in listOf(25.5, 26.0, 26.5)) assertTrue("seam at y $y should be covered", block.has(200.0, y))
        // x = 50 lies inside the second and third rows, whose seam is at 52.
        for (y in listOf(51.5, 52.0, 52.5)) assertTrue("seam at y $y should be covered", block.has(50.0, y))
        // The paper the sentence does not reach stays paper.
        assertFalse("the first line starts at x 120", block.has(50.0, 12.0))
        assertFalse(block.has(116.0, 12.0))
        assertFalse("the last line ends at x 90", block.has(200.0, 65.0))
        assertFalse(block.has(100.0, 70.0))
    }

    // Rows and runs

    @Test
    fun `rows that do not meet become separate closed shapes`() {
        // Flush, but a short centred line under a short centred line.
        val apart = listOf(listOf(rect(0.0, 0.0, 40.0, 26.0)), listOf(rect(280.0, 26.0, 40.0, 26.0)))
        assertEquals(2, HighlightBlock.path(lines = apart, style = style).subpathCount)

        // A gap far too wide to be a line break — a mark that skips a heading.
        val distant = listOf(listOf(rect(0.0, 0.0, 200.0, 26.0)), listOf(rect(0.0, 100.0, 200.0, 26.0)))
        assertEquals(2, HighlightBlock.path(lines = distant, style = style).subpathCount)

        // Both halves of a split run get their own vertical padding, since
        // neither edge is a seam any more.
        assertClose(HighlightBlock.path(lines = distant, style = style).boundingBox, rect(-3.0, -1.0, 206.0, 128.0), "split run")

        // Flush and overlapping, but by less than the two corner radii the
        // join would need: 1 pt of shared text, 7 pt once both rows are padded,
        // against the 8 pt a 4 pt corner asks for on each side.
        val barely = listOf(listOf(rect(0.0, 0.0, 100.0, 26.0)), listOf(rect(99.0, 26.0, 100.0, 26.0)))
        assertEquals(2, HighlightBlock.path(lines = barely, style = style).subpathCount)
        assertEquals(2, HighlightBlock.runs(HighlightBlock.rows(barely, 3.0), minimumOverlap = 8.0).size)

        // Three points of shared text is nine once padded, and joins.
        val enough = listOf(listOf(rect(0.0, 0.0, 100.0, 26.0)), listOf(rect(97.0, 26.0, 100.0, 26.0)))
        assertEquals(1, HighlightBlock.path(lines = enough, style = style).subpathCount)
    }

    @Test
    fun `a hairline gap between lines is closed, so the seam is exactly shared`() {
        val gapped = HighlightBlock.rows(
            listOf(listOf(rect(0.0, 0.0, 200.0, 26.0)), listOf(rect(0.0, 26.4, 200.0, 26.0))), 0.0,
        )
        assertEquals(2, gapped.size)
        assertEquals(gapped[1].minY, gapped[0].maxY, 0.0)
        // Closed downwards: the row above grows to meet the one below, so no
        // glyph loses its cover.
        assertEquals(26.4, gapped[0].maxY, 0.0)

        // And the other direction, which is the one a real page hands over:
        // the row above is trimmed onto the row below rather than swallowing
        // it, so two lines stay two.
        val lapped = HighlightBlock.rows(
            listOf(listOf(rect(0.0, 0.0, 200.0, 26.0)), listOf(rect(0.0, 25.6, 200.0, 26.0))), 0.0,
        )
        assertEquals(2, lapped.size)
        assertEquals(lapped[1].minY, lapped[0].maxY, 0.0)
        assertEquals(25.6, lapped[0].maxY, 0.0)
    }

    @Test
    fun `the pieces the layout splits one line into come back as one row`() {
        val pieces = listOf(
            listOf(rect(0.0, 26.0, 100.0, 26.0), rect(100.0, 26.0, 120.0, 26.0)),
            listOf(rect(0.0, 0.0, 200.0, 26.0)),
        )
        val grouped = HighlightBlock.rows(pieces, 0.0)
        assertEquals("two lines, however many segments they arrived in", 2, grouped.size)
        assertEquals(0.0, grouped[0].minY, 0.0)
        assertEquals(220.0, grouped[1].width, 0.0)

        // The same rectangles with the grouping thrown away. The guess gets
        // this one right, which is why it survived as long as it did.
        val guessed = HighlightBlock.rows(HighlightBlock.inferredLines(pieces.flatten()), 0.0)
        assertEquals(2, guessed.size)
        assertEquals(220.0, guessed[1].width, 0.0)
    }

    // The grouping, and the guess behind it

    /**
     * A footnote marker or a word at a larger size makes one line arrive as a
     * short rectangle beside a tall one. The old merge compared each incoming
     * rectangle against the *grown union*, so A, B and C came back as one row
     * spanning y 0–22.
     */
    @Test
    fun `a tall run on one line does not swallow the line beneath it`() {
        val rows = HighlightBlock.rows(inlineRun, 0.0)
        assertEquals("a tall run and the line under it are two lines", 2, rows.size)
        assertEquals(0.0, rows[0].minY, 0.0)
        assertEquals("trimmed onto the line below, not merged with it", 12.0, rows[0].maxY, 0.0)
        assertEquals(22.0, rows[1].maxY, 0.0)
    }

    /** Two, because [HighlightBlock.inferredLines] measures each rectangle against the one that *opened* its line: C overlaps A by −2, not by 8. */
    @Test
    fun `the guess measures against the rectangle that opened the line`() {
        val guessed = HighlightBlock.inferredLines(inlineRun.flatten())
        assertEquals("the tall run swallowed the line below it again", 2, guessed.size)
        assertEquals("the short piece and the tall one are one line", 2, guessed[0].size)
        assertEquals(1, guessed[1].size)
        assertEquals(2, HighlightBlock.rows(guessed, 0.0).size)
    }

    /** The case no rule over rectangles alone can decide, which is why the grouping is a parameter. */
    @Test
    fun `a drop capital told apart from the lines it spans is three rows`() {
        val rows = HighlightBlock.rows(dropCapital, 0.0)
        assertEquals(3, rows.size)
        assertEquals("the initial is trimmed onto line two, not left 60 pt tall", 20.0, rows[0].maxY, 0.0)
        assertEquals("the last line ends where the sentence ends", 120.0, rows[2].maxX, 0.0)
        assertFalse("the mark reaches past the end of the last line", HighlightBlock.path(lines = dropCapital, style = style).has(220.0, 50.0))
    }

    /**
     * Deliberately the wrong answer: guessed, a drop capital is one line. The
     * assertion is pinned so the guess cannot quietly start claiming to be
     * able to tell.
     */
    @Test
    fun `guessed, a drop capital is one line — which is why the grouping is passed in`() {
        val guessed = HighlightBlock.inferredLines(dropCapital.flatten())
        assertEquals("if the guess can do this, the grouping is not needed", 1, guessed.size)
        assertTrue(
            "the guess stopped over-reaching here, so the grouped case above pins nothing",
            HighlightBlock.path(lines = guessed, style = style).has(220.0, 50.0),
        )
    }

    /** Two genuine lines at tight leading can overlap; the caller has said these are two lines, so they stay two. */
    @Test
    fun `two lines whose bounds overlap at tight leading stay two lines`() {
        val tight = listOf(listOf(rect(0.0, 0.0, 200.0, 22.0)), listOf(rect(0.0, 18.0, 140.0, 22.0)))
        val rows = HighlightBlock.rows(tight, 0.0)
        assertEquals(2, rows.size)
        assertEquals("the seam is where the second line starts", 18.0, rows[0].maxY, 0.0)
        assertEquals(18.0, rows[1].minY, 0.0)
        assertEquals(40.0, rows[1].maxY, 0.0)
    }

    /** Segments arrive in layout order, which is not reading order once a mark runs over a bidirectional line. */
    @Test
    fun `rectangles that arrive out of order are put back into page order`() {
        val jumbled = listOf(
            listOf(rect(120.0, 26.0, 100.0, 26.0), rect(0.0, 26.0, 120.0, 26.0)),
            listOf(rect(0.0, 0.0, 200.0, 26.0)),
        )
        val rows = HighlightBlock.rows(jumbled, 0.0)
        assertEquals(2, rows.size)
        assertEquals("the line above comes first however it arrived", 0.0, rows[0].minY, 0.0)
        assertEquals(0.0, rows[1].minX, 0.0)
        assertEquals("and the two pieces of one line are one row", 220.0, rows[1].maxX, 0.0)
    }

    /** The deprecated flat entry point is exactly the guess followed by the grouped call. */
    @Suppress("DEPRECATION")
    @Test
    fun `the deprecated flat call is the guess followed by the grouped one`() {
        val flat = inlineRun.flatten()
        val shim = HighlightBlock.path(lineRects = flat, style = style)
        val explicit = HighlightBlock.path(lines = HighlightBlock.inferredLines(flat), style = style)
        assertClose(shim.boundingBox, explicit.boundingBox!!, "flat shim")
        assertEquals(explicit.subpathCount, shim.subpathCount)
        assertFalse(shim.isEmpty)
    }

    @Test
    fun `lines of different heights still make one block`() {
        val mixed = listOf(listOf(rect(0.0, 0.0, 200.0, 34.0)), listOf(rect(0.0, 34.0, 200.0, 20.0)))
        val block = HighlightBlock.path(lines = mixed, style = style)
        assertEquals(1, block.subpathCount)
        assertClose(block.boundingBox, rect(-3.0, -1.0, 206.0, 56.0), "mixed heights")
        assertTrue("the seam between them is covered", block.has(100.0, 34.0))
    }

    // Straightening

    @Test
    fun `a step too small to round is flattened outwards, never inwards`() {
        val ragged = listOf(listOf(rect(0.0, 0.0, 200.0, 26.0)), listOf(rect(0.0, 26.0, 198.0, 26.0)))
        val straight = HighlightBlock.straightened(HighlightBlock.rows(ragged, 0.0), tolerance = 4.0)
        assertEquals(200.0, straight[0].maxX, 0.0)
        assertEquals("the shorter row is extended, not the longer one shortened", 200.0, straight[1].maxX, 0.0)

        val block = HighlightBlock.path(lines = ragged, style = style)
        assertClose(block.boundingBox, rect(-3.0, -1.0, 206.0, 54.0), "straightened")
        assertTrue("the second row now reaches as far as the first", block.has(202.0, 39.0))

        // A step worth rounding survives.
        val stepped = listOf(listOf(rect(0.0, 0.0, 200.0, 26.0)), listOf(rect(0.0, 26.0, 160.0, 26.0)))
        val kept = HighlightBlock.straightened(HighlightBlock.rows(stepped, 0.0), tolerance = 4.0)
        assertEquals(160.0, kept[1].maxX, 0.0)
    }

    @Test
    fun `a chain of tiny steps settles rather than leaving one behind`() {
        val chain = (0 until 5).map { listOf(rect(0.0, it * 26.0, 200.0 + it * 2, 26.0)) }
        val straight = HighlightBlock.straightened(HighlightBlock.rows(chain, 0.0), tolerance = 4.0)
        assertTrue(straight.all { it.maxX == 208.0 })
    }

    // Nothing to draw

    @Test
    fun `nothing, or nonsense, draws nothing at all`() {
        assertTrue(HighlightBlock.path(lines = emptyList(), style = style).isEmpty)
        assertTrue(HighlightBlock.path(lines = listOf(emptyList()), style = style).isEmpty)
        assertTrue(HighlightBlock.path(lines = listOf(listOf(rect(0.0, 0.0, 0.0, 0.0))), style = style).isEmpty)
        // CoreGraphics' null and infinite rectangles.
        val nullRect = rect(Double.POSITIVE_INFINITY, Double.POSITIVE_INFINITY, 0.0, 0.0)
        val infinite = rect(-Double.MAX_VALUE / 2, -Double.MAX_VALUE / 2, Double.MAX_VALUE, Double.MAX_VALUE)
        assertTrue(HighlightBlock.path(lines = listOf(listOf(nullRect)), style = style).isEmpty)
        assertTrue(HighlightBlock.path(lines = listOf(listOf(infinite)), style = style).isEmpty)
        assertTrue(HighlightBlock.path(lines = listOf(listOf(rect(Double.NaN, 0.0, 10.0, 10.0))), style = style).isEmpty)
        assertTrue(HighlightBlock.path(lines = listOf(listOf(rect(0.0, 0.0, 100.0, 0.0))), style = style).isEmpty)
        assertTrue(HighlightBlock.rows(emptyList(), 3.0).isEmpty())
        assertTrue(HighlightBlock.inferredLines(emptyList()).isEmpty())
        assertTrue(HighlightBlock.runs(emptyList(), minimumOverlap = 8.0).isEmpty())
        assertTrue(HighlightBlock.outline(emptyList()).isEmpty())

        // One good row among the rubbish still draws — and a line made
        // entirely of rubbish is dropped rather than left as an empty row.
        val mixed = listOf(listOf(nullRect), listOf(rect(0.0, 0.0, 100.0, 26.0)), listOf(rect(5.0, 5.0, 0.0, 0.0)))
        assertFalse(HighlightBlock.path(lines = mixed, style = style).isEmpty)
        assertEquals(1, HighlightBlock.rows(mixed, 3.0).size)
    }

    @Test
    fun `a right-to-left block is the same walk, mirrored`() {
        // The last line of an RTL paragraph ends at the *left*, so the step is
        // on the other side. Nothing in the outline knows about direction.
        val rtl = listOf(listOf(rect(0.0, 0.0, 320.0, 26.0)), listOf(rect(230.0, 26.0, 90.0, 26.0)))
        val block = HighlightBlock.path(lines = rtl, style = style)
        assertEquals(1, block.subpathCount)
        assertClose(block.boundingBox, rect(-3.0, -1.0, 326.0, 54.0), "RTL")
        assertTrue("the seam under the short line is covered", block.has(280.0, 26.0))
        assertFalse("the paper it does not reach stays paper", block.has(100.0, 40.0))
    }

    /** The rounding is real tangent arcs: every corner of a single line is a quarter circle of the corner radius. */
    @Test
    fun `the corners are quarter circles of the corner radius`() {
        val block = HighlightBlock.path(lines = listOf(listOf(rect(0.0, 0.0, 100.0, 20.0))), style = style)
        val arcs = block.commands.filterIsInstance<PathCommand.Arc>()
        assertEquals(4, arcs.size)
        for (arc in arcs) {
            assertEquals(style.cornerRadius, arc.radius, 1e-9)
            assertEquals(90.0, abs(arc.sweepAngle), 1e-9)
        }
        // Clockwise on a page whose y grows downwards: every sweep positive.
        assertTrue(arcs.all { it.sweepAngle > 0 })
    }
}
