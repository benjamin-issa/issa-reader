package com.benjaminissa.issareader.render

import java.text.BreakIterator

/** One laid-out page: where it sits in the continuous layout, and what it covers. */
data class RenderedPage(
    val index: Int,
    /**
     * Y offset of this page's top within the continuous layout. Drawing a page
     * is a translation, never a re-layout.
     */
    val yOffset: Double,
    val height: Double,
    /**
     * Y offset where the NEXT page begins, or infinity on the last page.
     *
     * Drawing uses this rather than `yOffset + height` to decide what belongs
     * on the page. The two are not the same: pagination refuses to split a
     * line across a boundary, so a page's content usually stops short of its
     * height, and bounding the draw by height instead pulls in the following
     * page's opening line and clips it mid-glyph.
     */
    val contentBottom: Double,
    /** Character range of the text on this page. */
    val characterRange: TextRange,
) {
    val id: Int get() = index
}

/**
 * One line of the laid-out chapter, as pagination sees it: its vertical extent
 * in the continuous layout and the characters it holds. The Android layout
 * flattens its paragraphs into these; the Swift one reads them off TextKit's
 * line fragments.
 */
data class LineBox(
    /** Top of the line's typographic bounds, in the continuous layout. */
    val top: Double,
    val bottom: Double,
    /** First character, inclusive. */
    val start: Int,
    /** One past the last character. */
    val end: Int,
)

/**
 * The parts of the Swift `ChapterLayout` that are arithmetic over lines and
 * ranges rather than layout: how a chapter is cut into pages, and every lookup
 * that is answered from the pages, the fragment ranges and the text alone.
 *
 * The chapter is laid out once in an unbounded column and cut into
 * page-height bands, so turning a page is a translation of already-computed
 * geometry, and the rectangles needed to highlight a narrated sentence are
 * available without laying anything out again.
 */
object Paginator {
    /**
     * Cuts a chapter's lines into pages.
     *
     * Per line, not per paragraph. Pushing an entire long paragraph to the
     * next page rather than splitting its lines wasted up to a full page of
     * blank space below a short one — worse, a paragraph taller than one page
     * could never fit on any single page at all and had its tail silently
     * clipped by the fixed-size canvas, since nothing ever gave it a second
     * page to continue onto.
     *
     * A LINE that would cross the boundary starts the next page instead of
     * being split, so no line is ever cut in half. The `top > pageTop` guard is
     * the anti-loop protection, sized to "a line taller than a page" — a
     * full-height plate still trips it, since an image rides in its own line.
     *
     * @param lines every line of the chapter, top to bottom.
     * @param textLength the chapter's length, which the last page runs to.
     */
    fun computePages(lines: List<LineBox>, pageHeight: Double, textLength: Int): List<RenderedPage> {
        val tops = arrayListOf(0.0)
        val starts = arrayListOf(0)
        for (line in lines) {
            val pageTop = tops.last()
            if (line.bottom > pageTop + pageHeight && line.top > pageTop) {
                tops.add(line.top)
                starts.add(line.start)
            }
        }
        return tops.indices.map { index ->
            val nextTop = if (index + 1 < tops.size) tops[index + 1] else Double.POSITIVE_INFINITY
            val endOffset = if (index + 1 < starts.size) starts[index + 1] else textLength
            RenderedPage(
                index = index,
                yOffset = tops[index],
                height = pageHeight,
                contentBottom = nextTop,
                characterRange = TextRange(starts[index], maxOf(0, endOffset - starts[index])),
            )
        }
    }

    /**
     * The character range the draw pass would actually paint for a page.
     *
     * Only the lines this page actually draws — a paragraph straddling the
     * boundary has lines belonging to its neighbour, and counting them here is
     * what let a page's spoken text quietly repeat or skip a sentence at the
     * seam.
     *
     * No epsilon, deliberately. [computePages] sets a new page's `yOffset` to
     * the exact top of the line that starts it, and lines within one paragraph
     * sit flush — so the preceding line's bottom and this line's top are the
     * same value. A half-point tolerance included that preceding line on both
     * pages at once.
     */
    fun paintedCharacterRange(lines: List<LineBox>, page: RenderedPage): TextRange {
        var lower = Int.MAX_VALUE
        var upper = 0
        for (line in lines) {
            if (line.top >= page.contentBottom) break
            if (!(line.bottom > page.yOffset && line.top < page.contentBottom)) continue
            lower = minOf(lower, line.start)
            upper = maxOf(upper, line.end)
        }
        if (lower == Int.MAX_VALUE) return TextRange(page.characterRange.location, 0)
        return TextRange(lower, upper - lower)
    }

