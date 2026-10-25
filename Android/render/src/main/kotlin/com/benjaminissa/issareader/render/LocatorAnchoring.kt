package com.benjaminissa.issareader.render

import com.benjaminissa.issareader.core.model.ReadiumLocator
import com.benjaminissa.issareader.core.model.asProgression
import java.util.regex.Matcher
import java.util.regex.Pattern
import kotlin.math.abs

/**
 * Turns a stored position back into an exact place in freshly laid-out text.
 *
 * A locator is written against one rendering and read back against another: a
 * different font size, a different device, sometimes a different client. Page
 * numbers do not survive that, and progression alone lands the reader a
 * paragraph or two out — enough to be irritating in a novel and disorienting
 * mid-chapter. So resolution walks a ladder of anchors, strongest first, and
 * falls back only as far as it has to.
 *
 * Every offset here is a UTF-16 index into the string [ChapterParser] builds,
 * which is the Swift client's string too, so a position resolves to the same
 * place on either.
 */
object LocatorAnchoring {
    /**
     * Where in the chapter's text this locator points, as a character index.
     *
     * @param locator the stored position.
     * @param text the chapter as rendered now.
     * @param fragmentRanges element id → range, from the parser.
     */
    fun characterOffset(locator: ReadiumLocator, text: String, fragmentRanges: Map<String, TextRange>): Int? {
        val length = text.length
        if (length <= 0) return null

        // 1. The narrated sentence id. Exact, and stable across renderings,
        //    because it comes from the markup rather than from the layout.
        //
        //    Refined by the recorded offset when that falls inside the
        //    sentence. Page breaks land mid-sentence far more often than not,
        //    so a position saved at the top of a page names a sentence that
        //    began on the page before; returning the sentence's start sent the
        //    reader back a page on every open. An offset outside the sentence
        //    is from a different rendering of the text and is not trusted.
        //
        //    An offset *inside* it can be from a different rendering too: the
        //    renderer that stopped keeping the stray space at the start of every
        //    paragraph moved every character one place per paragraph above it,
        //    and a place a few characters out still falls inside a long
        //    sentence — or, a few characters further, just past its end, where
        //    it was set aside for the sentence's start, a page back. So the
        //    words recorded at the place, when there are any, are looked for in
        //    the sentence first, and say where in it the place is now. Only when
        //    they are not there does the offset refine the sentence as before.
        //    A position this app writes names the first sentence *beginning* on
        //    its page, and quotes from the page's top, before that sentence: its
        //    words are not inside it, and it lands on the sentence's start as it
        //    always did.
        val fragment = locator.sentenceId
        val range = fragment?.let { fragmentRanges[it] }
        if (range != null) {
            val offset = locator.locations?.charOffset
            val quote = locator.text?.highlight
            if (quote != null) {
                val found = nearestOccurrence(
                    quote, text, near = offset ?: range.location, before = locator.text?.before, startingWithin = range,
                )
                if (found != null) return found.location
            }
            if (offset != null && offset > range.location && offset < range.end && offset < length) return offset
            return range.location
        }

        // 2. The text that was on screen. Survives an id that changed, and is
        //    what re-anchors a position after the publisher revises a chapter.
        offsetOfQuotedText(locator, text)?.let { return it }

        // 3. The offset we recorded, if the chapter is still roughly that long.
        //    A wildly different length means a different revision of the file,
        //    where a raw index would point somewhere arbitrary.
        val recorded = locator.locations?.charOffset
        if (recorded != null && recorded >= 0 && recorded < length) return recorded

        // 4. Progression. Always available, never precise.
        return offset(locator.locations?.progression, length)
    }

