package com.benjaminissa.issareader.ask

import com.benjaminissa.issareader.render.TextRange

/**
 * One retrievable piece of a chapter, and where it sits in the rendered text.
 *
 * [start] and [end] are UTF-16 offsets into the chapter's rendered string —
 * the same coordinate system [ReadingBoundary.charOffset], the reader's page
 * ranges and the parser's fragment ranges all use. That is the whole point of
 * the type: the spoiler boundary is a comparison between two numbers, and it
 * is only sound if both were measured against the same string.
 */
data class Passage(
    val spineIndex: Int,
    /**
     * Position within the chapter, zero-based. With [spineIndex] it gives the
     * stable book order the ranker restores after scoring.
     */
    val ordinal: Int,
    val start: Int,
    val end: Int,
    val words: Int,
    /**
     * The chapter's characters from [start], verbatim — leading whitespace
     * included, only the trailing tiling newlines removed.
     *
     * Deliberately not trimmed at the front. Character *i* of this string is
     * chapter offset `start + i`, which is the single invariant that lets the
     * straddling passage be cut to exactly `boundary.charOffset - start`
     * UTF-16 units. Trim it at the front and the cut lands a character or two
     * late, which is a word of the next sentence the reader has not read.
     */
    val text: String,
) {
    val range: TextRange get() = TextRange(start, end - start)

    /**
     * What the model and the UI are shown: the stored text without the
     * whitespace the tiling handed it.
     */
    val displayText: String get() = text.trimmingWhitespaceAndNewlines()
}

/**
 * Cuts a chapter's rendered text into passages a 4,096-token context can
 * actually afford to carry.
 *
 * The unit is a paragraph, because that is what a novel is written in and what
 * answers a question without stranding half a sentence. The limits below are
 * the compromise: small enough that a dozen of them fit in the budget with
 * room for instructions and an answer; large enough that a passage still says
 * who is speaking and where they are.
 *
 * Ranges tile the chapter with no gaps. That is not tidiness — the boundary
 * clause truncates the one passage that straddles the reader's position, and a
 * gap there would silently drop the very sentence being read.
 */
object PassageChunker {
    /**
     * Every number the chunker has an opinion about, in one place, so a test
     * asserts against the shipped constants rather than its own copy of them.
     */
    object Limits {
        /** What a passage aims for. Roughly 120 tokens. */
        const val targetWords = 90

        /** Above this a paragraph is split at a sentence boundary. */
        const val maximumWords = 140

        /**
         * Below this a passage is not worth retrieving on its own and is
         * merged into the one before it — a line of dialogue on its own tells
         * the model nothing about who said it.
         */
        const val minimumWords = 40

        /** How many lines a passage needs before its shape is allowed to say anything. */
        internal const val navigationLines = 4

        /**
         * A line this long is prose, whatever else is around it. Generous,
         * because a chapter title runs to nine words in *Alice* ("CHAPTER IV.
         * The Rabbit Sends in a Little Bill").
         */
        internal const val navigationLineWords = 12

        /**
         * What share of a passage's lines must be short before it can be a
         * contents list. Near-total: the contents tables in both fixtures are
         * 100% short lines, and the paragraph that follows a chapter heading
         * drops it to two thirds.
         */
        internal const val navigationShortShare = 0.9

        /** What share of a passage's non-numbered lines must be the book's own section titles. */
        internal const val navigationTitleShare = 0.6

        /**
         * …and how many of them there must be at all, so a chapter opening
         * "CHAPTER I. / Down the Rabbit-Hole" — two lines that both look like
         * halves of one navigation entry — cannot reach the threshold.
         */
        internal const val navigationTitles = 3
    }

