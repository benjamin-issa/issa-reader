package com.benjaminissa.issareader.render

import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

/**
 * One connected shape for a marked passage, in place of one lozenge per line.
 *
 * The Swift reader used to fill a rounded rectangle for every line fragment
 * TextKit reported, each grown by `insetBy(dx: -2, dy: -1)` and painted in a
 * translucent colour. Consecutive lines' rectangles are flush, so the two pads
 * met and every seam was covered twice: 0.22 alpha composited over 0.22 alpha
 * reads as 0.39, which is the dark band that ran across the middle of every
 * wrapped sentence. The separate lozenges also read as a stack of strips
 * rather than one marked passage.
 *
 * The cure is to paint once. This turns the line rectangles into a single
 * rectilinear outline whose seams are *shared* edges rather than overlapping
 * pads, rounds its corners, and hands back one [PagePath] for the caller to
 * fill in one go — so the alpha is uniform by construction rather than by
 * luck.
 *
 * Deliberately pure geometry: no state, no view. The phone, the tablet and the
 * television all mark a sentence with the same shape, and every step below is
 * testable on its own.
 */
object HighlightBlock {
    /** How much air the block puts around the glyphs, and how round it is. */
    class Style(horizontal: Double, vertical: Double, cornerRadius: Double) {
        /**
         * Added to each end of every row, so a mark starts a little before the
         * first glyph and ends a little after the last.
         */
        val horizontal: Double = sane(horizontal)

        /**
         * Added above the first row and below the last — and only there.
         * Padding a seam is precisely what produced the double-composited
         * band, so the seams between rows stay exactly shared.
         */
        val vertical: Double = sane(vertical)

        val cornerRadius: Double = sane(cornerRadius)

        override fun equals(other: Any?): Boolean = other is Style && horizontal == other.horizontal &&
            vertical == other.vertical && cornerRadius == other.cornerRadius

        override fun hashCode(): Int = listOf(horizontal, vertical, cornerRadius).hashCode()

        override fun toString(): String = "Style(horizontal=$horizontal, vertical=$vertical, cornerRadius=$cornerRadius)"

        companion object {
            /**
             * The proportions the reader uses, derived from the reading size.
             *
             * Derived rather than fixed because the same block is drawn on a
             * phone at 18 pt and on a television at 40 pt, and a 3 pt pad that
             * looks generous around small type all but disappears around large
             * type. 18 pt gives 3 / 1 / 4; 40 pt gives 6 / 2 / 9.
             */
            fun forFontSize(fontSize: Double): Style {
                val size = if (fontSize.isFinite()) max(1.0, fontSize) else 18.0
                return Style(
                    horizontal = max(1.0, rounded(size * 0.15)),
                    vertical = max(1.0, rounded(size * 0.05)),
                    cornerRadius = max(1.0, rounded(size * 0.22)),
                )
            }

            /** Swift's `rounded()`: halves away from zero. */
            private fun rounded(value: Double): Double = if (value >= 0) Math.floor(value + 0.5) else -Math.floor(-value + 0.5)

            /**
             * A non-finite or negative measurement would put NaN into the path
             * and silently blank the whole page, so it is refused here instead.
             */
            private fun sane(value: Double): Double = if (value.isFinite()) max(0.0, value) else 0.0
        }
    }

    // Building the path

    /**
     * The outline of a marked passage, given its rectangles grouped by line.
     *
     * Grouped by the caller because only the caller can know. The layout
     * splits a line wherever the attributes or the direction change, so one
     * line arrives as several rectangles — and two *genuine* lines at
     * `LineSpacing.TIGHT`, or a line carrying a drop capital, produce exactly
     * the same overlapping geometry. Inferring it here merged a narrated
     * sentence with the line under it and painted the mark across words the
     * sentence does not cover.
     *
     * The nested list *is* the identity, rather than a rectangle-and-line-number
     * pair: a pair with a defaulted line number can be filled in wrongly and
     * still type-check, and the wrong answer it then gives is the very bug this
     * signature exists to make unrepresentable.
     *
     * Rows that cannot be joined without overlapping — a short centred line, an
     * RTL opening line, a mark that jumps a paragraph — become separate closed
     * subpaths. Disjoint subpaths never cover the same pixel, so one fill still
     * gives one alpha.
     */
    fun path(lines: List<List<PageRect>>, style: Style): PagePath {
        val rows = rows(lines, style.horizontal)
        if (rows.isEmpty()) return PagePath.EMPTY
        val builder = PagePathBuilder()

        val runs = runs(rows, minimumOverlap = style.cornerRadius * 2)
        for ((index, run) in runs.withIndex()) {
            val top = run.firstOrNull() ?: continue
            val bottom = run.last()
            // Vertical padding belongs to the outside of the shape, never to a
            // seam. A run that sits flush against its neighbour is a seam even
            // though the two are drawn separately, so it goes unpadded there
            // too — otherwise the very overlap this file exists to remove
            // reappears in the corner where the two runs meet.
            val padsTop = index == 0 || runs[index - 1].lastOrNull()?.let { it.maxY < top.minY - EPSILON } ?: true
            val padsBottom = index == runs.size - 1 ||
                runs[index + 1].firstOrNull()?.let { it.minY > bottom.maxY + EPSILON } ?: true

            val shaped = straightened(run, tolerance = style.cornerRadius).toMutableList()
            if (padsTop) {
                val first = shaped[0]
                shaped[0] = first.copy(y = first.y - style.vertical, height = first.height + style.vertical)
            }
            if (padsBottom) {
                val last = shaped[shaped.size - 1]
                shaped[shaped.size - 1] = last.copy(height = last.height + style.vertical)
            }
            addRounded(outline(shaped), style.cornerRadius, builder)
        }
        return builder.build()
    }

