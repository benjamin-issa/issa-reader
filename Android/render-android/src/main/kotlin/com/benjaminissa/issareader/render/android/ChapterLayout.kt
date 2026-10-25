package com.benjaminissa.issareader.render.android

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.text.Layout
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.StaticLayout
import android.text.TextDirectionHeuristics
import android.text.TextPaint
import android.text.style.LeadingMarginSpan
import com.benjaminissa.issareader.render.HighlightBlock
import com.benjaminissa.issareader.render.LineBox
import com.benjaminissa.issareader.render.PageRect
import com.benjaminissa.issareader.render.Paginator
import com.benjaminissa.issareader.render.ParagraphAttributes
import com.benjaminissa.issareader.render.ReaderStyle
import com.benjaminissa.issareader.render.RenderedPage
import com.benjaminissa.issareader.render.Rgba
import com.benjaminissa.issareader.render.StyledChapter
import com.benjaminissa.issareader.render.TextAlignment
import com.benjaminissa.issareader.render.TextRange
import java.text.Bidi
import java.util.Locale
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Lays out a chapter once and slices it into pages: the Swift client's
 * `ChapterLayout`, on Android text layout.
 *
 * TextKit 2 gives the Swift reader one layout of the whole chapter in an
 * unbounded column; here each paragraph is one `StaticLayout`, stacked with its
 * paragraph spacing, and the stack's lines are what [Paginator.computePages]
 * cuts into pages. Either way the chapter is laid out exactly once, so turning
 * a page is a translation of already-computed geometry, and the rectangles
 * needed to highlight a narrated sentence are available without laying
 * anything out again.
 *
 * Everything is in pixels with the column's top-left corner as the origin; the
 * parser's lengths are points and are multiplied by [scale] on the way in.
 * Page counts will not match TextKit's — the faces are the same files, but
 * the line breaker and its metrics are not — and nothing depends on them: a
 * position is a character offset, and the page it lands on is recomputed.
 *
 * Main-thread only, as the Swift one is `@MainActor`; a plate decodes on the
 * thread that first draws it.
 *
 * @param chapter what [com.benjaminissa.issareader.render.ChapterParser] built.
 * @param style the style it was parsed under: the reading size, and the face.
 * @param scale pixels per point.
 * @param locale the book's language, for hyphenation; the device's when null.
 */