    /** The page a fragment appears on, for "follow the narration". */
    fun pageContainingFragment(pages: List<RenderedPage>, range: TextRange?): RenderedPage? {
        range ?: return null
        return pages.firstOrNull { page ->
            range.location in page.characterRange ||
                (range.location < page.characterRange.location && range.end > page.characterRange.location)
        }
    }

    /** The page holding a character index, for restoring a saved position. */
    fun pageContainingOffset(pages: List<RenderedPage>, offset: Int): RenderedPage? =
        pages.firstOrNull { offset in it.characterRange } ?: pages.lastOrNull()

    /** Fraction of the chapter before this page, for progress reporting. */
    fun progression(page: RenderedPage, textLength: Int): Double {
        if (textLength <= 0) return 0.0
        return page.characterRange.location.toDouble() / textLength.toDouble()
    }

    /**
     * The first fragment that *begins* on a page — the one a saved position
     * may anchor on.
     *
     * Not the one covering the page's first character. Pages break per line,
     * so that fragment usually began on the page before, and a position
     * anchored on it came back to that page's start; the close then saved the
     * page it had landed on, and every open walked the reader back one more
     * page. `null` when no fragment starts here — one sentence spanning the
     * whole page — and the position rests on its offset and quote instead.
     *
     * @param matching which ids count. The default takes any. A caller that
     *   means "the first *narrated* sentence" must say so here rather than
     *   reject the answer afterwards: element ids are not all sentences —
     *   headings, page anchors and a publisher's own paragraph wrappers carry
     *   them too — so a wrapper opening the page would otherwise shadow the
     *   sentence inside it and the caller would be told there is nothing here.
     */
    fun firstFragment(chapter: StyledChapter, page: RenderedPage, matching: (String) -> Boolean = { true }): String? {
        val range = page.characterRange
        if (range.length <= 0 || range.end > chapter.text.length) return null
        // The fragment-id attribute run by run across the page, in order: the
        // Swift side's `enumerateAttribute(.issaFragmentID, in: range)`.
        var previous: String? = null
        for (run in chapter.runs) {
            if (run.end <= range.location) continue
            if (run.start >= range.end) break
            val id = run.fragmentId ?: continue
            if (id == previous) continue
            previous = id
            val whole = chapter.fragmentRanges[id] ?: continue
            if (whole.location >= range.location && matching(id)) return id
        }
        return null
    }

    /**
     * The narrated sentence at a character index on a page, for tap-to-play.
     *
     * Nearest-enclosing wins: fragment ranges nest when a sentence contains
     * marked-up spans, and the reader means the innermost thing they tapped.
     *
     * @param rawIndex the character under the tap.
     * @param isUsable which ids the caller can actually do something with.
     *   **Not every element id is a sentence** — a chapter heading, a
     *   page-break anchor and a publisher's own paragraph wrapper all carry
     *   one, and which of those a book contains varies entirely by who made it.
     *   Without this filter the nearest-enclosing answer can be an id the
     *   caller has no use for, and the tap does nothing at all rather than
     *   falling through to the sentence that is right there.
     *
     * Falls back to the nearest usable fragment *on the same page* when the
     * point encloses none. A tap past the end of a short last line, or in the
     * space between paragraphs, lands on characters that belong to no sentence
     * — in some books a great many characters do — and answering "nothing"
     * there is never what the reader meant by pointing at a page.
     */
    fun fragmentId(
        rawIndex: Int,
        page: RenderedPage,
        fragmentRanges: Map<String, TextRange>,
        isUsable: (String) -> Boolean = { true },
    ): String? {
        // Clamped into this page's own character range. A tap right at a
        // page's last line can compute an "end of line" index equal to the very
        // first character of the *next* fragment — genuinely ambiguous, since
        // that number is simultaneously "one past this page's last character"
        // and "the first of the next page's". Left unclamped, that ambiguity
        // always resolved in the next page's favour, because the enclosing
        // search matches a range's start inclusively. Symmetric at the top for
        // the same reason a tap at a page's very first pixel deserves.
        val index = if (page.characterRange.length > 0) {
            minOf(maxOf(rawIndex, page.characterRange.location), page.characterRange.end - 1)
        } else {
            rawIndex
        }
        val enclosing = fragmentRanges.entries
            .filter { isUsable(it.key) && index in it.value }
            // Length first, then the id, because a map has no order to rely
            // on and two equal-length ranges would otherwise resolve
            // differently from one run to the next.
            .minWithOrNull(compareBy<Map.Entry<String, TextRange>>({ it.value.length }, { it.key }))
            ?.key
        return enclosing ?: nearestFragment(index, page, fragmentRanges, isUsable)
    }