    /**
     * The character a progression names in text of [length], or `null` when
     * the progression cannot name one.
     *
     * The value comes straight off the server, decoded as whatever `Double`
     * the JSON held, and the Swift arithmetic used to convert it to `Int`
     * *before* clamping: `Int(.nan)`, `Int(.infinity)` and
     * `Int(1e300 * length)` all trap, uncatchably, on every open of that book
     * until the position is overwritten from another device. Clamped first, and
     * refused when there is nothing finite to clamp.
     */
    fun offset(progression: Double?, length: Int): Int? {
        if (progression == null || !progression.isFinite() || length <= 0) return null
        val clamped = progression.asProgression ?: 0.0
        return minOf((length.toDouble() * clamped).toInt(), length - 1)
    }

    /**
     * Finds the remembered text again, preferring the occurrence nearest to
     * where the reader was.
     *
     * "Chapter One" and "said Alice" appear many times in a book; taking the
     * first match would throw the reader to the top of the chapter. The
     * recorded progression is a poor anchor on its own but a good tie-breaker.
     *
     * Through [nearestOccurrence], which a quote needs for the same reason a
     * highlight does: [quote] folds the chapter's newlines into spaces, and the
     * chapter it is searched for in still has them — so a quote taken across a
     * paragraph break, which is every quote taken in a paragraph shorter than
     * itself, never matched at all, and this rung failed in exactly the case it
     * exists for.
     */
    internal fun offsetOfQuotedText(locator: ReadiumLocator, text: String): Int? {
        val highlight = locator.text?.highlight?.trimmingWhitespaceAndNewlines() ?: return null
        if (clusterCount(highlight) < SHORT_EXCERPT_LENGTH) return null
        val expected = offset(locator.locations?.progression, text.length)
        return nearestOccurrence(highlight, text, near = expected, before = locator.text?.before)?.location
    }

    /**
     * Below this many characters a piece of remembered text is too common to
     * trust on its own: "the" is in every sentence, and inside "then",
     * "there" and "other" too.
     *
     * A reading position will not anchor on a quote this short at all. A
     * highlight has no choice — a single word is the smallest thing a reader
     * can select — so for one this short [nearestOccurrence] takes only whole
     * words, and asks the words that came before it which copy is the one.
     * Counted in grapheme clusters, as Swift's `String.count` counts.
     */
    const val SHORT_EXCERPT_LENGTH = 12

