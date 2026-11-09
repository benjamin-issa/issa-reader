package com.benjaminissa.issareader.render

import com.benjaminissa.issareader.epub.EpubPackage
import com.benjaminissa.issareader.epub.EpubStyleSheet
import com.benjaminissa.issareader.epub.EpubXml
import com.benjaminissa.issareader.epub.EpubXmlNode

/**
 * Turns an EPUB chapter's XHTML into styled text, keeping every element id so
 * media-overlay fragments can later be located exactly. The Swift client's
 * `HTMLContentParser`, step for step.
 *
 * **Its string is shared with the Swift client, unit for unit.** A reading
 * position's `charOffset`, an Ask passage and a spoiler boundary are all UTF-16
 * offsets into it, so every rule below — which elements break a paragraph,
 * which whitespace collapses, which images take a place, what is trimmed — is
 * the Swift parser's, and `ParserParityTest` holds the two to the same strings
 * for every fixture book. A change here that would be harmless on one client
 * moves every saved position on the other.
 *
 * This is deliberately a scoped subset of HTML and CSS rather than a browser.
 * It covers what reflowable trade fiction actually uses — block and inline
 * flow, headings, emphasis, lists, blockquotes, breaks — and reports anything
 * beyond that so the caller can route the chapter to a web view instead.
 *
 * The CSS half is [EpubStyleSheet], and it is why a book's italics appear at
 * all: emphasis in a real trade ebook is very often a class rather than an
 * `<em>`, and so are the first-line indent and the justification that make a
 * page look like a page. What that subset will and will not read — and why it
 * will never read anything that changes *which characters* are rendered — is
 * written there.
 *
 * Not thread-safe: it holds an image loader whose plates cache, and a parse
 * happens on one thread at a time.
 *
 * @param maxImageWidth the column width images are scaled to fit.
 * @param maxImageHeight the page height images are scaled to fit; see
 *   [ImageAttachment.displaySize].
 * @param columnWidth what a percentage length resolves against — a
 *   `text-indent: 4.688%` is 4.688% of *this*. Named separately from
 *   [maxImageWidth] even though the reader passes the same number for both:
 *   they coincide because a picture is scaled to the column, not because they
 *   are the same quantity, and the callers that parse for search or for the Ask
 *   index pass neither.
 * @param loadImage given an archive path, the artwork: its size is read at
 *   once, its pixels only when drawn. Supplying it is what lets illustrations
 *   occupy real space and actually draw; without it, images are skipped and an
 *   illustrated chapter reads as empty. Results are expected to be cached by
 *   the caller — a chapter asks once per plate.
 * @param loadStyleSheet given an archive path, that sheet already parsed.
 *   Supplying it is what makes a book's own formatting appear; without it the
 *   chapter renders exactly as it did before there was a CSS reader. Expected
 *   to be cached by the caller — every chapter of a book links the same two or
 *   three sheets.
 *
 *   Deliberately **not** supplied by the Ask indexer or the in-book search,
 *   which parse the same chapters for their text. The rendered *string* must
 *   not depend on styling — every passage offset and spoiler boundary is
 *   measured in it — so the whitelist in [EpubStyleSheet] admits only
 *   properties that produce attributes, and `IndexOffsetTest` holds that
 *   invariant down.
 */