    /**
     * Splits one chapter's rendered string.
     *
     * @param text the chapter as the reader sees it, images and all.
     * @param spineIndex stamped onto every passage; the chunker does no I/O.
     */
    fun chunk(text: String, spineIndex: Int): List<Passage> {
        if (text.isEmpty()) return emptyList()

        // 1. Paragraphs, as blocks separated by a newline. The chapter parser
        //    emits exactly one newline between blocks and never stacks two, so
        //    a blank-line split would find nothing to split on.
        val blocks = paragraphRanges(text)
        if (blocks.isEmpty()) return emptyList()

        // 2. Oversized paragraphs split at sentences; everything else passes
        //    through whole.
        val pieces = ArrayList<TextRange>()
        for (block in blocks) {
            val body = text.substring(block.location, block.end)
            if (wordCount(body) > Limits.maximumWords) pieces.addAll(splitAtSentences(block, text)) else pieces.add(block)
        }

        // 3. Merge forward: a runt, a heading, or anything short joins the
        //    piece before it — or, when it is the first, adopts the next one.
        val merged = ArrayList<TextRange>()
        for (piece in pieces) {
            val body = text.substring(piece.location, piece.end)
            val short = wordCount(body) < Limits.minimumWords
            val last = merged.lastOrNull()
            if (short && last != null &&
                wordCount(text.substring(last.location, last.end)) + wordCount(body) <= Limits.maximumWords
            ) {
                merged[merged.size - 1] = TextRange(last.location, piece.end - last.location)
            } else {
                merged.add(piece)
            }
        }
        // A chapter that opens on a heading leaves the heading first and short;
        // it belongs with the paragraph that follows, not alone.
        if (merged.size > 1 && wordCount(text.substring(merged[0].location, merged[0].end)) < Limits.minimumWords) {
            val first = merged[0]
            val second = merged[1]
            merged[1] = TextRange(first.location, second.end - first.location)
            merged.removeAt(0)
        }

        // 4. Tile: each passage runs from its own start to the next one's, so
        //    the inter-block whitespace belongs to somebody and the last
        //    passage reaches the end of the chapter. Without this the
        //    straddling passage's truncation could land in a hole.
        val passages = ArrayList<Passage>(merged.size)
        for ((ordinal, piece) in merged.withIndex()) {
            val start = if (ordinal == 0) 0 else piece.location
            val end = if (ordinal == merged.size - 1) text.length else merged[ordinal + 1].location
            val stored = trimmingTail(text.substring(start, end))
            passages.add(
                Passage(
                    spineIndex = spineIndex, ordinal = ordinal, start = start, end = end,
                    words = wordCount(stored), text = stored,
                ),
            )
        }
        return passages
    }

    // What is worth indexing

    /**
     * [chunk], cut to the book and minus the passages that are a table of
     * contents rather than the book.
     *
     * A second function rather than a filter inside [chunk], because the
     * tiling [chunk] promises is load-bearing: every character of the chapter
     * belongs to some passage, which is what lets the straddling passage be
     * cut to exactly the characters the reader has read. This is the
     * *indexing* decision on top of it. Dropping a navigation passage only
     * ever removes something from retrieval — it cannot move an offset, and
     * every passage that remains still carries the offsets [chunk] gave it.
     *
     * The bug, verified on the Swift client: "Who is Alice?" asked at 4% cited
     * "CHAPTER XII. Alice's Evidence". Not a boundary leak — the passage is
     * Gutenberg's own contents table, which sits on the header page at the
     * front of the spine and is legitimately behind the reader — but a list of
     * chapter titles is not evidence, and citing one makes the whole feature
     * look broken.
     *
     * **The boilerplate is clipped, not filtered, and that is a bug fix.** This
     * used to drop any passage not wholly inside [bookRange], while [chunk]
     * tiles the chapter with no gaps — so the one passage that *straddles* a
     * Gutenberg START or END marker was discarded entire, taking whatever real
     * book text sat in its tail with it: 639 characters, 93 words, of real book
     * text in *Franklin*'s spine 10, the tail of his chronology. Clipping keeps
     * that text, and restores the tiling invariant [chunk] documents.
     *
     * Clipped *before* the navigation test, so a straddling passage is judged
     * on the book text it actually contributes rather than on the licence
     * block in front of it.
     *
     * @param navigationTitles the book's own table of contents entries,
     *   `EpubPackage.navigation`. With none of them nothing is dropped, which
     *   is the right default: the test is "these lines are the book's section
     *   titles", and without the titles there is nothing to be sure about.
     */
    fun indexable(text: String, spineIndex: Int, navigationTitles: List<String> = emptyList()): List<Passage> {
        val book = bookRange(text)
        var passages = chunk(text, spineIndex).mapNotNull { clipped(it, book, text) }
        val titles = navigationTitles.map { QueryTerms.tokens(it) }.filter { it.isNotEmpty() }
        if (titles.isNotEmpty()) passages = passages.filter { !isNavigationList(it.text, titles) }
        return passages
    }

