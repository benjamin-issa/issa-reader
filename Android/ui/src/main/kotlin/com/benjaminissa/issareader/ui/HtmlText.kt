package com.benjaminissa.issareader.ui

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withLink
import androidx.compose.ui.text.withStyle
import com.benjaminissa.issareader.core.model.HtmlEntities
import com.benjaminissa.issareader.core.networking.isWebLink
import java.net.URI

/**
 * Renders the small fragments of HTML a book's metadata carries.
 *
 * Deliberately not the EPUB parser. That one needs strict, single-root XHTML
 * and throws on the unclosed `<br>` and bare `&` that real publisher blurbs are
 * full of. This is a forgiving scanner: it understands a handful of tags,
 * ignores everything else rather than failing, and never throws — a
 * description that cannot be parsed is still worth showing as text.
 */
object HtmlText {
    /** One run of text and the inline emphasis it carries. */
    data class Run(val text: String, val bold: Boolean = false, val italic: Boolean = false, val link: String? = null)

    private data class Style(val bold: Boolean = false, val italic: Boolean = false, val link: String? = null)

    private sealed interface Piece {
        data class Text(val text: String, val style: Style) : Piece

        /**
         * `hard` gaps come from block tags and merge to the larger of the two;
         * soft ones come from `<br>` and add up, because two of them in a row
         * is how most scraped blurbs separate paragraphs.
         */
        data class Gap(val count: Int, val hard: Boolean) : Piece
    }

    /**
     * The fragment as styled runs. Block tags become paragraph breaks, `<br>` a
     * single newline, and runs of whitespace collapse the way a browser would —
     * server descriptions are routinely pretty-printed with newlines that are
     * not meant to be shown.
     */
    fun runs(html: String): List<Run> {
        // Scanned into pieces first, assembled second: trimming the space either
        // side of a paragraph break needs to see both neighbours.
        val pieces = mutableListOf<Piece>()
        val styles = mutableListOf(Style())
        val buffer = StringBuilder()
        fun flush() {
            val text = collapse(decodeEntities(buffer.toString()))
            buffer.setLength(0)
            if (text.isNotEmpty()) pieces += Piece.Text(text, styles.last())
        }

        var index = 0
        while (index < html.length) {
            if (html[index] == '<') {
                // A `<` with no matching `>` is literal text, not a broken tag.
                val close = html.indexOf('>', index)
                if (close < 0) {
                    buffer.append(html, index, html.length)
                    break
                }
                flush()
                val (breaks, hard) = apply(html.substring(index + 1, close), styles)
                if (breaks > 0) pieces += Piece.Gap(breaks, hard)
                index = close + 1
            } else {
                buffer.append(html[index])
                index += 1
            }
        }
        flush()

        // Space against a block boundary is layout, not content.
        for (position in pieces.indices) {
            if (pieces[position] !is Piece.Gap) continue
            (pieces.getOrNull(position - 1) as? Piece.Text)?.let { pieces[position - 1] = it.copy(text = it.text.trimEnd(' ')) }
            (pieces.getOrNull(position + 1) as? Piece.Text)?.let { pieces[position + 1] = it.copy(text = it.text.trimStart(' ')) }
        }

        val out = mutableListOf<Run>()
        var pendingGap = 0
        var wroteAnything = false
        for (piece in pieces) {
            when (piece) {
                is Piece.Gap -> if (wroteAnything) {
                    pendingGap = if (piece.hard) maxOf(pendingGap, piece.count) else pendingGap + piece.count
                }
                is Piece.Text -> {
                    val text = if (wroteAnything) piece.text else piece.text.trimStart(' ')
                    if (text.isEmpty()) continue
                    if (pendingGap > 0) {
                        out += Run("\n".repeat(minOf(pendingGap, 2)))
                        pendingGap = 0
                    }
                    out += Run(text, piece.style.bold, piece.style.italic, piece.style.link)
                    wroteAnything = true
                }
            }
        }
        // A trailing space left by the last run is equally not content.
        while (out.isNotEmpty() && out.last().text.endsWith(' ')) {
            val last = out.removeAt(out.lastIndex)
            val trimmed = last.text.trimEnd(' ')
            if (trimmed.isNotEmpty()) {
                out += last.copy(text = trimmed)
                break
            }
        }
        return out
    }