    /**
     * The usable fragment whose characters come closest to an index, within
     * the page the reader is looking at.
     *
     * Page-bounded on purpose: without it a tap on a blank half-page at the
     * end of a chapter would reach back into the previous page's text.
     */
    private fun nearestFragment(
        index: Int,
        page: RenderedPage,
        fragmentRanges: Map<String, TextRange>,
        isUsable: (String) -> Boolean,
    ): String? {
        var bestId: String? = null
        var bestDistance = 0
        for ((id, range) in fragmentRanges) {
            if (!isUsable(id)) continue
            if (range.length <= 0 || range.intersection(page.characterRange).length <= 0) continue
            val distance = when {
                index < range.location -> range.location - index
                index >= range.end -> index - (range.end - 1)
                else -> 0
            }
            // Ties broken by id, again for determinism.
            val best = bestId
            if (best == null || distance < bestDistance || (distance == bestDistance && id < best)) {
                bestId = id
                bestDistance = distance
            }
        }
        return bestId
    }

    /**
     * The word around a character index, for a long press that should select
     * something meaningful rather than a single letter.
     *
     * Bounded by whitespace and punctuation, except the apostrophes and the
     * hyphen a word can contain — Foundation's `whitespacesAndNewlines` and
     * `punctuationCharacters`, less `'’-`, unit by unit.
     */
    fun wordRange(text: String, index: Int): TextRange? {
        if (index < 0 || index >= text.length) return null
        var start = index
        while (start > 0) {
            if (isWordSeparator(text[start - 1])) break
            start -= 1
        }
        var end = index
        while (end < text.length) {
            if (isWordSeparator(text[end])) break
            end += 1
        }
        if (end <= start) return null
        return TextRange(start, end - start)
    }

    private fun isWordSeparator(unit: Char): Boolean {
        if (unit == '\'' || unit == '’' || unit == '-') return false
        if (isSwiftWhitespace(unit.code)) return true
        return when (Character.getType(unit).toByte()) {
            Character.CONNECTOR_PUNCTUATION, Character.DASH_PUNCTUATION, Character.START_PUNCTUATION,
            Character.END_PUNCTUATION, Character.INITIAL_QUOTE_PUNCTUATION, Character.FINAL_QUOTE_PUNCTUATION,
            Character.OTHER_PUNCTUATION,
            -> true
            else -> false
        }
    }

    /**
     * The sentence around a character index.
     *
     * Uses the narrated fragment when there is one — the aligner already split
     * the text into sentences, and its idea of a sentence beats a second guess
     * made from punctuation.
     */
    fun sentenceRange(text: String, fragmentRanges: Map<String, TextRange>, index: Int): TextRange? {
        fragmentRanges.values.filter { index in it }.minByOrNull { it.length }?.let { return it }
        if (index < 0 || index >= text.length) return null
        val sentences = BreakIterator.getSentenceInstance()
        sentences.setText(text)
        val end = sentences.following(index)
        val start = sentences.previous()
        if (start == BreakIterator.DONE || end == BreakIterator.DONE) return null
        return TextRange(start, end - start)
    }
}