    /**
     * One passage, cut to the part of it that is the book, or null where none
     * of it is.
     *
     * The offsets move with the text, which is the whole point: [Passage.text]
     * promises that character *i* of it is chapter offset `start + i`, and the
     * boundary truncation is `boundary.charOffset - start` UTF-16 units into
     * that string. A clipped passage that kept the old `start` would cut the
     * reader's position a title page early.
     */
    private fun clipped(passage: Passage, book: TextRange, text: String): Passage? {
        val start = maxOf(passage.start, book.location)
        val end = minOf(passage.end, book.end)
        if (start >= end) return null
        // Wholly inside, which is every passage of every book that has no
        // markers at all: nothing to recompute, and no substring to take.
        if (start == passage.start && end == passage.end) return passage
        val stored = trimmingTail(text.substring(start, end))
        return Passage(
            spineIndex = passage.spineIndex, ordinal = passage.ordinal,
            start = start, end = end, words = wordCount(stored), text = stored,
        )
    }

    /**
     * Trailing whitespace only: dropping the tiling's newlines costs nothing,
     * and dropping anything from the front would break the offset identity
     * [Passage.text] documents.
     *
     * Shared by [chunk] and [clipped] so a clipped passage is stored exactly
     * as a whole one is.
     */
    private fun trimmingTail(body: String): String {
        var end = body.length
        while (end > 0) {
            val codePoint = body.codePointBefore(end)
            if (!isSwiftWhitespace(codePoint) && !isSwiftNewline(codePoint)) break
            end -= Character.charCount(codePoint)
        }
        return if (end == body.length) body else body.substring(0, end)
    }

    /**
     * What of a chapter is the book, when the transcriber says so.
     *
     * Project Gutenberg wraps every one of its books in a legal notice and a
     * credits block, and marks the join itself:
     *
     *     *** START OF THE PROJECT GUTENBERG EBOOK ALICE'S ADVENTURES … ***
     *     *** END OF THE PROJECT GUTENBERG EBOOK ALICE'S ADVENTURES … ***
     *
     * Those lines exist so that tools can strip what is outside them, and this
     * is that. Outside them is a licence, a release date, and a *Credits* line
     * — and the credits are people, who were offered as suggestion chips
     * ("Who is David Widger?" beside "Who is Alice?").
     *
     * Exact rather than heuristic: the marker is a literal string the producer
     * writes. A book without one keeps every character it has. Both spellings,
     * because Gutenberg has used *THE* and *THIS* over the years.
     */
    fun bookRange(text: String): TextRange {
        var start = 0
        var end = text.length
        for (opener in boilerplateOpeners) {
            val found = text.indexOf(opener)
            if (found < 0) continue
            start = maxOf(start, found + opener.length)
        }
        for (closer in boilerplateClosers) {
            val found = text.indexOf(closer)
            if (found < 0) continue
            end = minOf(end, found)
        }
        if (start > end) return TextRange(0, text.length)
        return TextRange(start, end - start)
    }

    internal val boilerplateOpeners = listOf(
        "*** START OF THE PROJECT GUTENBERG EBOOK",
        "*** START OF THIS PROJECT GUTENBERG EBOOK",
    )
    internal val boilerplateClosers = listOf(
        "*** END OF THE PROJECT GUTENBERG EBOOK",
        "*** END OF THIS PROJECT GUTENBERG EBOOK",
    )

    /**
     * Whether this passage is a list of the book's own section titles.
     *
     * **Three gates, and all three are needed.** *Alice*'s contents table and
     * the Mouse's Tale have the same shape, so no measure of line length can
     * tell a table of contents from a shaped poem. The same is true of the
     * bare numbers: half the lines of Franklin's contents are page numbers,
     * and so are two thirds of the lines of his hour-by-hour daily plan, which
     * is genuine book content.
     *
     * What actually separates them is that a contents list's lines *are* the
     * book's navigation entries and a poem's lines are not. So the titles
     * decide, the line shape only qualifies, and the numbered lines are left
     * out of the denominator rather than counted for or against.
     *
     * Matching is deliberately loose. Gutenberg's NCX calls the chapter "I
     * ANCESTRY AND EARLY YOUTH IN BOSTON" while its own contents page prints
     * "I. Ancestry and Early Life in Boston", so an equality test finds
     * nothing on the very book this was measured against.
     */
    internal fun isNavigationList(text: String, titles: List<List<String>>): Boolean {
        val lines = splitLines(text).map { it.trimmingWhitespaces() }.filter { it.isNotEmpty() }
        if (lines.size < Limits.navigationLines) return false

        val short = lines.filter { wordCount(it) <= Limits.navigationLineWords }
        if (short.size.toDouble() < lines.size.toDouble() * Limits.navigationShortShare) return false

        // A line of nothing but digits and punctuation is a page number.
        val candidates = lines.filter { line -> line.codePointList().any(::isSwiftLetter) }
        if (candidates.isEmpty()) return false
        val matched = candidates.filter { line ->
            val tokens = QueryTerms.tokens(line)
            titles.any { matches(tokens, it) }
        }
        return matched.size >= Limits.navigationTitles &&
            matched.size.toDouble() >= candidates.size.toDouble() * Limits.navigationTitleShare
    }