    /** Plain text, for the widget or an accessibility label. */
    fun plain(html: String): String = runs(html).joinToString("") { it.text }

    /**
     * Styled text for a `Text`: bold and italic as spans, links in [linkColor],
     * underlined and tappable. The face and size come from the `Text`'s own
     * style, as `Typography.body` does on the iPhone.
     */
    fun annotated(html: String, linkColor: Color): AnnotatedString = annotated(runs(html), linkColor)

    fun annotated(runs: List<Run>, linkColor: Color): AnnotatedString = buildAnnotatedString {
        for (run in runs) {
            val style = SpanStyle(
                fontWeight = if (run.bold) FontWeight.Bold else null,
                fontStyle = if (run.italic) FontStyle.Italic else null,
            )
            val link = run.link
            if (link != null) {
                withLink(LinkAnnotation.Url(link, TextLinkStyles(SpanStyle(color = linkColor, textDecoration = TextDecoration.Underline)))) {
                    withStyle(style) { append(run.text) }
                }
            } else {
                withStyle(style) { append(run.text) }
            }
        }
    }

    /**
     * The same parse, remembered. The book page recomposes on every debounced
     * position save — every two seconds while the book it shows is narrating —
     * and re-scanned the whole description each time. Keyed on the markup
     * itself, and bounded by dropping everything when full.
     */
    @Synchronized
    fun cached(html: String): List<Run> {
        cache[html]?.let { return it }
        val result = runs(html)
        if (cache.size >= CACHE_CAPACITY) cache.clear()
        cache[html] = result
        return result
    }

    private val cache = HashMap<String, List<Run>>()
    private const val CACHE_CAPACITY = 32

    /** Applies one tag to the style stack; returns the line breaks it asks for and whether they are hard. */
    private fun apply(raw: String, styles: MutableList<Style>): Pair<Int, Boolean> {
        val closing = raw.startsWith("/")
        val body = if (closing) raw.drop(1) else raw
        val name = body.takeWhile { !it.isWhitespace() && it != '/' }.lowercase()
        return when (name) {
            "b", "strong", "i", "em", "a" -> {
                if (closing) {
                    // Never pop the base style: stray closing tags are common.
                    if (styles.size > 1) styles.removeAt(styles.lastIndex)
                } else {
                    val current = styles.last()
                    val style = when (name) {
                        "b", "strong" -> current.copy(bold = true)
                        "i", "em" -> current.copy(italic = true)
                        else -> current.copy(link = href(body))
                    }
                    // A self-closing tag opens nothing.
                    if (!body.endsWith("/")) styles += style
                }
                0 to true
            }
            "br" -> 1 to false
            "p", "div", "ul", "ol", "li", "h1", "h2", "h3", "h4", "blockquote" -> (if (name == "li") 1 else 2) to true
            else -> 0 to true // Unknown tags are dropped, never rendered and never fatal.
        }
    }

    /**
     * The destination of an anchor, if it is one worth following. Descriptions
     * are scraped metadata, so the scheme is checked: a blurb must not be able
     * to hand the system a `javascript:` or `data:` URL to open.
     */
    private fun href(tag: String): String? {
        val value = attribute("href", tag) ?: return null
        // The value is markup too: `?a=1&amp;b=2` must not navigate to a
        // parameter literally named "amp;b".
        val decoded = decodeEntities(value).trim()
        val uri = runCatching { URI(decoded) }.getOrNull() ?: return null
        return if (uri.isWebLink) decoded else null
    }