    /**
     * The outline of a marked passage from a flat list of rectangles, with the
     * grouping guessed by [inferredLines].
     *
     * Kept, rather than erased, because the guess is what a caller holding no
     * line identity is left with, and a named wrong-but-documented path is
     * easier to reason about than an inlined one. It is deprecated because the
     * guess is provably unable to answer: a drop capital and three lines are
     * the same geometry.
     */
    @JvmName("pathFromFlatRects")
    @Deprecated(
        "Group the rectangles by line and call path(lines, style). The flat guess merges a tall inline run " +
            "with the line below it, and cannot tell a drop capital from the three lines it spans.",
    )
    fun path(lineRects: List<PageRect>, style: Style): PagePath = path(inferredLines(lineRects), style)

    // Rows

    /**
     * Tolerance for "the same coordinate". Page geometry arrives from the
     * layout with fractional parts, so exact equality is not on offer.
     */
    const val EPSILON = 1e-6

    /**
     * One rectangle per row of text, padded at the ends, with every seam
     * between consecutive rows made exactly shared.
     *
     * Two things happen that the grouped segments do not do for us. The lines
     * arrive in layout order, which is not always page order once a mark runs
     * over a bidirectional line, so the rows are sorted here — the walk that
     * closes the seams below reads them top to bottom. And consecutive rows are
     * usually flush but occasionally leave a hairline gap or a hairline
     * overlap — Alice's justified page reports neighbours 1e-14 apart — either
     * of which would show through a translucent fill; closing it by moving one
     * row's bottom onto the next row's top makes the seam an edge the outline
     * can simply walk along.
     *
     * A line that overlaps the one below it by more than a hairline is trimmed
     * rather than merged: the caller has said these are two lines, and the
     * answer to overlapping bounds at `LineSpacing.TIGHT` is a shared seam, not
     * one row swallowing the other.
     */
    fun rows(lines: List<List<PageRect>>, horizontalPadding: Double): List<PageRect> {
        // One row per line, so the pieces' own order inside a line cannot
        // matter; a line with nothing usable on it is dropped rather than left
        // as an empty row for the seam walk to trip over.
        val merged = ArrayList<PageRect>()
        for (line in lines) {
            val usable = line.map { it.standardized }.filter(::isUsable)
            val first = usable.firstOrNull() ?: continue
            merged.add(usable.drop(1).fold(first) { all, next -> all.union(next) })
        }
        merged.sortWith(compareBy<PageRect>({ it.minY }, { it.minX }))

        val padded = merged.map {
            PageRect(it.minX - horizontalPadding, it.minY, it.width + horizontalPadding * 2, it.height)
        }.toMutableList()

        for (index in 0 until padded.size - 1) {
            val gap = padded[index + 1].minY - padded[index].maxY
            val shorter = min(padded[index].height, padded[index + 1].height)
            // A gap wider than this is a real break in the mark — a paragraph
            // skipped, a heading between two lines — and stays a break.
            if (!(gap < 0 || gap <= shorter * 0.4)) continue
            if (!(padded[index + 1].minY > padded[index].minY)) continue
            padded[index] = padded[index].copy(height = padded[index + 1].minY - padded[index].minY)
        }
        return padded
    }