    /** `split(whereSeparator: \.isNewline)`, empty pieces omitted. */
    private fun splitLines(text: String): List<String> {
        val lines = ArrayList<String>()
        var start = 0
        var index = 0
        while (index < text.length) {
            val codePoint = text.codePointAt(index)
            val width = Character.charCount(codePoint)
            if (isSwiftNewline(codePoint)) {
                if (index > start) lines.add(text.substring(start, index))
                start = index + width
            }
            index += width
        }
        if (start < text.length) lines.add(text.substring(start))
        return lines
    }

    /**
     * Whether a line and a navigation entry are the same entry.
     *
     * Equal, or one the beginning of the other, or sharing most of their
     * words. The prefix arm needs the shorter side to be four characters
     * before it counts, or a bare "I." on its own line is the beginning of
     * every Roman-numbered chapter title in the book.
     */
    internal fun matches(line: List<String>, title: List<String>): Boolean {
        if (line.isEmpty() || title.isEmpty()) return false
        val joinedLine = line.joinToString("")
        val joinedTitle = title.joinToString("")
        if (joinedLine == joinedTitle) return true
        if (minOf(joinedLine.graphemeCount(), joinedTitle.graphemeCount()) >= 4 &&
            (joinedLine.startsWith(joinedTitle) || joinedTitle.startsWith(joinedLine))
        ) {
            return true
        }
        val shared = line.toSet().intersect(title.toSet()).size
        return shared >= 3 && shared.toDouble() >= minOf(line.size, title.size).toDouble() * Limits.navigationTitleShare
    }

    // Pieces

    /**
     * Blocks of the chapter, one per line of rendered text.
     *
     * Empty lines are skipped as ranges but not as characters: the tiling step
     * hands their characters to whichever passage precedes them.
     */
    internal fun paragraphRanges(text: String): List<TextRange> {
        val ranges = ArrayList<TextRange>()
        var index = 0
        while (index < text.length) {
            val line = text.lineRangeAt(index)
            val body = text.substring(line.first, line.last + 1)
            if (body.trimmingWhitespaceAndNewlines().isNotEmpty()) ranges.add(TextRange(line.first, line.last + 1 - line.first))
            index = line.first + maxOf(line.last + 1 - line.first, 1)
        }
        return ranges
    }

    /**
     * Cuts an over-long paragraph at sentence ends, filling to the target.
     *
     * The platform's sentence rules rather than a full stop scan: they get
     * "Mr. Rabbit", ellipses and quotation right, and a naive scan does not —
     * which would cut mid-sentence and hand the model half a thought.
     */
    internal fun splitAtSentences(range: TextRange, text: String): List<TextRange> {
        val sentences = SentenceBreaker.current.sentences(text, range.location, range.end)
        if (sentences.size <= 1) return listOf(range)

        val pieces = ArrayList<TextRange>()
        var current: TextRange? = null
        var words = 0
        for (sentence in sentences) {
            val count = wordCount(text.substring(sentence.location, sentence.end))
            val open = current
            if (open != null && words + count > Limits.targetWords) {
                pieces.add(open)
                current = sentence
                words = count
            } else if (open != null) {
                current = TextRange(open.location, sentence.end - open.location)
                words += count
            } else {
                current = sentence
                words = count
            }
        }
        current?.let(pieces::add)
        // The enumeration may skip leading whitespace; re-anchor to the block
        // so the tiling has nothing to fill in at the front.
        val first = pieces.first()
        if (first.location != range.location) pieces[0] = TextRange(range.location, first.end - range.location)
        return pieces
    }

    /**
     * Whitespace-separated runs. Good enough for a budget: the token estimate
     * downstream is what actually decides whether a passage fits.
     */
    fun wordCount(text: String): Int {
        var count = 0
        var inWord = false
        var index = 0
        while (index < text.length) {
            val codePoint = text.codePointAt(index)
            if (isWhitespaceOrNewline(codePoint)) {
                inWord = false
            } else if (!inWord) {
                inWord = true
                count += 1
            }
            index += Character.charCount(codePoint)
        }
        return count
    }
}