    /**
     * Reads one attribute out of a tag body, matched as a whole attribute
     * name: searching for "href" anywhere found it inside `class="nohref"`.
     */
    internal fun attribute(name: String, tag: String): String? {
        var from = 0
        while (true) {
            val found = tag.indexOf(name, from, ignoreCase = true)
            if (found < 0) return null
            val before = tag.getOrNull(found - 1)
            var after = found + name.length
            while (after < tag.length && tag[after].isWhitespace()) after++
            // A real attribute is preceded by whitespace and followed by `=`.
            if ((before == null || before.isWhitespace()) && tag.getOrNull(after) == '=') {
                after++
                while (after < tag.length && tag[after].isWhitespace()) after++
                val quote = tag.getOrNull(after) ?: return null
                if (quote == '"' || quote == '\'') {
                    val end = tag.indexOf(quote, after + 1)
                    return if (end < 0) null else tag.substring(after + 1, end)
                }
                return tag.substring(after).takeWhile { !it.isWhitespace() && it != '>' }
            }
            from = found + name.length
        }
    }

    /**
     * Collapses runs of whitespace, the way a browser lays out HTML — except
     * the non-breaking spaces, which a browser collapses no more than it would
     * a letter: `Vol.&nbsp;II` must not become a space a line can break at.
     */
    private fun collapse(text: String): String {
        val out = StringBuilder(text.length)
        var lastWasSpace = false
        for (char in text) {
            val isSpace = char in WHITE_SPACE && char !in NON_BREAKING
            if (isSpace) {
                if (!lastWasSpace) out.append(' ')
            } else {
                out.append(char)
            }
            lastWasSpace = isSpace
        }
        return out.toString()
    }

    /** Unicode's White_Space property, as Swift's `Character.isWhitespace` reads it. */
    private val WHITE_SPACE: Set<Char> = buildSet {
        addAll(listOf('\u0009', '\u000A', '\u000B', '\u000C', '\u000D', ' ', '\u0085', ' ', ' '))
        for (c in 0x2000..0x200A) add(c.toChar())
        addAll(listOf(' ', ' ', ' ', ' ', '　'))
    }

    /** The spaces that mean "do not break here", which collapsing must keep. */
    private val NON_BREAKING = setOf(' ', ' ')

    /**
     * Decodes the entity forms that actually appear in book metadata. A bare
     * `&` is left exactly as it is — descriptions contain them unescaped, and
     * turning one into a parse failure loses the whole blurb.
     */
    internal fun decodeEntities(text: String): String {
        if ('&' !in text) return text
        val out = StringBuilder(text.length)
        var index = 0
        while (index < text.length) {
            val end = if (text[index] == '&') text.indexOf(';', index).takeIf { it in index until index + 12 } else null
            val decoded = end?.let { decode(text.substring(index + 1, it)) }
            if (end != null && decoded != null) {
                out.append(decoded)
                index = end + 1
            } else {
                out.append(text[index])
                index += 1
            }
        }
        return out.toString()
    }

    private fun decode(name: String): String? {
        if (name.startsWith("#")) {
            val digits = name.drop(1)
            val value = if (digits.startsWith("x") || digits.startsWith("X")) {
                digits.drop(1).toLongOrNull(16)
            } else {
                digits.toLongOrNull()
            }
            return value?.takeIf { it in 0..0x10FFFF && it !in 0xD800..0xDFFF }?.let { String(Character.toChars(it.toInt())) }
        }
        // All of HTML's names, case-sensitive as HTML is.
        HtmlEntities.character(name)?.let { return it }
        // `&AMP;` and `&QUOT;` are how some feeds write XML's five.
        val lower = name.lowercase()
        return if (lower in CASE_INSENSITIVE) HtmlEntities.character(lower) else null
    }

    private val CASE_INSENSITIVE = setOf("amp", "lt", "gt", "quot", "apos")
}