    /**
     * Where some remembered words are in the chapter now, nearest to where
     * they were.
     *
     * The one search behind both kinds of remembered text — a reading
     * position's quote and a highlight's excerpt — because both are stored the
     * same way and go stale the same way: written against one rendering of the
     * chapter, read back against another.
     *
     * - **Whitespace is matched by the run.** Both are stored with the
     *   chapter's newlines folded into spaces, so the words either side of a
     *   paragraph break never matched the chapter they came from. And text
     *   stored before the renderer stopped keeping the stray space at the start
     *   of every paragraph has two spaces where the chapter now has one
     *   newline. Any run of whitespace in the excerpt matches any run in the
     *   chapter, so all three meet.
     * - **A short excerpt is matched by whole words.** "the" must not be found
     *   inside "then"; past [SHORT_EXCERPT_LENGTH] a match inside a longer word
     *   is still preferred against, but allowed, because a page can begin with
     *   the second half of a word the layout hyphenated.
     * - **The words before it break ties.** [before] is the context stored
     *   alongside — `ReadiumLocator.Text.before`. Where several copies are
     *   found, the ones that follow the same words are preferred; then the one
     *   nearest [near].
     *
     * @param excerpt the remembered words.
     * @param text the chapter as rendered now.
     * @param near where they were, as a character offset into [text], when
     *   that is known.
     * @param before the text that preceded them when they were stored.
     * @param startingWithin when given, only an occurrence that *begins*
     *   inside it counts; it may run on past its end.
     * @return the range the words occupy now. Its length can differ from the
     *   excerpt's, because whitespace is matched by the run.
     */
    fun nearestOccurrence(
        excerpt: String,
        text: String,
        near: Int?,
        before: String? = null,
        startingWithin: TextRange? = null,
    ): TextRange? {
        if (text.isEmpty()) return null
        val pattern = ExcerptPattern.of(excerpt) ?: return null
        val whole = TextRange(0, text.length)
        val window = startingWithin?.intersection(whole) ?: whole
        if (window.length <= 0) return null
        val context = before?.let(::comparableContext)?.ifEmpty { null }
        // Lookbehind for the word test has to see the character before the
        // range it is handed, so the bounds are transparent.
        val matcher = pattern.expression.matcher(text).useTransparentBounds(true).useAnchoringBounds(false)

        // The ordinary case, and the one that has to stay cheap: nothing has
        // moved, and the words are still exactly where they were. One anchored
        // attempt rather than a scan of the chapter — this runs for every mark
        // in a chapter each time one loads. A short excerpt still has to be the
        // copy that follows the same words, or a stale offset that happens to
        // land on another "the" would be taken as exact.
        if (near != null && near >= window.location && near < window.end) {
            val start = skippingWhitespace(near, text, window.end)
            if (start < window.end) {
                matcher.region(start, text.length)
                if (matcher.lookingAt()) {
                    val hit = matcher.range()
                    if (!pattern.isShort || context?.let { follows(it, hit.location, text) } != false) return hit
                }
            }
        }

        val found = ArrayList<TextRange>()
        matcher.region(window.location, text.length)
        while (matcher.find()) {
            val range = matcher.range()
            if (range.location >= window.end) break
            found.add(range)
        }
        if (found.isEmpty()) return null

        // Whole words first. A short excerpt has already been held to them by
        // its pattern; a long one only prefers them.
        var candidates: List<TextRange> = found
        if (!pattern.isShort) {
            val wholeWords = candidates.filter { pattern.isWholeWords(it, text) }
            if (wholeWords.isNotEmpty()) candidates = wholeWords
        }
        // Then the copies that follow the same words, when there is more than
        // one to choose between and something to choose by. Where none do, the
        // text before the mark has changed rather than the mark, and every copy
        // stays in the running.
        if (candidates.size > 1 && context != null) {
            val following = candidates.filter { follows(context, it.location, text) }
            if (following.isNotEmpty()) candidates = following
        }
        if (near == null) return candidates.first()
        // Strictly nearer, so a tie goes to the earlier copy.
        return candidates.drop(1).fold(candidates[0]) { best, next ->
            if (abs(next.location - near) < abs(best.location - near)) next else best
        }
    }

    private fun Matcher.range(): TextRange = TextRange(start(), end() - start())

    /**
     * The remembered words as a pattern: each word escaped, and every run of
     * whitespace between them free to be any run of whitespace.
     */
    private class ExcerptPattern(
        val expression: Pattern,
        val isShort: Boolean,
        private val startsWithWord: Boolean,
        private val endsWithWord: Boolean,
    ) {
        /** Whether a match begins and ends on a word boundary, where the excerpt itself does. */
        fun isWholeWords(range: TextRange, text: String): Boolean {
            if (startsWithWord && range.location > 0 && isWordUnit(text[range.location - 1])) return false
            if (endsWithWord && range.end < text.length && isWordUnit(text[range.end])) return false
            return true
        }

        companion object {
            /**
             * `\s` is ICU's `[\t\n\f\r\p{Z}]`, which `NSRegularExpression`
             * uses; Java's is narrower, so it is spelled out, with the two
             * Swift also counts as whitespace, so the words split here are the
             * words the pattern separates.
             */
            const val WHITESPACE = "[\\t\\n\\f\\r\\p{Z}\\x{0B}\\x{85}]+"

            /** A letter or a digit either side of a match means it is inside a longer word. */
            const val WORD_CHARACTER = "[\\p{L}\\p{N}]"

            fun of(excerpt: String): ExcerptPattern? {
                val words = splitOnWhitespace(excerpt)
                if (words.isEmpty()) return null
                val first = words.first().codePointAt(0)
                val lastWord = words.last()
                val last = lastWord.codePointAt(lastClusterStart(lastWord))
                val isShort = clusterCount(words.joinToString(" ")) < SHORT_EXCERPT_LENGTH
                val startsWithWord = isWordScalar(first)
                val endsWithWord = isWordScalar(last)
                var pattern = words.joinToString(WHITESPACE) { Pattern.quote(it) }
                if (isShort) {
                    if (startsWithWord) pattern = "(?<!$WORD_CHARACTER)$pattern"
                    if (endsWithWord) pattern += "(?!$WORD_CHARACTER)"
                }
                val expression = try {
                    Pattern.compile(pattern)
                } catch (_: Exception) {
                    return null
                }
                return ExcerptPattern(expression, isShort, startsWithWord, endsWithWord)
            }

            /**
             * One UTF-16 unit is enough to tell: a surrogate half is never a
             * boundary, and treating it as a letter errs towards "inside a
             * word".
             */
            private fun isWordUnit(unit: Char): Boolean = unit.isSurrogate() || isWordScalar(unit.code)

            /** [WORD_CHARACTER], in code: a letter or a number, by general category. */
            private fun isWordScalar(codePoint: Int): Boolean = when (Character.getType(codePoint).toByte()) {
                Character.UPPERCASE_LETTER, Character.LOWERCASE_LETTER, Character.TITLECASE_LETTER,
                Character.MODIFIER_LETTER, Character.OTHER_LETTER, Character.DECIMAL_DIGIT_NUMBER,
                Character.LETTER_NUMBER, Character.OTHER_NUMBER,
                -> true
                else -> false
            }
        }
    }