class ChapterLayout(
    chapter: StyledChapter,
    val style: ReaderStyle,
    fonts: ReaderFonts,
    val scale: Double = 1.0,
    locale: Locale? = null,
) {
    /**
     * The chapter as it is laid out now. A `var` because of [reindent], the
     * one thing that changes it — a first-line indent, never a character.
     */
    var chapter: StyledChapter = chapter
        private set

    /** The rendered string, which every offset here is into. */
    val text: String get() = chapter.text
    val fragmentRanges: Map<String, TextRange> get() = chapter.fragmentRanges

    var pages: List<RenderedPage> = emptyList()
        private set

    /** The page size last laid out for, in pixels. */
    var pageWidth: Double = 0.0
        private set
    var pageHeight: Double = 0.0
        private set

    private val spans = SpanBuilder(fonts, style, scale)
    private val spanned: SpannableStringBuilder = spans.build(chapter)
    private val plateSpans: List<PlateSpan> = spanned.getSpans(0, spanned.length, PlateSpan::class.java).toList()

    /**
     * The one paint every paragraph is laid out and drawn with. Its colour is
     * the page's ink; nothing else in the chapter carries one.
     */
    private val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).also { paint ->
        paint.color = style.theme.text.argb
        paint.textSize = (style.fontSize * scale).toFloat()
        paint.typeface = fonts.bodyFace(style, italic = false, bold = false, scale = 1.0).typeface
        if (locale != null) paint.textLocale = locale
    }

    /** The ink the chapter is drawn in, as `0xAARRGGBB`. */
    val ink: Int get() = paint.color

    private class Paragraph(
        /** First character. */
        val start: Int,
        /** One past the last character before its separator. */
        val contentEnd: Int,
        /** One past the separator, or [contentEnd] for the last paragraph. */
        val end: Int,
    ) {
        var layout: StaticLayout? = null
        var frameTop = 0.0
        var contentTop = 0.0
        var height = 0.0
        var frameBottom = 0.0

        /** The paragraph's directional runs, computed once per layout. */
        var bidi: Bidi? = null
    }

    private val paragraphs: List<Paragraph> = splitParagraphs(chapter.text)
    private var lines: List<LineBox> = emptyList()

    /**
     * Re-flows for a new page size. Cheap enough to call on rotation, and the
     * only operation that costs a full layout pass.
     */
    fun layout(width: Double, height: Double) {
        if (!(width > 0) || !(height > 0)) return
        pageWidth = width
        pageHeight = height
        reindent(width / scale)
        for (plate in plateSpans) plate.availableWidthPx = width
        val widthPx = max(1, width.toInt())
        var y = 0.0
        for (paragraph in paragraphs) {
            val attributes = paragraphAttributes(paragraph.start)
            paragraph.frameTop = y
            paragraph.contentTop = y + attributes.paragraphSpacingBefore * scale
            if (paragraph.contentEnd > paragraph.start) {
                val built = build(paragraph, attributes, widthPx)
                paragraph.layout = built
                paragraph.height = built.height.toDouble()
                paragraph.bidi = null
            } else {
                paragraph.layout = null
                paragraph.height = emptyLineHeight(paragraph.start, attributes)
            }
            paragraph.frameBottom = paragraph.contentTop + paragraph.height + attributes.paragraphSpacing * scale
            y = paragraph.frameBottom
        }
        lines = lineBoxes()
        pages = Paginator.computePages(lines, height, text.length)
    }

    /** The paragraph style a paragraph takes, which is its first character's, as TextKit has it. */
    private fun paragraphAttributes(start: Int): ParagraphAttributes =
        chapter.runAt(start)?.style?.paragraph ?: defaultParagraph

    private val defaultParagraph = ParagraphAttributes(
        alignment = TextAlignment.NATURAL, lineHeightMultiple = 0.0, hyphenationFactor = 0.0,
        paragraphSpacing = 0.0, headIndent = 0.0, firstLineHeadIndent = 0.0,
    )

    private fun build(paragraph: Paragraph, attributes: ParagraphAttributes, width: Int): StaticLayout {
        val content = SpannableStringBuilder(spanned, paragraph.start, paragraph.contentEnd)
        val first = (attributes.firstLineHeadIndent * scale).roundToInt()
        val rest = (attributes.headIndent * scale).roundToInt()
        if (first != 0 || rest != 0) {
            content.setSpan(LeadingMarginSpan.Standard(first, rest), 0, content.length, Spanned.SPAN_INCLUSIVE_INCLUSIVE)
        }
        // A plate's line is the plate's own height. Multiplying it as text is
        // multiplied would make a plate the page bound fitted exactly taller
        // than the page, and it would be clipped.
        val isPlate = chapter.runAt(paragraph.start)?.plateIndex != null
        if (!isPlate) {
            content.setSpan(LineHeightMultipleSpan(attributes.lineHeightMultiple), 0, content.length, Spanned.SPAN_INCLUSIVE_INCLUSIVE)
        }
        val rtl = TextDirectionHeuristics.FIRSTSTRONG_LTR.isRtl(content, 0, content.length)
        val alignment = when (attributes.alignment) {
            TextAlignment.NATURAL, TextAlignment.JUSTIFIED -> Layout.Alignment.ALIGN_NORMAL
            TextAlignment.CENTER -> Layout.Alignment.ALIGN_CENTER
            TextAlignment.LEFT -> if (rtl) Layout.Alignment.ALIGN_OPPOSITE else Layout.Alignment.ALIGN_NORMAL
            TextAlignment.RIGHT -> if (rtl) Layout.Alignment.ALIGN_NORMAL else Layout.Alignment.ALIGN_OPPOSITE
        }
        val justified = attributes.alignment == TextAlignment.JUSTIFIED
        return StaticLayout.Builder.obtain(content, 0, content.length, paint, width)
            .setAlignment(alignment)
            .setTextDirection(TextDirectionHeuristics.FIRSTSTRONG_LTR)
            .setIncludePad(false)
            .setLineSpacing(0f, 1f)
            .setBreakStrategy(Layout.BREAK_STRATEGY_HIGH_QUALITY)
            // Hyphenation matters far more in a justified column; without it,
            // justified text opens rivers of whitespace.
            .setHyphenationFrequency(
                if (justified || attributes.hyphenationFactor > 0) Layout.HYPHENATION_FREQUENCY_FULL else Layout.HYPHENATION_FREQUENCY_NONE,
            )
            .setJustificationMode(if (justified) Layout.JUSTIFICATION_MODE_INTER_WORD else Layout.JUSTIFICATION_MODE_NONE)
            .setUseLineSpacingFromFallbacks(true)
            .build()
    }

    /** An empty paragraph is one empty line of its own face, as TextKit lays it out. */
    private fun emptyLineHeight(index: Int, attributes: ParagraphAttributes): Double {
        val run = chapter.runAt(index)?.style
        val measure = TextPaint(paint)
        if (run != null) {
            measure.typeface = spans.face(run).typeface
            measure.textSize = spans.sizePx(run)
        }
        val metrics = measure.fontMetricsInt
        val natural = metrics.descent - metrics.ascent
        val multiple = attributes.lineHeightMultiple
        return if (multiple > 0) (natural * multiple).roundToInt().toDouble() else natural.toDouble()
    }

    private fun lineBoxes(): List<LineBox> {
        val boxes = ArrayList<LineBox>()
        for (paragraph in paragraphs) {
            val layout = paragraph.layout
            if (layout == null) {
                boxes.add(LineBox(paragraph.contentTop, paragraph.contentTop + paragraph.height, paragraph.start, paragraph.end))
                continue
            }
            for (line in 0 until layout.lineCount) {
                val last = line == layout.lineCount - 1
                boxes.add(
                    LineBox(
                        top = paragraph.contentTop + layout.getLineTop(line),
                        bottom = paragraph.contentTop + layout.getLineBottom(line),
                        start = paragraph.start + layout.getLineStart(line),
                        // A paragraph's last line holds its separator, as a
                        // TextKit line fragment does, so the lines tile the text.
                        end = if (last) paragraph.end else paragraph.start + layout.getLineEnd(line),
                    ),
                )
            }
        }
        return boxes
    }

    // Colour and indents

    /**
     * Repaints the chapter in a new ink, keeping the pagination it has.
     *
     * A theme change alters the ink and no metric: the same glyphs sit in the
     * same rectangles on sepia paper as on white. Treating it as a typography
     * change meant an inflate, an XML parse and a decode of every plate in the
     * chapter, on the main thread, every time the reader switched theme — or
     * every time the system slid into dark theme on its own, which happens at
     * sunset while someone is reading.
     *
     * [pages] is deliberately left alone: recomputing it would produce the same
     * boundaries from the same line metrics, and keeping it means the reader
     * does not move. Only the paint changes; the layouts draw with it.
     */
    fun recolour(colour: Rgba) {
        paint.color = colour.argb
    }

    /** The column width the first-line indents were last resolved against; `null` until the first layout. */
    private var indentedWidth: Double? = null

    /**
     * Resolves the book's first-line indents again for a new column width, in
     * points; see [StyledChapter.reindented]. Leaves the chapter alone when
     * nothing moves, which is every layout of a chapter at the width it was
     * parsed for.
     */
    private fun reindent(columnWidth: Double) {
        if (columnWidth == indentedWidth) return
        indentedWidth = columnWidth
        chapter = chapter.reindented(columnWidth)
    }

    // Highlighting

    /**
     * Rectangles covering a media-overlay fragment, grouped by the line of type
     * each one sits on, in the coordinate space of the page that contains it.
     *
     * This is the whole point of owning the layout: highlighting the narrated
     * sentence is a rectangle lookup against geometry that already exists, so
     * it costs nothing per audio tick and cannot fall behind the audio.
     *
     * Grouped rather than flat because the grouping is knowable *here* and
     * nowhere downstream: [HighlightBlock] sees rectangles alone, and
     * rectangles alone cannot tell a tall run on one line from two lines. A
     * line splits into more than one rectangle where its writing direction
     * changes, as TextKit splits it.
     */
    fun highlightLines(fragmentId: String, page: RenderedPage): List<List<PageRect>> {
        val range = fragmentRanges[fragmentId] ?: return emptyList()
        return segmentLines(range, page)
    }

    /**
     * The same rectangles with the line grouping thrown away, for callers that
     * want geometry rather than a shape to fill — the tap-to-seek hit tests,
     * and the tests that measure where a sentence landed.
     */
    fun highlightRects(fragmentId: String, page: RenderedPage): List<PageRect> = highlightLines(fragmentId, page).flatten()

    /** Rectangles covering an arbitrary character range on a page, grouped by line, for a selection or a stored highlight. */
    fun lines(range: TextRange, page: RenderedPage): List<List<PageRect>> =
        if (range.length <= 0) emptyList() else segmentLines(range, page)

    /** The same rectangles, flattened — see [highlightRects]. */
    fun rects(range: TextRange, page: RenderedPage): List<PageRect> = lines(range, page).flatten()

    /** The block's proportions at this chapter's reading size, in pixels. */
    val highlightStyle: HighlightBlock.Style
        get() {
            val points = HighlightBlock.Style.forFontSize(style.fontSize)
            return HighlightBlock.Style(points.horizontal * scale, points.vertical * scale, points.cornerRadius * scale)
        }

    /**
     * Text segments on one page, one group per line of type.
     *
     * The page bounds are checked before a line is taken, and bounded by
     * `contentBottom`, not the page's height: the page's drawn content stops at
     * its last whole line, and a fragment continuing onto the next page would
     * otherwise paint a bar in the blank band below it — the same migration
     * [draw] and [paintedCharacterRange] already made.
     */
    private fun segmentLines(range: TextRange, page: RenderedPage): List<List<PageRect>> {
        val result = ArrayList<List<PageRect>>()
        for (paragraph in paragraphs) {
            if (paragraph.end <= range.location) continue
            if (paragraph.start >= range.end) break
            val layout = paragraph.layout ?: continue
            val localStart = max(range.location, paragraph.start) - paragraph.start
            val localEnd = min(range.end, paragraph.contentEnd) - paragraph.start
            if (localEnd <= localStart) continue
            for (line in layout.getLineForOffset(localStart)..layout.getLineForOffset(localEnd - 1)) {
                val top = paragraph.contentTop + layout.getLineTop(line)
                val bottom = paragraph.contentTop + layout.getLineBottom(line)
                if (!(bottom - page.yOffset > -1 && top < page.contentBottom)) continue
                val a = max(localStart, layout.getLineStart(line))
                val b = min(localEnd, layout.getLineEnd(line))
                if (b <= a) continue
                val rects = extents(paragraph, layout, line, a, b).map { (left, right) ->
                    PageRect(left, top - page.yOffset, right - left, bottom - top)
                }
                if (rects.isNotEmpty()) result.add(rects)
            }
        }
        return result
    }

    /** The horizontal extents of `[a, b)` on one line, one per directional run. */
    private fun extents(paragraph: Paragraph, layout: StaticLayout, line: Int, a: Int, b: Int): List<Pair<Double, Double>> {
        val bidi = paragraph.bidi ?: Bidi(
            layout.text.toString(), Bidi.DIRECTION_DEFAULT_LEFT_TO_RIGHT,
        ).also { paragraph.bidi = it }
        val pieces = ArrayList<Pair<Int, Int>>()
        if (bidi.isMixed) {
            for (run in 0 until bidi.runCount) {
                val start = max(a, bidi.getRunStart(run))
                val end = min(b, bidi.getRunLimit(run))
                if (end > start) pieces.add(start to end)
            }
        } else {
            pieces.add(a to b)
        }
        return pieces.mapNotNull { (start, end) -> extent(layout, line, start, end) }
    }

    /**
     * One run's left and right edges on one line, or `null` when it draws
     * nothing.
     *
     * From the layout's own selection geometry, which follows justification:
     * a justified line's spaces are stretched or squeezed when it is drawn,
     * and per-character bounds measured without that put a line's last word
     * past the column's edge. Kept to the one line: a selection ending at a
     * wrapped line's end is, to `getSelectionPath`, a selection reaching the
     * next line, and it would add the band from the line's end to the column's
     * edge. So the line's last character is taken from the line's own edge.
     */
    private fun extent(layout: StaticLayout, line: Int, start: Int, end: Int): Pair<Double, Double>? {
        var left = Double.POSITIVE_INFINITY
        var right = Double.NEGATIVE_INFINITY
        val lastLine = line == layout.lineCount - 1
        val within = if (end >= layout.getLineEnd(line) && !lastLine) end - 1 else end
        if (within > start) {
            val path = Path()
            layout.getSelectionPath(start, within, path)
            val bounds = RectF()
            path.computeBounds(bounds, true)
            if (!bounds.isEmpty) {
                left = bounds.left.toDouble()
                right = bounds.right.toDouble()
            }
        }
        if (within < end) {
            val rtl = layout.isRtlCharAt(end - 1)
            val leading = layout.getPrimaryHorizontal(end - 1).toDouble()
            val edge = (if (rtl) layout.getLineLeft(line) else layout.getLineRight(line)).toDouble()
            left = min(left, min(leading, edge))
            right = max(right, max(leading, edge))
        }
        left = max(left, 0.0)
        right = min(right, layout.width.toDouble())
        if (!(right > left)) return null
        return left to right
    }

    // Hit testing

    /**
     * What the reader just tapped: the character index under a point on a
     * page, in page coordinates, so the caller does not have to know about the
     * scroll offset pagination is built on.
     *
     * Bounded to this page's own content, never the next one's. The canvas
     * clips drawing at `contentBottom` — nothing below it is ever shown for
     * this page — but a lookup straight into the continuous layout with no
     * such limit let a point in that clipped, undrawn margin resolve to a
     * fragment that is genuinely the *next* page's.
     */
    fun characterIndex(x: Double, y: Double, page: RenderedPage): Int? {
        val upper = if (page.contentBottom.isFinite()) page.contentBottom - 1 else Double.MAX_VALUE
        val inDocument = min(max(y + page.yOffset, page.yOffset), upper)
        val paragraph = paragraphs.firstOrNull { inDocument >= it.frameTop && inDocument < it.frameBottom } ?: return null
        val layout = paragraph.layout ?: return paragraph.start
        // A tap lands in a paragraph; the line inside it has to be found by
        // hand, and a point in the paragraph's spacing falls to its last line.
        val inParagraph = inDocument - paragraph.contentTop
        val line = (0 until layout.lineCount).firstOrNull {
            layout.getLineTop(it) <= inParagraph && inParagraph < layout.getLineBottom(it)
        } ?: (layout.lineCount - 1)
        val index = layout.getOffsetForHorizontal(line, x.toFloat())
        if (index < 0 || paragraph.start + index > text.length) return null
        return paragraph.start + index
    }

    /**
     * The narrated sentence under a point, for tap-to-play: nearest-enclosing,
     * among the ids [isUsable] accepts, and the nearest on the page when the
     * point encloses none. See [Paginator.fragmentId].
     */
    fun fragmentId(x: Double, y: Double, page: RenderedPage, isUsable: (String) -> Boolean = { true }): String? {
        val index = characterIndex(x, y, page) ?: return null
        return Paginator.fragmentId(index, page, fragmentRanges, isUsable)
    }

    /** The word around a character index, for a long press that should select something meaningful. */
    fun wordRange(index: Int): TextRange? = Paginator.wordRange(text, index)

    /** The sentence around a character index: the narrated fragment when there is one. */
    fun sentenceRange(index: Int): TextRange? = Paginator.sentenceRange(text, fragmentRanges, index)

    /** The character range a fragment occupies, for reading its text back. */
    fun fragmentRange(fragmentId: String): TextRange? = fragmentRanges[fragmentId]

    /** The page a fragment appears on, for "follow the narration". */
    fun pageContainingFragment(fragmentId: String): RenderedPage? =
        Paginator.pageContainingFragment(pages, fragmentRanges[fragmentId])

    /** The first fragment that *begins* on a page — the one a saved position may anchor on. See [Paginator.firstFragment]. */
    fun firstFragment(page: RenderedPage, matching: (String) -> Boolean = { true }): String? =
        Paginator.firstFragment(chapter, page, matching)

    /** The page holding a character index, for restoring a saved position. */
    fun pageContainingOffset(offset: Int): RenderedPage? = Paginator.pageContainingOffset(pages, offset)

    /** Fraction of the chapter before this page, for progress reporting. */
    fun progression(page: RenderedPage): Double = Paginator.progression(page, text.length)

    // Drawing

    /**
     * The character range the draw pass would actually paint for a page.
     *
     * Exposed so tests can assert it matches the page's own range: when the two
     * disagree, the page paints text that belongs to its neighbour — which is
     * visible as a line sliced in half at the bottom of every page.
     */
    fun paintedCharacterRange(page: RenderedPage): TextRange = Paginator.paintedCharacterRange(lines, page)

    /**
     * The page as words, for reading it aloud.
     *
     * Built from the painted range rather than `characterRange`, because a
     * paragraph that began on an earlier page is not on this one — and every
     * illustration is replaced by its alt text, since the object-replacement
     * character it leaves behind is silent.
     */
    fun spokenText(page: RenderedPage): String {
        val range = paintedCharacterRange(page)
        if (range.length <= 0 || range.end > text.length) return ""
        val result = StringBuilder(text.substring(range.location, range.end))
        // Alt-text stretches, merged where neighbours carry the same text, as
        // an attribute enumeration merges them. Replaced back to front, so
        // replacing one does not move the next.
        val replacements = ArrayList<Triple<Int, Int, String>>()
        for (run in chapter.runs) {
            if (run.end <= range.location) continue
            if (run.start >= range.end) break
            val alt = run.style.imageAlt ?: continue
            val start = max(run.start, range.location) - range.location
            val end = min(run.end, range.end) - range.location
            val previous = replacements.lastOrNull()
            if (previous != null && previous.third == alt && previous.second == start) {
                replacements[replacements.size - 1] = Triple(previous.first, end, alt)
            } else {
                replacements.add(Triple(start, end, alt))
            }
        }
        for ((start, end, alt) in replacements.asReversed()) result.replace(start, end, "Image: $alt. ")
        // Anything still unlabelled is an illustration the book gave no alt
        // text for; saying so beats a silent gap in the middle of a sentence.
        val spoken = result.toString().replace("\uFFFC", "Image. ")
        return spoken.trim { isWhitespace(it) }
    }

    /**
     * Draws one page onto a canvas whose origin is the page's top-left corner.
     *
     * Clipped to `[yOffset, contentBottom)`: a paragraph straddling the
     * boundary is visited on both pages it touches and drawn whole each time,
     * and the clip is what leaves only this page's own lines visible. Only the
     * paragraphs overlapping the page are visited, so page forty of a chapter
     * does not walk the thirty-nine before it on every redraw — every page
     * turn, every narrated sentence, every tick of the highlight.
     */
    fun draw(page: RenderedPage, canvas: Canvas) {
        val saved = canvas.save()
        if (page.contentBottom.isFinite()) {
            canvas.clipRect(-100_000f, 0f, 100_000f, (page.contentBottom - page.yOffset).toFloat())
        }
        canvas.translate(0f, (-page.yOffset).toFloat())
        for (paragraph in paragraphs) {
            if (paragraph.frameBottom <= page.yOffset - 0.5) continue
            if (paragraph.frameTop >= page.contentBottom) break
            val layout = paragraph.layout ?: continue
            val inner = canvas.save()
            canvas.translate(0f, paragraph.contentTop.toFloat())
            layout.draw(canvas)
            canvas.restoreToCount(inner)
        }
        canvas.restoreToCount(saved)
    }

    private companion object {
        /** Paragraph separators: a newline, a carriage return (with or without its newline) and U+2029. */
        fun splitParagraphs(text: String): List<Paragraph> {
            val found = ArrayList<Paragraph>()
            if (text.isEmpty()) return found
            var start = 0
            var index = 0
            while (index < text.length) {
                val unit = text[index]
                if (unit == '\n' || unit == '\r' || unit == '\u2029') {
                    val end = if (unit == '\r' && index + 1 < text.length && text[index + 1] == '\n') index + 2 else index + 1
                    found.add(Paragraph(start, index, end))
                    start = end
                    index = end
                    continue
                }
                index += 1
            }
            if (start < text.length) found.add(Paragraph(start, text.length, text.length))
            return found
        }

        /** `trimmingCharacters(in: .whitespacesAndNewlines)`, unit by unit. */
        fun isWhitespace(unit: Char): Boolean = when (unit.code) {
            in 0x0009..0x000D, 0x0020, 0x0085, 0x00A0, 0x1680, in 0x2000..0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 -> true
            else -> false
        }
    }
}
