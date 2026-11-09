package com.benjaminissa.issareader.ask

import com.benjaminissa.issareader.render.TextRange

/**
 * Cuts a passage into sentences, for the retrieval that decides which of them
 * says anything.
 *
 * A separate splitter from [PassageChunker]'s, deliberately. That one decides
 * where a *passage* starts, and every offset in every index on every device
 * was computed with it; touching it would move the reading boundary. This one
 * only reads what is already stored, so it can be as fussy as it likes.
 *
 * Fussy is required. ICU's sentence rules split "Mr. Rabbit ran." into "Mr."
 * and "Rabbit ran." — which turns the sentence that introduces a character
 * into a two-word fragment that predicates nothing, and hands the model half a
 * thought with a citation on it. So fragments that end in an honorific or an
 * initial are merged forward, and so are runts with no terminal punctuation.
 *
 * UTF-16 ranges throughout, because character *i* of a [Passage.text] is
 * chapter offset `start + i`, and that identity is what lets an evidence
 * sentence keep real chapter offsets — which is what keeps it inside the
 * spoiler boundary.
 */
object SentenceSplitter {
    /**
     * Sentence ranges covering [range] with no gaps.
     *
     * Tiled rather than trimmed: the ranges are used to cut windows out of a
     * passage, and a gap between two of them is a few characters of the book
     * that no window can ever show — including, when the gap falls at the end,
     * the punctuation that says the sentence finished.
     */
    fun ranges(text: String, range: TextRange): List<TextRange> {
        if (range.length <= 0 || range.location < 0 || range.end > text.length) return emptyList()
        val found = SentenceBreaker.current.sentences(text, range.location, range.end)
        if (found.isEmpty()) return listOf(range)

        // No substrings at all until a sentence actually needs one. Deciding
        // "is this a fragment?" by trimming and splitting each piece into words
        // measured at 25 ms over a 300-passage scan — nine times what the
        // sentence enumeration itself cost.
        val merged = ArrayList<TextRange>(found.size)
        for (sentence in found) {
            val last = merged.lastOrNull()
            if (last != null && needsMore(text, last)) {
                merged[merged.size - 1] = TextRange(last.location, sentence.end - last.location)
            } else {
                merged.add(sentence)
            }
        }

        val tiled = ArrayList<TextRange>(merged.size)
        for ((index, piece) in merged.withIndex()) {
            val start = if (index == 0) range.location else piece.location
            val end = if (index == merged.size - 1) range.end else merged[index + 1].location
            val length = maxOf(0, end - start)
            if (length > 0) tiled.add(TextRange(start, length))
        }
        return tiled
    }

    /** The whole of a string. */
    fun ranges(text: String): List<TextRange> = ranges(text, TextRange(0, text.length))

    // Merging

    /**
     * Whether this piece is the front half of a sentence ICU cut in two.
     *
     * Two cases, both of which produce evidence that says nothing: an
     * abbreviation the splitter mistook for a full stop ("Mr.", "T."), and a
     * runt with no terminal punctuation at all — a heading, a speaker's name
     * on its own line, the tail of a line-broken title.
     */
    internal fun needsMore(units: String, range: TextRange): Boolean {
        // Back past the quotation marks and brackets that sit outside a full
        // stop, and past the whitespace ICU left on the end.
        var index = range.end - 1
        while (index >= range.location && isSkippable(units[index].code)) index -= 1
        // Nothing but punctuation and space: not a sentence at all.
        if (index < range.location) return true

        val last = units[index].code
        if (last == PERIOD) {
            val start = wordStart(units, index, range.location)
            if (index - start > LONGEST_ABBREVIATION) return false
            val word = units.substring(start, index).trimmingNonLetters()
            if (word.lowercasedSwift() in NameFinder.honorifics) return true
            // A single capital and a full stop is an initial — "T. Rabbit" —
            // and splitting there loses whoever it belongs to.
            return word.graphemeCount() == 1 && word.firstCodePoint?.let(::isSwiftUppercase) == true
        }
        if (last in TERMINATORS) return false
        // Not terminated at all: a heading, a speaker's name on its own line,
        // the tail of a line-broken title. It joins what follows.
        return words(units, range, MINIMUM_WORDS) < MINIMUM_WORDS
    }

    /** Below this a piece is not a sentence, it is a fragment of one. */
    internal const val MINIMUM_WORDS = 3

    /**
     * Past this a word is not an abbreviation, and there is nothing to
     * allocate a string for. "professor" is the longest in the table.
     */
    internal const val LONGEST_ABBREVIATION = 12

    /** Where the word ending just before [index] begins. */
    internal fun wordStart(units: String, index: Int, floor: Int): Int {
        var start = index
        while (start > floor && !isWhitespace(units[start - 1].code)) start -= 1
        return start
    }

    /** Whitespace-separated runs, counting no further than it has to. */
    internal fun words(units: String, range: TextRange, limit: Int): Int {
        var count = 0
        var inWord = false
        for (index in range.location until range.end) {
            if (isWhitespace(units[index].code)) {
                inWord = false
            } else if (!inWord) {
                inWord = true
                count += 1
                if (count >= limit) return count
            }
        }
        return count
    }

    // Code units

    internal const val PERIOD = 0x2E

    internal fun isWhitespace(unit: Int): Boolean =
        unit == 0x20 || unit == 0x0A || unit == 0x0D || unit == 0x09 ||
            unit == 0x00A0 || unit == 0x2028 || unit == 0x2029

    /** Quotation marks and brackets, which sit outside the full stop, plus the whitespace that follows it. */
    internal fun isSkippable(unit: Int): Boolean = isWhitespace(unit) || unit in CLOSING_MARKS

    internal val CLOSING_MARKS: Set<Int> = setOf(
        0x22, 0x27, 0x29, 0x5D, 0x7D, 0x00BB, 0x2018, 0x2019, 0x201C, 0x201D, 0x203A,
    )
    internal val TERMINATORS: Set<Int> = setOf(0x2E, 0x21, 0x3F, 0x2026, 0x3A, 0x3B)
}