    /**
     * The grouping a caller holding no line identity is reduced to guessing.
     *
     * Pieces of one line share a baseline, so they overlap vertically by more
     * than half the shorter one's height; two lines set flush do not overlap at
     * all. Each incoming rectangle is measured against **the rectangle that
     * opened its line**, never against the growing union: comparing against the
     * union let a tall inline run raise the accumulator's `maxY`, and the next
     * genuine line then cleared the threshold and was swallowed. Three
     * rectangles A(y 0–10), B(y 0–20), C(y 12–22) came back as one row spanning
     * y 0–22 — the mark painted over a line the sentence never reached.
     * Measured against A, C overlaps by −2 and opens a line of its own.
     *
     * It is still a guess, and it is still wrong for a drop capital: a 60 pt
     * initial beside a 20 pt line, over three 20 pt lines, is the same geometry
     * as one tall line, and no rule over rectangles alone can tell them apart.
     * That is what [path] takes the grouping for.
     */
    fun inferredLines(rects: List<PageRect>): List<List<PageRect>> {
        val usable = rects.map { it.standardized }.filter(::isUsable)
            .sortedWith(compareBy<PageRect>({ it.minY }, { it.minX }))
        if (usable.isEmpty()) return emptyList()

        val lines = ArrayList<MutableList<PageRect>>()
        var opener: PageRect? = null
        for (rect in usable) {
            if (opener != null) {
                val overlap = min(opener.maxY, rect.maxY) - max(opener.minY, rect.minY)
                if (overlap > min(opener.height, rect.height) / 2) {
                    lines[lines.size - 1].add(rect)
                    continue
                }
            }
            lines.add(mutableListOf(rect))
            opener = rect
        }
        return lines
    }

    /**
     * A rectangle with four finite corners and some area to it. A NaN would
     * propagate through the whole outline; an empty rectangle would leave a
     * zero-width spur on it.
     */
    private fun isUsable(rect: PageRect): Boolean =
        rect.x.isFinite() && rect.y.isFinite() && rect.width.isFinite() && rect.height.isFinite() &&
            rect.width > 0 && rect.height > 0 && abs(rect.x) < HUGE && abs(rect.y) < HUGE &&
            rect.width < HUGE && rect.height < HUGE

    /** Past this a rectangle is CoreGraphics' "infinite" one, not a line of text. */
    private const val HUGE = 1e30

    // Runs

    /**
     * Groups rows into the connected shapes they can honestly make.
     *
     * Two rows join only if they are flush *and* share enough width for the
     * corners to be rounded without the two roundings meeting in mid-air. A
     * mark that jumps from the right edge to the left — the first line of an
     * RTL paragraph, a short centred line — would otherwise be joined by a
     * sliver of shape crossing empty paper.
     *
     * @param minimumOverlap how much width consecutive rows must share; the
     *   caller passes twice the corner radius.
     */
    fun runs(rows: List<PageRect>, minimumOverlap: Double): List<List<PageRect>> {
        val first = rows.firstOrNull() ?: return emptyList()
        val runs = arrayListOf(mutableListOf(first))
        for (row in rows.drop(1)) {
            val previous = runs[runs.size - 1].last()
            val flush = abs(previous.maxY - row.minY) <= EPSILON
            val overlap = min(previous.maxX, row.maxX) - max(previous.minX, row.minX)
            if (flush && overlap > 0 && overlap >= minimumOverlap) {
                runs[runs.size - 1].add(row)
            } else {
                runs.add(mutableListOf(row))
            }
        }
        return runs
    }

    // Straightening

    /**
     * Flattens steps between rows that are too small to round.
     *
     * A justified paragraph's right margin, or hanging punctuation, leaves
     * steps of a point or two. Rounding one of those produces a visible nick
     * rather than a corner. Rows are always *extended* to meet, never shrunk —
     * a shrink would leave a glyph sticking out of its own highlight.
     */
    fun straightened(rows: List<PageRect>, tolerance: Double): List<PageRect> {
        if (rows.size <= 1 || !(tolerance > 0)) return rows
        val result = rows.toMutableList()
        // Extending is monotonic — left edges only move left, right edges only
        // move right — so this settles; the counter is a belt-and-braces bound.
        var passes = 0
        var changed = true
        while (changed && passes <= result.size) {
            changed = false
            passes += 1
            for (index in 0 until result.size - 1) {
                val left = min(result[index].minX, result[index + 1].minX)
                val leftStep = abs(result[index].minX - result[index + 1].minX)
                if (leftStep > EPSILON && leftStep < tolerance) {
                    result[index] = extendedLeft(result[index], left)
                    result[index + 1] = extendedLeft(result[index + 1], left)
                    changed = true
                }
                val right = max(result[index].maxX, result[index + 1].maxX)
                val rightStep = abs(result[index].maxX - result[index + 1].maxX)
                if (rightStep > EPSILON && rightStep < tolerance) {
                    result[index] = extendedRight(result[index], right)
                    result[index + 1] = extendedRight(result[index + 1], right)
                    changed = true
                }
            }
        }
        return result
    }