class ChapterParser(
    private val style: ReaderStyle,
    private val maxImageWidth: Double = 320.0,
    private val maxImageHeight: Double = Double.MAX_VALUE,
    private val columnWidth: Double = 320.0,
    private val loadImage: ((String) -> ChapterArtwork?)? = null,
    private val loadStyleSheet: ((String) -> EpubStyleSheet?)? = null,
) {
    /**
     * @throws com.benjaminissa.issareader.epub.EpubError.MalformedPackage when
     *   the chapter is not well-formed XML, even after its HTML entities are
     *   rewritten.
     */
    fun parse(xhtml: ByteArray, baseHref: String): StyledChapter {
        // A chapter is HTML its author wrote, and routinely says `&nbsp;` or
        // `&eacute;` — names XML does not define, which a strict parser treats
        // as fatal under the HTML5 DOCTYPE or none. `:epub` rewrites the whole
        // HTML 4.01 set to numeric references first; the Swift renderer used
        // to keep a table of its own that stopped forty-eight names short, and
        // a chapter using any of those (`&asymp;`, `&sum;`, the double arrows)
        // would not open, and dropped out of search and the Ask index.
        val root = EpubXml.parse(xhtml, substitutingHtmlEntities = true)

        val output = Output()
        val ranges = LinkedHashMap<String, TextRange>()
        val complexity = ComplexityTally()

        val body = root.firstDescendant("body") ?: root
        val context = Context(style = style, baseHref = baseHref, sheet = styleSheet(root, baseHref, loadStyleSheet))
        render(body, output, ranges, complexity, context)

        // Trimming the ends shifts every recorded range, so they move with it;
        // an off-by-one here misplaces every highlight in the chapter.
        val text = output.text.toString()
        val originalLength = text.length
        val end = trimmedEnd(text)
        val offset = leadingTrimOffset(text)
        val begin = minOf(offset, end)
        val trimmedLength = end - begin
        val adjusted: Map<String, TextRange> = if (offset == 0 && trimmedLength == originalLength) {
            ranges
        } else {
            val shifted = LinkedHashMap<String, TextRange>()
            for ((id, range) in ranges) {
                val location = range.location - offset
                if (location < 0 || location >= trimmedLength) continue
                shifted[id] = TextRange(location, minOf(range.length, trimmedLength - location))
            }
            shifted
        }

        val runs = ArrayList<StyleRun>(output.pieces.size)
        val plates = ArrayList<ChapterPlate>()
        for (piece in output.pieces) {
            val start = maxOf(piece.start, begin)
            val stop = minOf(piece.end, end)
            if (stop <= start) continue
            var plateIndex: Int? = null
            if (piece.plate != null) {
                plateIndex = plates.size
                plates.add(piece.plate.copy(offset = piece.plate.offset - begin))
            }
            runs.add(StyleRun(start - begin, stop - begin, piece.style, piece.fragmentId, plateIndex))
        }
        return StyledChapter(
            text = text.substring(begin, end),
            runs = runs,
            fragmentRanges = adjusted,
            plates = plates,
            complexity = complexity.value,
        )
    }

    // Rendering

    private data class Context(
        val style: ReaderStyle,
        /** Path of the document being parsed, so image srcs resolve correctly. */
        val baseHref: String,
        /** This document's cascade, empty when the caller supplied none. */
        val sheet: EpubStyleSheet,
        val bold: Boolean = false,
        val italic: Boolean = false,
        val sizeScale: Double = 1.0,
        /**
         * Set by `<h1>`–`<h6>` and by nothing else.
         *
         * The leading and paragraph-spacing rules below used to ask
         * `sizeScale > 1.2` instead, which meant the same thing only while
         * headings were the one thing that could change the size. A book's own
         * `font-size: 1.3em` on an ordinary paragraph would otherwise have
         * given it a heading's tight leading and a heading's gap beneath.
         */
        val isHeading: Boolean = false,
        val blockquoteDepth: Int = 0,
        val listDepth: Int = 0,
        val isPreformatted: Boolean = false,
        val alignment: TextAlignment? = null,
        /**
         * How far the book asked for the first line of a paragraph to be
         * pushed in, past whatever indent a blockquote or list already
         * applies. The request rather than a number of points: a percentage is
         * of the column, and the column changes when the window does — see
         * `ChapterLayout.reindent`.
         */
        val textIndent: EpubStyleSheet.Length? = null,
        val underlined: Boolean = false,
    )

    private class ComplexityTally {
        var value = ChapterComplexity()
    }

    private fun render(
        node: EpubXmlNode,
        output: Output,
        ranges: MutableMap<String, TextRange>,
        complexity: ComplexityTally,
        context: Context,
    ) {
        val start = output.length
        var child = context

        when (node.name.lowercase()) {
            "script", "style", "head", "title" -> {
                // Recorded before the return, not after it. The Swift
                // client's only assignment to `hasScripting` once sat forty
                // lines below this early exit and was therefore unreachable,
                // so the flag was permanently false and `requiresWebView`
                // never fired: a chapter carrying <script> was silently
                // linearised by the native path instead of being routed to a
                // web view, and its interactive content dropped with no
                // fallback.
                if (node.name.lowercase() == "script") complexity.value = complexity.value.copy(hasScripting = true)
                return
            }
            "b", "strong" -> child = child.copy(bold = true)
            "i", "em", "cite", "dfn" -> child = child.copy(italic = true)
            "h1" -> child = child.copy(bold = true, sizeScale = 1.9, isHeading = true)
            "h2" -> child = child.copy(bold = true, sizeScale = 1.6, isHeading = true)
            "h3" -> child = child.copy(bold = true, sizeScale = 1.35, isHeading = true)
            "h4", "h5", "h6" -> child = child.copy(bold = true, sizeScale = 1.15, isHeading = true)
            "blockquote" -> child = child.copy(blockquoteDepth = child.blockquoteDepth + 1)
            "ul", "ol" -> child = child.copy(listDepth = child.listDepth + 1)
            "pre", "code" -> child = child.copy(isPreformatted = true)

            "br" -> {
                output.append("\n", attributes(context))
                return
            }

            "img", "image" -> {
                complexity.value = complexity.value.copy(imageCount = complexity.value.imageCount + 1)
                appendImage(node, output, child)
                // Not a bare `return`: an id on the image itself — a contents
                // entry's `#plate-3`, a hand-made overlay's `<par>` — is as
                // much a place in the chapter as one on a sentence, and
                // returning before the bookkeeping below left it pointing
                // nowhere.
                recordFragment(node, start, output, ranges)
                return
            }

            "svg" -> {
                // The standard EPUB cover is an <svg> wrapping a raster
                // <image>, so this must descend rather than bail — bailing is
                // what made every Gutenberg book open on a blank page. Genuine
                // vector drawing is counted as complexity; a bare raster
                // wrapper is not.
                if (containsVectorDrawing(node)) complexity.value = complexity.value.copy(hasVectorArt = true)
            }

            "table" -> complexity.value = complexity.value.copy(hasTables = true)
            "video", "audio", "iframe", "object", "embed" ->
                complexity.value = complexity.value.copy(hasEmbeddedMedia = true)
        }

        // What the book's own stylesheet says about this element, applied over
        // the tag's meaning rather than under it: an author's rule beats the
        // browser's default for the same element, which is what `<em>` and
        // `<strong>` amount to here. An `<em>` *inside* a class-styled
        // paragraph is unaffected — the class is the paragraph's, and the
        // emphasis is inherited down to it through `child`.
        //
        // An inline `style=` counts on its own. Asking only whether the sheet
        // had rules made identical markup render styled in one book and plain
        // in another, depending on whether anything unrelated in its CSS
        // happened to parse — and the books formatted chiefly by `style=`
        // (word-processor conversions) are the ones whose sheets say least.
        if (!context.sheet.isEmpty || node["style"] != null) {
            val asked = context.sheet.declarations(
                tag = node.name, classes = node["class"], identifier = node["id"], inlineStyle = node["style"],
            )
            asked.italic?.let { child = child.copy(italic = it) }
            asked.bold?.let { child = child.copy(bold = it) }
            asked.underlined?.let { child = child.copy(underlined = it) }
            asked.fontScale?.let { scale ->
                // Relative to the parent, replacing the tag's own size rather
                // than compounding with it: `h1 {font-size: 1.3em}` is a
                // smaller heading, not a 2.5x one.
                //
                // Bounded, because `em` does compound through nesting — two
                // nested `2em`s are already four — and a line taller than the
                // page cannot be paged through. That is the same reason
                // `maxImageHeight` bounds a plate: content drawn outside the
                // canvas is content the reader can never reach.
                child = child.copy(sizeScale = minOf(context.sizeScale * scale, MAXIMUM_FONT_SCALE))
            }
            asked.alignment?.let { child = child.copy(alignment = alignment(it, context.style.justification)) }
            asked.textIndent?.let { child = child.copy(textIndent = it) }
        }

        // Text content of this element, before descending. `child`, not
        // `context`: a <pre>'s own preformatted flag was set on `child` just
        // above, and reading the incoming context collapsed the very text the
        // element exists to preserve — nested <pre><code> worked while a bare
        // <pre> (Gutenberg's poetry markup) lost every line break.
        if (node.text.isNotEmpty()) append(node.text, output, child)

        for (sub in node.children) {
            render(sub, output, ranges, complexity, child)
            // Text following a child element belongs to this element.
            if (sub.tail.isNotEmpty()) append(sub.tail, output, child)
        }

        if (isBlock(node.name)) appendParagraphBreak(output, child)

        recordFragment(node, start, output, ranges)
    }

    /**
     * Records the range an element occupies, so a SMIL fragment id maps to
     * exact characters.
     *
     * The id is applied only where none is set yet. Children are rendered
     * first, so this keeps the innermost id — which is the one the media
     * overlay references. Overwriting blindly would let an outer wrapper's id
     * replace every sentence span inside it, and the highlight would then
     * cover a whole chapter instead of one sentence.
     */
    private fun recordFragment(node: EpubXmlNode, start: Int, output: Output, ranges: MutableMap<String, TextRange>) {
        val id = node["id"] ?: return
        if (output.length <= start) return
        ranges[id] = TextRange(start, output.length - start)
        output.claim(start, id)
    }

    /**
     * Reserves space for an illustration and records where to draw it.
     *
     * A U+FFFC object-replacement character takes the plate's place in the
     * flow, and the line break after it gives the plate a paragraph of its
     * own; both carry the plate's paragraph attributes. `imageHref` only names
     * where it came from.
     */
    private fun appendImage(node: EpubXmlNode, output: Output, context: Context) {
        val src = node["src"] ?: node["href"] ?: return
        if (src.isEmpty()) return
        val href = EpubPackage.resolve(src, relativeTo = context.baseHref)
        val image = loadImage?.invoke(href) ?: return
        val width = image.layoutWidth
        val height = image.layoutHeight
        if (!(width > 0) || !(height > 0)) return

        val display = ImageAttachment.displaySize(width, height, maxImageWidth, maxImageHeight)

        // Alt text is the only thing a reader using TalkBack gets from a
        // picture. Dropping it at parse time left an object-replacement
        // character that no screen reader can say, and a full-page plate became
        // a page with one unspeakable glyph on it.
        val alt = (node["alt"] ?: node["title"])?.trimmingWhitespaceAndNewlines()?.ifEmpty { null }

        val base = attributes(context)
        // Centre the illustration in the column and give it room to breathe.
        // A plate is centred with no indent of its own, so it must not be
        // re-indented when the column changes either.
        val plateStyle = base.copy(
            paragraph = base.paragraph.copy(
                alignment = TextAlignment.CENTER,
                firstLineHeadIndent = 0.0,
                headIndent = 0.0,
                paragraphSpacing = style.fontSize,
                paragraphSpacingBefore = style.fontSize,
            ),
            indentFraction = null,
            indentPoints = null,
            imageHref = href,
            imageAlt = alt,
        )
        val plate = ChapterPlate(
            offset = output.length, href = href,
            displayWidth = display.width, displayHeight = display.height,
            artwork = image, alt = alt,
        )
        output.append(OBJECT_REPLACEMENT, plateStyle, plate)
        output.append("\n", plateStyle)
    }

    /**
     * Appends character data, minus the whitespace that is only indentation.
     *
     * Source markup is pretty-printed, so `</p>\n<p>` puts a newline between
     * two blocks. HTML collapses that to a space, and as inline content it is
     * a space — but between two *blocks* it is nothing at all, and appending it
     * opened every paragraph after the first with a stray space.
     *
     * Which was not merely untidy. The layout takes a paragraph's whole style
     * from its **first character**, and that character was this space,
     * carrying the enclosing element's attributes rather than the paragraph's
     * — so a `<p>`'s own alignment or first-line indent was computed correctly
     * and then ignored, and a blockquote's first line lost its indent whenever
     * the source had a newline before it.
     */
    private fun append(text: String, output: Output, context: Context) {
        if (context.isPreformatted) {
            output.append(text, attributes(context))
            return
        }
        var collapsed = collapseWhitespace(text)
        // Only at the start of a block. A lone space between two inline
        // elements is real, and dropping that one would run two words together.
        //
        // Ordinary spaces only: `collapseWhitespace` deliberately spares the
        // no-break space and its relatives, and a book that opens a line with
        // one is asking for it.
        if (output.length == 0 || output.endsWith("\n")) collapsed = dropLeadingSpaces(collapsed)
        if (collapsed.isEmpty()) return
        output.append(collapsed, attributes(context))
    }

    private fun appendParagraphBreak(output: Output, context: Context) {
        if (output.length == 0) return
        // Never stack more than one blank line, however deeply nested.
        if (output.endsWith("\n\n")) return
        output.append("\n", attributes(context))
    }

    private fun attributes(context: Context): RunStyle {
        // Large type needs proportionally less leading; applying the body
        // multiple to a 1.9x heading leaves it floating in whitespace.
        val leadingScale = if (context.isHeading) 0.82 else 1.0
        // The book's own alignment, where it asked for one and the reader has
        // not overruled it; see `alignment`.
        val alignment = context.alignment
            ?: if (context.style.justification == ReaderStyle.Justification.ALWAYS) TextAlignment.JUSTIFIED else TextAlignment.NATURAL
        val fontSize = context.style.fontSize
        val indent = (context.blockquoteDepth + context.listDepth).toDouble() * fontSize * 1.2
        val requested = context.textIndent?.points(columnWidth, fontSize) ?: 0.0
        val paragraph = ParagraphAttributes(
            alignment = alignment,
            lineHeightMultiple = context.style.lineSpacing.multiple * leadingScale,
            // Hyphenation matters far more in a justified column; without it,
            // justified text opens rivers of whitespace.
            hyphenationFactor = if (alignment == TextAlignment.JUSTIFIED) 1.0 else 0.0,
            paragraphSpacing = fontSize * (if (context.isHeading) 0.55 else 0.30),
            headIndent = indent,
            // `firstLineHeadIndent` is measured from the column's edge, not
            // from `headIndent`, so a book's own indent is added to the quoting
            // indent rather than replacing it. Until a book could ask for one
            // these two were always equal, which is why no book had ever had an
            // indented first line.
            firstLineHeadIndent = indent + firstLineIndent(requested, columnWidth),
        )
        // What the indent was asked as, so a new column width can be honoured
        // without parsing the chapter again. A percentage is resolved afresh
        // against the new column; an `em` indent keeps its size but is bounded
        // again by the new column's half.
        val indentRequest = context.textIndent
        return RunStyle(
            bold = context.bold,
            italic = context.italic,
            sizeScale = context.sizeScale,
            isHeading = context.isHeading,
            blockquoteDepth = context.blockquoteDepth,
            listDepth = context.listDepth,
            isPreformatted = context.isPreformatted,
            underlined = context.underlined,
            textIndent = indentRequest,
            paragraph = paragraph,
            indentFraction = (indentRequest as? EpubStyleSheet.Length.Fraction)?.value
                ?.takeIf { it > 0 && it.isFinite() },
            indentPoints = if (indentRequest is EpubStyleSheet.Length.Ems && requested > 0 && requested.isFinite()) {
                requested
            } else {
                null
            },
        )
    }

    companion object {
        /** U+FFFC, which holds a plate's place in the text. */
        const val OBJECT_REPLACEMENT = "\uFFFC"

        /**
         * The rules in force for one document, in the order it links them.
         *
         * Document order, not manifest order: CSS breaks a tie between two
         * equally specific rules by which came last, and the manifest is
         * sorted by href. `<style>` in the document's own head comes after its
         * links, as a browser would have it.
         */
        fun styleSheet(root: EpubXmlNode, baseHref: String, load: ((String) -> EpubStyleSheet?)?): EpubStyleSheet {
            var sheet = EpubStyleSheet()
            val head = root.firstDescendant("head") ?: return sheet
            for (link in head.children("link")) {
                val relation = (link["rel"] ?: "").lowercase()
                val type = (link["type"] ?: "").lowercase()
                if (!("stylesheet" in relation || type == "text/css")) continue
                val href = link["href"]
                if (href.isNullOrEmpty()) continue
                val linked = load?.invoke(EpubPackage.resolve(href, relativeTo = baseHref)) ?: continue
                sheet = sheet.adding(linked)
            }
            for (block in head.children("style")) {
                val css = block.allText
                if (css.isNotEmpty()) sheet = sheet.adding(css)
            }
            return sheet
        }

        /**
         * What a book's `text-align` becomes, once the reader has had their say.
         *
         * Centring and ranging right are structure — an epigraph, a signature,
         * a chapter number — and no reading setting is about them, so they are
         * honoured whatever it says. Justification is the one the reader has an
         * opinion on, and `NEVER` is that opinion: the paragraph falls back to
         * the natural alignment rather than to the book's.
         */
        fun alignment(asked: EpubStyleSheet.Alignment, justification: ReaderStyle.Justification): TextAlignment =
            when (asked) {
                EpubStyleSheet.Alignment.CENTER -> TextAlignment.CENTER
                EpubStyleSheet.Alignment.RIGHT -> TextAlignment.RIGHT
                EpubStyleSheet.Alignment.LEFT ->
                    if (justification == ReaderStyle.Justification.ALWAYS) TextAlignment.JUSTIFIED else TextAlignment.LEFT
                // `NATURAL`, not "nothing to say", under `NEVER`: nothing to
                // say lets the paragraph inherit its parent's alignment, so a
                // justified paragraph inside a centred title page came out
                // centred line by line.
                EpubStyleSheet.Alignment.JUSTIFY ->
                    if (justification == ReaderStyle.Justification.NEVER) TextAlignment.NATURAL else TextAlignment.JUSTIFIED
            }

        /**
         * The first-line indent a paragraph is given, in points past any
         * quoting indent, for the indent it asked for.
         *
         * The one place this is decided, for the parse and for
         * `ChapterLayout.reindent` alike. Bounded at half the column because an
         * indent as wide as the column pushes the paragraph's whole first line
         * into a zero-width fragment at the right edge, where it is clipped —
         * `text-indent: 100%`, `25em` on a phone, or `1e400em`, which parses to
         * infinity. Never negative: a hanging indent draws outside the column
         * and is clipped too.
         */
        fun firstLineIndent(requested: Double, columnWidth: Double): Double {
            if (!requested.isFinite() || !(requested > 0)) return 0.0
            val half = if (columnWidth.isFinite()) maxOf(columnWidth, 0.0) / 2 else 0.0
            return minOf(requested, half)
        }

        /**
         * Whether an `<svg>` actually draws vectors, as opposed to merely
         * wrapping a bitmap the way cover pages do.
         */
        fun containsVectorDrawing(node: EpubXmlNode): Boolean {
            if (node.name.lowercase() in vectorDrawing) return true
            return node.children.any { containsVectorDrawing(it) }
        }

        private val vectorDrawing = setOf(
            "path", "rect", "circle", "ellipse", "line", "polyline", "polygon", "text", "use",
        )

        /**
         * The largest a book may make its own text, as a multiple of the
         * reader's chosen size. Above `<h1>`'s 1.9 with room to spare, and far
         * below the point where one line fills a page.
         */
        const val MAXIMUM_FONT_SCALE = 3.0

        private val blockElements = setOf(
            "p", "div", "section", "article", "h1", "h2", "h3", "h4", "h5", "h6",
            "blockquote", "li", "ul", "ol", "figure", "figcaption", "header",
            "footer", "main", "aside", "hr", "table", "tr", "dd", "dt", "dl",
        )

        fun isBlock(name: String): Boolean = name.lowercase() in blockElements

        /**
         * HTML collapses runs of whitespace to a single space; preserving them
         * verbatim produces visible gaps where the source was merely indented.
         *
         * Non-breaking spaces are deliberately exempt. Swift's
         * `Character.isWhitespace` is true for U+00A0, so a naive collapse
         * silently rewrites every `&nbsp;` into an ordinary space — losing
         * exactly the line-breaking behaviour the author asked for, in places
         * like "Chapter 1" or "10 km" where a break would read badly.
         *
         * Walked by grapheme cluster, because the Swift one walks `Character`s:
         * a cluster is whitespace when its *first scalar* has Unicode's
         * White_Space property ([isSwiftWhitespace]), and the whole cluster
         * becomes one space — so a space carrying a combining mark collapses
         * with its mark, and CR LF is one break, not two. The exemption
         * compares whole clusters, so a no-break space carrying a mark is not
         * exempt. Kotlin's `Char.isWhitespace` would be wrong twice over: it
         * leaves out U+00A0, U+2007 and U+202F and takes in U+001C–U+001F.
         */
        fun collapseWhitespace(text: String): String {
            val result = StringBuilder(text.length)
            var lastWasSpace = false
            forEachCluster(text) { start, end ->
                val first = text.codePointAt(start)
                val exempt = end - start == 1 && text[start] in nonCollapsing
                if (isSwiftWhitespace(first) && !exempt) {
                    if (!lastWasSpace) result.append(' ')
                    lastWasSpace = true
                } else {
                    result.append(text, start, end)
                    lastWasSpace = false
                }
            }
            return result.toString()
        }

        /** Whitespace that carries meaning and must survive collapsing. */
        private val nonCollapsing = setOf(
            '\u00A0', // no-break space
            '\u202F', // narrow no-break space
            '\u2007', // figure space
            '\u2060', // word joiner
        )

        /**
         * `String(collapsed.drop(while: { $0 == " " }))`: leading clusters that
         * are exactly one space. Re-clustered here rather than reusing the
         * source's clusters, because collapsing can bring a space and a
         * following mark together into one cluster that is no longer a space.
         */
        internal fun dropLeadingSpaces(text: String): String {
            var cut = 0
            forEachClusterWhile(text) { start, end ->
                if (end - start == 1 && text[start] == ' ') {
                    cut = end
                    true
                } else {
                    false
                }
            }
            return if (cut == 0) text else text.substring(cut)
        }

        /** The four UTF-16 units the final trim removes: newline, space, tab and carriage return. */
        private fun isTrimmable(unit: Char): Boolean = unit == '\n' || unit == ' ' || unit == '\t' || unit == '\r'

        /** How many units the final trim removes from the front. */
        fun leadingTrimOffset(text: CharSequence): Int {
            var begin = 0
            while (begin < text.length && isTrimmable(text[begin])) begin += 1
            return begin
        }

        /**
         * Where the text ends once trailing whitespace is trimmed.
         *
         * Source markup routinely puts a newline between `<body>` and the
         * first block, which would otherwise open every chapter on a stray
         * space and shift every recorded fragment range by one; the end is
         * trimmed for the same reason.
         */
        fun trimmedEnd(text: CharSequence): Int {
            var end = text.length
            while (end > 0 && isTrimmable(text[end - 1])) end -= 1
            return end
        }
    }

    /**
     * The attributed string being built: text, and its runs in order.
     *
     * An `NSMutableAttributedString` in miniature. A run's fragment id can be
     * claimed after it is appended — an element's id is recorded once its
     * children are — and only where no inner element has claimed it first.
     */
    private class Output {
        val text = StringBuilder()
        val pieces = ArrayList<Piece>()

        val length: Int get() = text.length

        fun endsWith(suffix: String): Boolean {
            if (text.length < suffix.length) return false
            for (index in suffix.indices) {
                if (text[text.length - suffix.length + index] != suffix[index]) return false
            }
            return true
        }

        fun append(string: String, style: RunStyle, plate: ChapterPlate? = null) {
            if (string.isEmpty()) return
            val start = text.length
            text.append(string)
            val last = pieces.lastOrNull()
            // Coalesced as an attributed string coalesces equal attributes;
            // a plate always has a run of its own.
            if (plate == null && last != null && last.plate == null && last.fragmentId == null &&
                last.end == start && last.style == style
            ) {
                last.end = text.length
            } else {
                pieces.add(Piece(start, text.length, style, plate = plate))
            }
        }

        /**
         * Gives every unclaimed character from [start] to the end the id
         * [id]. Collected first, then applied, as the Swift side must: the
         * runs before [start] are untouched, and a run straddling it is split.
         */
        fun claim(start: Int, id: String) {
            // The first piece reaching past `start`, found from the end: the
            // element being closed is the most recent text.
            var index = pieces.size
            while (index > 0 && pieces[index - 1].end > start) index -= 1
            if (index < pieces.size) {
                val first = pieces[index]
                if (first.start < start && first.fragmentId == null) {
                    // Split so the part before the element keeps no id.
                    pieces.add(index + 1, Piece(start, first.end, first.style, first.fragmentId, first.plate))
                    first.end = start
                    index += 1
                }
            }
            for (position in index until pieces.size) {
                val piece = pieces[position]
                if (piece.fragmentId == null) piece.fragmentId = id
            }
        }
    }

    private class Piece(
        val start: Int,
        var end: Int,
        val style: RunStyle,
        var fragmentId: String? = null,
        val plate: ChapterPlate? = null,
    )
}
