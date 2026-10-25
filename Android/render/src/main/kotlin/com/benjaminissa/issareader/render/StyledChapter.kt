package com.benjaminissa.issareader.render

import com.benjaminissa.issareader.epub.EpubStyleSheet

/**
 * One chapter as [ChapterParser] renders it: the string, and what each part of
 * it should look like.
 *
 * The string is the contract. A reading position's `charOffset` is a UTF-16
 * index into [text], and so is every Ask passage and spoiler boundary; the
 * Swift client builds the same string from the same markup, unit for unit, so
 * a position saved on one device lands on the same sentence on the other.
 * Nothing here that is about looks — fonts, sizes, colours — can change a
 * character of it: the runs only describe the characters, and the fonts are
 * applied later, by `:render-android`.
 */
data class StyledChapter(
    val text: String,
    /**
     * Ordered, contiguous and covering [text] exactly: the attribute runs of
     * the Swift client's `NSAttributedString`.
     */
    val runs: List<StyleRun>,
    /**
     * Fragment id to its character range in [text]. This is what makes
     * highlighting a shape draw rather than a DOM query.
     */
    val fragmentRanges: Map<String, TextRange>,
    /** Every illustration that took a place in the text, in order. */
    val plates: List<ChapterPlate>,
    /** Structure this parser could not represent faithfully. */
    val complexity: ChapterComplexity,
) {
    /** The run holding the character at [index], or `null` past the end. */
    fun runAt(index: Int): StyleRun? {
        if (index < 0 || index >= text.length) return null
        var low = 0
        var high = runs.size - 1
        while (low <= high) {
            val middle = (low + high) ushr 1
            val run = runs[middle]
            when {
                index < run.start -> high = middle - 1
                index >= run.end -> low = middle + 1
                else -> return run
            }
        }
        return null
    }

    /**
     * The innermost element id over the character at [index]: the Swift
     * client's `.issaFragmentID` attribute.
     */
    fun fragmentIdAt(index: Int): String? = runAt(index)?.fragmentId

    /**
     * The book's first-line indents resolved again for a new column width.
     *
     * A `text-indent: 4.688%` is a fraction of the column, and the parser can
     * only resolve it against the column it was given. A resize — rotation, a
     * split-screen drag, a desktop window — only lays the chapter out again;
     * it does not parse it again. So every paragraph kept an indent sized for
     * the old column until the next chapter, when it jumped. The parser tags
     * each run with what was asked ([RunStyle.indentFraction],
     * [RunStyle.indentPoints]), and this applies it in place, the way a new
     * ink is applied: one attribute, the same characters.
     * [ChapterParser.firstLineIndent] decides the number for both, so the
     * bound on an over-wide indent holds at every width.
     *
     * Returns `this` when nothing moves, which is every layout of a chapter at
     * the width it was parsed for.
     */
    fun reindented(columnWidth: Double): StyledChapter {
        var changed = false
        val edited = runs.map { run ->
            val style = run.style
            val requested = style.indentFraction?.let { columnWidth * it } ?: style.indentPoints ?: return@map run
            val first = style.paragraph.headIndent + ChapterParser.firstLineIndent(requested, columnWidth)
            if (first == style.paragraph.firstLineHeadIndent) return@map run
            changed = true
            run.copy(style = style.copy(paragraph = style.paragraph.copy(firstLineHeadIndent = first)))
        }
        return if (changed) copy(runs = edited) else this
    }
}

/**
 * The attributes of one stretch of the chapter's text, where the Swift client
 * keeps an `NSAttributedString` run.
 */
data class StyleRun(
    /** First UTF-16 unit, inclusive. */
    val start: Int,
    /** One past the last unit. */
    val end: Int,
    val style: RunStyle,
    /**
     * The innermost element id over these characters — the one a media
     * overlay references. See [ChapterParser] on why innermost.
     */
    val fragmentId: String? = null,
    /** Index into [StyledChapter.plates] for an illustration's U+FFFC. */
    val plateIndex: Int? = null,
) {
    val length: Int get() = end - start
    val range: TextRange get() = TextRange(start, end - start)
}

/**
 * What the markup said about some text, and the paragraph attributes the
 * Swift parser computes from it: `HTMLContentParser.attributes(for:)`, as a
 * value.
 *
 * Both halves are kept. The flags are what the font is chosen from, later and
 * per platform; the resolved paragraph numbers are what TextKit was handed, so
 * the Android layout is given the same ones rather than a second derivation of
 * them.
 */
data class RunStyle(
    val bold: Boolean = false,
    val italic: Boolean = false,
    /** A multiple of the reader's size: a heading's, or the book's own `font-size`. */
    val sizeScale: Double = 1.0,
    /** Set by `<h1>`–`<h6>` and by nothing else. */
    val isHeading: Boolean = false,
    val blockquoteDepth: Int = 0,
    val listDepth: Int = 0,
    val isPreformatted: Boolean = false,
    val underlined: Boolean = false,
    /** The first-line indent the book asked for, as asked; see [ChapterParser.firstLineIndent]. */
    val textIndent: EpubStyleSheet.Length? = null,
    val paragraph: ParagraphAttributes,
    /**
     * A first-line indent the book asked for as a fraction of the column
     * (`text-indent: 5%` is 0.05), so a new column width can re-resolve it
     * without a re-parse. The Swift client's `.issaIndentFraction`.
     */
    val indentFraction: Double? = null,
    /**
     * A first-line indent the book asked for in `em`, resolved to points. It
     * does not grow with the column, but it is bounded by it, so a narrower one
     * bounds it again. The Swift client's `.issaIndentPoints`.
     */
    val indentPoints: Double? = null,
    /**
     * Archive path of an image occupying this run. A label, not what draws it:
     * the plate does that.
     */
    val imageHref: String? = null,
    /** An illustration's alternative text, kept so the page can be spoken. */
    val imageAlt: String? = null,
)

/** `NSParagraphStyle`, the fields the parser sets. Lengths in points. */
data class ParagraphAttributes(
    val alignment: TextAlignment,
    val lineHeightMultiple: Double,
    /** 1 where the paragraph is justified, 0 otherwise. */
    val hyphenationFactor: Double,
    /** Space after the paragraph. */
    val paragraphSpacing: Double,
    /** Space before it; only a plate asks for any. */
    val paragraphSpacingBefore: Double = 0.0,
    /** Every line's indent from the column's leading edge. */
    val headIndent: Double,
    /** The first line's, measured from the column's edge too — not from [headIndent]. */
    val firstLineHeadIndent: Double,
)

/** `NSTextAlignment`. [NATURAL] follows the paragraph's writing direction. */
enum class TextAlignment { NATURAL, LEFT, RIGHT, CENTER, JUSTIFIED }

/** One illustration in the flow: where its U+FFFC is, and the room it takes. */
data class ChapterPlate(
    /** The UTF-16 offset of its object-replacement character. */
    val offset: Int,
    /** Archive path it came from. */
    val href: String,
    /**
     * Scaled down to fit the column and the page, never up — see
     * [ChapterParser]; a narrower column at layout scales it again
     * ([ImageAttachment.bounds]).
     */
    val displayWidth: Double,
    val displayHeight: Double,
    val artwork: ChapterArtwork,
    val alt: String?,
)