    private fun extendedLeft(rect: PageRect, minX: Double): PageRect =
        PageRect(minX, rect.minY, rect.maxX - minX, rect.height)

    private fun extendedRight(rect: PageRect, maxX: Double): PageRect =
        PageRect(rect.minX, rect.minY, maxX - rect.minX, rect.height)

    // Outline

    /**
     * A clockwise rectilinear polygon around one run of flush rows.
     *
     * Clockwise in the page's own coordinates, which run downwards: along the
     * top of the first row, down the right-hand edges stepping in or out at
     * each seam, along the bottom of the last row, then back up the left-hand
     * edges. Nothing here knows about writing direction — an RTL block is the
     * same walk with the steps the other way about, so it mirrors itself.
     *
     * Collinear vertices are dropped, so a run of equal-width rows comes back
     * as a plain rectangle rather than a rectangle with invisible corners on
     * its sides, each of which would otherwise be rounded into a dent.
     */
    fun outline(rows: List<PageRect>): List<PagePoint> {
        val first = rows.firstOrNull() ?: return emptyList()
        val last = rows.last()
        val points = arrayListOf(PagePoint(first.minX, first.minY), PagePoint(first.maxX, first.minY))
        for (index in 1 until rows.size) {
            val seam = rows[index].minY
            points.add(PagePoint(rows[index - 1].maxX, seam))
            points.add(PagePoint(rows[index].maxX, seam))
        }
        points.add(PagePoint(last.maxX, last.maxY))
        points.add(PagePoint(last.minX, last.maxY))
        for (index in (1 until rows.size).reversed()) {
            val seam = rows[index].minY
            points.add(PagePoint(rows[index].minX, seam))
            points.add(PagePoint(rows[index - 1].minX, seam))
        }
        return withoutCollinearPoints(points)
    }

    /** Drops vertices that lie on the line between their neighbours, and any vertex that repeats the next one. */
    fun withoutCollinearPoints(points: List<PagePoint>): List<PagePoint> {
        val result = points.toMutableList()
        var index = 0
        while (result.size > 3 && index < result.size) {
            val previous = result[(index - 1 + result.size) % result.size]
            val current = result[index]
            val next = result[(index + 1) % result.size]
            val cross = (current.x - previous.x) * (next.y - current.y) - (current.y - previous.y) * (next.x - current.x)
            val repeats = abs(current.x - next.x) <= EPSILON && abs(current.y - next.y) <= EPSILON
            if (repeats || abs(cross) <= EPSILON) {
                result.removeAt(index)
                // Removing a vertex can make the one before it collinear.
                index = max(0, index - 1)
            } else {
                index += 1
            }
        }
        return result
    }

    // Rounding

    /**
     * Adds one closed, corner-rounded subpath through the given polygon.
     *
     * Built from tangent arcs (CoreGraphics' `addArc(tangent1End:tangent2End:
     * radius:)`, worked out by [PagePathBuilder.arcThroughCorner]), which round
     * convex corners and fillet concave ones — the notch where a long line
     * meets a short one wants a fillet, not a spike. The radius at each corner
     * is clamped to half the shorter of its two edges, so no two roundings can
     * reach past one another however narrow the step; below half a point
     * there is nothing to see, and a straight line is drawn instead.
     */
    internal fun addRounded(points: List<PagePoint>, radius: Double, path: PagePathBuilder) {
        if (points.size < 3) return
        val count = points.size
        // Starting mid-edge guarantees the first arc has half an edge of
        // run-up, exactly as every later arc does.
        val start = midpoint(points[count - 1], points[0])
        path.moveTo(start.x, start.y)
        for (index in 0 until count) {
            val corner = points[index]
            val previous = points[(index - 1 + count) % count]
            val next = points[(index + 1) % count]
            val limit = min(distance(previous, corner), distance(corner, next)) / 2
            val clamped = min(radius, limit)
            if (clamped < 0.5) {
                path.lineTo(corner.x, corner.y)
            } else {
                path.arcThroughCorner(corner.x, corner.y, next.x, next.y, clamped)
            }
        }
        path.close()
    }

    private fun midpoint(a: PagePoint, b: PagePoint) = PagePoint((a.x + b.x) / 2, (a.y + b.y) / 2)

    private fun distance(a: PagePoint, b: PagePoint): Double = hypot(a.x - b.x, a.y - b.y)
}