    /**
     * Whether the text just before [location] ends with [context], once both
     * have had their whitespace runs folded to one space.
     */
    private fun follows(context: String, location: Int, text: String): Boolean {
        // Twice the context and some: folding only ever shortens, so a window
        // this size always holds enough of the chapter to compare.
        val start = clusterBoundary(text, location - minOf(location, context.length * 2 + 16))
        val preceding = text.substring(start, location)
        return hasClusterSuffix(comparableContext(preceding), context)
    }

    /**
     * Text reduced to what two renderings of it agree on: every run of
     * whitespace as one space, and none at either end — the context's own
     * first characters can be cut mid-run, and its last are the break before
     * the mark, which one rendering spells as a newline and another did not.
     */
    private fun comparableContext(text: String): String {
        val folded = StringBuilder(text.length)
        var inRun = false
        forEachCluster(text) { start, end ->
            if (isWhitespaceCluster(text, start)) {
                if (!inRun) folded.append(' ')
                inRun = true
            } else {
                folded.append(text, start, end)
                inRun = false
            }
        }
        // `trimmingCharacters(in: .whitespaces)`; every whitespace cluster is
        // a single space by now.
        return folded.toString().trim { it == ' ' }
    }

    /**
     * The first character at or after [offset] that is not whitespace: the
     * stored text was trimmed, so it begins there rather than at the offset.
     */
    private fun skippingWhitespace(offset: Int, text: String, end: Int): Int {
        var index = offset
        while (index < end && !text[index].isSurrogate() && isSwiftWhitespace(text[index].code)) index += 1
        return index
    }

    /**
     * The snippet to record for a position: enough text to be unambiguous,
     * little enough not to bloat every write.
     *
     * Newlines are collapsed because the stored copy is compared against a
     * re-render whose line breaks depend on the layout, not on the markup.
     */
    fun quote(text: String, offset: Int, length: Int = 64): ReadiumLocator.Text? {
        if (offset < 0 || offset >= text.length) return null
        // Cut at the edge of a character, not of a UTF-16 unit: a slice that
        // ends or begins inside an emoji stores a replacement character that
        // no render of the chapter contains, and the quote can never be found.
        val end = clusterBoundary(text, minOf(offset + length, text.length))
        val highlight = text.substring(offset, end).replace("\n", " ").trimmingWhitespaceAndNewlines()
        if (highlight.isEmpty()) return null

        val beforeStart = clusterBoundary(text, maxOf(0, offset - 32))
        val before = if (beforeStart < offset) text.substring(beforeStart, offset).replace("\n", " ") else null
        return ReadiumLocator.Text(before = before, highlight = highlight)
    }
}
