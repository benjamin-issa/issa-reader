package com.benjaminissa.issareader.epub

/**
 * The part of a book's CSS a reading app can honour, and no more.
 *
 * **This is not a browser, and it must not become one.** It reads simple rules
 * off a stylesheet and answers one question: for this element, what did the
 * book ask for? Everything it cannot answer faithfully it declines to answer at
 * all, which is the only way a subset stays honest.
 *
 * It exists because emphasis in a real trade ebook is very often not `<em>`.
 * *The Nudge* — the book that prompted this — marks every italic passage as
 * `<p class="class_s5T-0">` against `.class_s5T-0 {font-style: italic}`, and a
 * renderer that reads no CSS renders the whole conversation upright. So do the
 * first-line indent and the justification that make a page look like a book:
 * they are one `text-indent` and one `text-align` on `body`'s own class.
 *
 * ### What it supports
 *
 * Selectors: `tag`, `.class`, `tag.class`, `#id`, `*`, and comma-separated
 * lists of those. A descendant combinator, an attribute selector, a
 * pseudo-class or a media query is **skipped**, not approximated — a rule
 * half-applied is worse than a rule ignored, because the reader cannot see
 * which half.
 *
 * Properties: the seven in [Declarations]. The cascade is specificity then
 * source order, and an element's own `style=` attribute beats all of it.
 *
 * ### What it will never support, and why
 *
 * - **`color`** — the page colour belongs to the reader. This book sets
 *   `#0000fe` on its links; on the night theme that is invisible.
 * - **`text-transform`**, **`display: none`**, **`content:`** — all three
 *   change *which characters* are rendered. Every SMIL fragment range, every
 *   Ask passage offset and every saved highlight is measured in those
 *   characters, so a stylesheet that could move them would make the read-along
 *   highlight and the reader's own notes land in the wrong place. Attributes
 *   only; never text.
 *
 * A value: [adding] returns a new sheet and leaves this one as it was, which is
 * what Swift's `mutating add` on a struct copy does — the renderer merges one
 * book-wide sheet into each document's without changing the book's.
 */
@ConsistentCopyVisibility
data class EpubStyleSheet internal constructor(internal val rules: List<Rule>) {
    constructor() : this(emptyList())

    /**
     * What a book asked for, where it asked for anything.
     *
     * Every field optional and inheritance left to the caller: the renderer
     * already threads a context down the element tree, and that context *is*
     * an inheritance chain. All of these inherit in CSS, so folding a non-null
     * value into the child context is the whole of the rule.
     */
    data class Declarations(
        val italic: Boolean? = null,
        val bold: Boolean? = null,
        val alignment: Alignment? = null,
        /**
         * A first-line indent, as a fraction of the column width or a multiple
         * of the font size; see [Length].
         */
        val textIndent: Length? = null,
        /**
         * A multiplier on the inherited size. Absolute units are deliberately
         * dropped — see [Length].
         */
        val fontScale: Double? = null,
        val underlined: Boolean? = null,
        /**
         * Families in declaration order, unquoted. Read by [EpubFontResolver],
         * not by the renderer, which is handed one resolved face.
         */
        val families: List<String>? = null,
    ) {
        /** `other` folded on top of this, later and more specific winning. */
        internal fun merging(other: Declarations) = Declarations(
            italic = other.italic ?: italic,
            bold = other.bold ?: bold,
            alignment = other.alignment ?: alignment,
            textIndent = other.textIndent ?: textIndent,
            fontScale = other.fontScale ?: fontScale,
            underlined = other.underlined ?: underlined,
            families = other.families ?: families,
        )

        val isEmpty: Boolean get() = this == Declarations()
    }

    enum class Alignment(val rawValue: String) {
        LEFT("left"),
        RIGHT("right"),
        CENTER("center"),
        JUSTIFY("justify"),
        ;

        companion object {
            fun of(rawValue: String): Alignment? = entries.firstOrNull { it.rawValue == rawValue }
        }
    }

    /**
     * A CSS length this reader can resolve without a layout engine.
     *
     * Percentages resolve against the column, `em`/`rem` against the text
     * size. Absolute units are not a case, because honouring `font-size: 11pt`
     * — what InDesign exports — would pin the page to the publisher's size and
     * silently disable the reader's own Text size control. A book may say how
     * much bigger; it may not say how big.
     */
    sealed interface Length {
        data class Fraction(val value: Double) : Length
        data class Ems(val value: Double) : Length

        fun points(columnWidth: Double, fontSize: Double): Double = when (this) {
            is Fraction -> columnWidth * value
            is Ems -> fontSize * value
        }
    }

    /**
     * One parsed rule. `order` is where it appeared across every sheet, which
     * is the tie-break when two selectors are equally specific.
     */
    internal data class Rule(val selector: Selector, val declarations: Declarations, val order: Int)

    /**
     * The shapes of selector this reader will match.
     *
     * Anything outside this list never becomes a `Selector`, so it can never
     * match — which is the intended behaviour, not a gap.
     */
    internal data class Selector(val tag: String? = null, val klass: String? = null, val identifier: String? = null) {
        /**
         * CSS specificity, flattened to one comparable number. Ids outrank
         * classes outrank tags, and nothing here can reach the next decade.
         */
        val specificity: Int
            get() = (if (identifier == null) 0 else 100) + (if (klass == null) 0 else 10) + (if (tag == null) 0 else 1)

        fun matches(tag: String, classes: Set<String>, identifier: String?): Boolean {
            if (this.tag != null && this.tag != tag) return false
            if (klass != null && klass !in classes) return false
            if (this.identifier != null && this.identifier != identifier) return false
            return true
        }
    }

    /**
     * This sheet with one more stylesheet read after it.
     *
     * Order matters and is the caller's to get right: sheets are added in the
     * order the *document* links them, because that is what CSS breaks ties by.
     */
    fun adding(css: String): EpubStyleSheet {
        val rules = ArrayList(this.rules)
        val text = stripComments(css)
        var index = 0
        while (true) {
            val open = text.indexOf('{', index)
            if (open < 0) break
            var selectors = text.substring(index, open)
            // A `;` out here ends a braceless at-rule — `@charset`, `@import`,
            // `@namespace` — and everything up to it belongs to that rule, not
            // to the selector after it. Left glued on, `@charset "UTF-8";
            // body` matched nothing and silently cost the sheet its body rule:
            // the reset `EpubFontResolver.blocks` already makes.
            val semicolon = selectors.lastIndexOf(';')
            if (semicolon >= 0) selectors = selectors.substring(semicolon + 1)
            val close = endOfBlock(text, open + 1) ?: break
            val body = text.substring(open + 1, close)
            // An at-rule — `@media`, `@supports`, `@font-face`, `@page`. Its
            // braces are skipped whole: a rule inside a media query is one this
            // reader cannot decide the truth of, and `@font-face` belongs to
            // `EpubFontResolver`, which reads the sheet for itself.
            if ('@' !in selectors) {
                val declarations = declarations(body)
                if (!declarations.isEmpty) {
                    for (selector in selectors(selectors)) {
                        rules.add(Rule(selector, declarations, order = rules.size))
                    }
                }
            }
            index = close + 1
        }
        return EpubStyleSheet(rules)
    }

    /**
     * This sheet with an already-parsed one after everything here.
     *
     * Sheets are parsed once per book and merged per document, so a chapter
     * pays for its cascade and not for the parsing of it.
     */
    fun adding(other: EpubStyleSheet): EpubStyleSheet {
        val base = rules.size
        return EpubStyleSheet(rules + other.rules.map { it.copy(order = base + it.order) })
    }

    /**
     * What this sheet says about one element.
     *
     * `inlineStyle` is the element's own `style=` attribute, which wins over
     * every rule regardless of specificity — as it does in a browser.
     */
    fun declarations(tag: String, classes: String?, identifier: String?, inlineStyle: String? = null): Declarations {
        val name = tag.lowercase()
        val classNames = (classes ?: "").swiftSplit { it.isSwiftWhitespace() }.map { it.lowercase() }.toSet()
        val id = identifier?.lowercase()

        var resolved = Declarations()
        for (rule in rules
            .filter { it.selector.matches(name, classNames, id) }
            .sortedWith(compareBy<Rule>({ it.selector.specificity }, { it.order }))
        ) {
            resolved = resolved.merging(rule.declarations)
        }
        if (!inlineStyle.isNullOrEmpty()) resolved = resolved.merging(declarations(inlineStyle))
        return resolved
    }

    val isEmpty: Boolean get() = rules.isEmpty()

    internal companion object {
        // Reading selectors

        fun selectors(list: String): List<Selector> = list.swiftSplit(',').mapNotNull { selector(it) }

        /** One selector, or `null` when it is outside the supported shapes. */
        fun selector(raw: String): Selector? {
            val text = raw.trimmingWhitespaceAndNewlines().lowercase()
            if (text.isEmpty()) return null
            // A combinator, a pseudo-class, an attribute selector: all mean the
            // rule applies to something this reader cannot identify, so it
            // matches nothing rather than matching too much.
            if (text.any { it == ' ' || it == '>' || it == '+' || it == '~' } ||
                ':' in text || '[' in text || '(' in text
            ) {
                return null
            }
            if (text == "*") return Selector()

            var tag: String? = null
            var klass: String? = null
            var identifier: String? = null
            val current = StringBuilder()
            var kind = ' '
            // Refusing a shape means refusing the *whole* selector, and
            // tracking that in a flag rather than by clearing a field. Clearing
            // was the bug: `div.a.b` dropped the second class and kept the tag,
            // so a rule meant for one kind of div silently applied to every div
            // in the book — precisely the half-applied rule this type exists not
            // to produce.
            var supported = true
            fun commit() {
                if (current.isEmpty()) {
                    // A separator with nothing after it — `p.`, `#` — is
                    // malformed, and it used to leave a bare tag behind that
                    // matched everything.
                    if (kind != ' ') supported = false
                    return
                }
                when (kind) {
                    '.' -> {
                        if (klass != null) supported = false
                        klass = current.toString()
                    }
                    '#' -> {
                        if (identifier != null) supported = false
                        identifier = current.toString()
                    }
                    else -> tag = current.toString()
                }
                current.setLength(0)
            }
            for (character in text) {
                if (character == '.' || character == '#') {
                    commit()
                    kind = character
                } else {
                    current.append(character)
                }
            }
            commit()
            if (!supported || (tag == null && klass == null && identifier == null)) return null
            return Selector(tag, klass, identifier)
        }

        /**
         * The end of a block opened at `from`, counting nested braces so an
         * `@media` wrapper is skipped whole rather than ending at its first
         * inner rule.
         */
        fun endOfBlock(text: String, from: Int): Int? {
            var depth = 0
            for (index in from until text.length) {
                val character = text[index]
                if (character == '{') depth += 1
                if (character == '}') {
                    if (depth == 0) return index
                    depth -= 1
                }
            }
            return null
        }

        // Reading declarations

        fun declarations(body: String): Declarations {
            var italic: Boolean? = null
            var bold: Boolean? = null
            var alignment: Alignment? = null
            var textIndent: Length? = null
            var fontScale: Double? = null
            var underlined: Boolean? = null
            var families: List<String>? = null
            for (statement in body.swiftSplit(';')) {
                val parts = statement.swiftSplit(':', maxSplits = 1)
                if (parts.size != 2) continue
                val property = parts[0].trimmingWhitespaceAndNewlines().lowercase()
                val value = withoutImportant(parts[1].trimmingWhitespaceAndNewlines().lowercase())
                if (value.isEmpty()) continue
                when (property) {
                    // `oblique` is a slanted roman where an italic is a
                    // different drawing, but a reader asking for one will accept
                    // the other, and the alternative is rendering the passage
                    // upright.
                    "font-style" -> italic = when {
                        value == "italic" || value.startsWith("oblique") -> true
                        value == "normal" -> false
                        else -> null
                    }
                    "font-weight" -> bold = isBold(value)
                    "text-align" -> alignment = Alignment.of(value) ?: when (value) {
                        "start" -> Alignment.LEFT
                        "end" -> Alignment.RIGHT
                        else -> null
                    }
                    "text-indent" -> textIndent = length(value)
                    // A non-positive size is refused rather than obeyed: a book
                    // asking for zero is asking for nothing renderable, and a
                    // page set in a zero-point font is blank with no setting a
                    // reader could use to get it back.
                    "font-size" -> fontScale = length(value)
                        ?.let {
                            when (it) {
                                is Length.Fraction -> it.value
                                is Length.Ems -> it.value
                            }
                        }
                        ?.takeIf { it > 0 }
                    "text-decoration", "text-decoration-line" -> underlined = when {
                        "underline" in value -> true
                        "none" in value -> false
                        else -> null
                    }
                    "font-family" -> {
                        val declared = value.swiftSplit(',')
                            .map { unquote(it.trimmingWhitespaceAndNewlines()) }
                            .filter { it.isNotEmpty() }
                        if (declared.isNotEmpty()) families = declared
                    }
                }
            }
            return Declarations(italic, bold, alignment, textIndent, fontScale, underlined, families)
        }

        /**
         * A lowercased value with any trailing `!important` taken off.
         *
         * Left on, it rode into every comparison below: `italic !important`
         * was neither `italic` nor `normal`, `1.5em !important` had no unit,
         * and the declaration read as no opinion at all — the shipped
         * upright-italics bug again, on any sheet that uses it. Its
         * *precedence* is not honoured; the declaration simply takes its place
         * in the ordinary cascade, which is right for every book seen so far
         * and far better than dropping it.
         */
        fun withoutImportant(value: String): String {
            val bang = value.lastIndexOf('!')
            if (bang < 0 || value.substring(bang + 1).trimmingWhitespaceAndNewlines() != "important") return value
            return value.substring(0, bang).trimmingWhitespaceAndNewlines()
        }

        /**
         * Whether a `font-weight` asks for a heavier face.
         *
         * 600 is where CSS puts semibold, and a reading face that has one
         * member heavier than regular answers to all of them.
         */
        fun isBold(value: String): Boolean? = when (value) {
            "bold", "bolder" -> true
            "normal", "lighter" -> false
            else -> swiftInt(value)?.let { it >= 600 }
        }

        /**
         * A length, in the two forms that can be resolved without a layout
         * engine.
         *
         * `pt`, `px`, `cm` and friends return `null` deliberately: see
         * [Length]. A zero is the exception, in any unit and any spelling:
         * `0pt` means the same as `0`, and reading it as no opinion left an
         * inherited `1.5em` indent on the very paragraph that was cancelling it.
         */
        fun length(value: String): Length? {
            val number = value.takeWhile { it.isSwiftNumber() || it == '.' || it == '-' || it == '+' }
            val unit = value.substring(number.length)
            val zero = swiftDouble(number)
            if (zero != null && zero == 0.0 && (unit.isEmpty() || unit in lengthUnits)) return Length.Fraction(0.0)
            if (value.endsWith("%")) return swiftDouble(value.dropLast(1))?.let { Length.Fraction(it / 100) }
            if (value.endsWith("rem")) return swiftDouble(value.dropLast(3))?.let { Length.Ems(it) }
            if (value.endsWith("em")) return swiftDouble(value.dropLast(2))?.let { Length.Ems(it) }
            return null
        }

        /** The CSS length units, for recognising a zero written in any of them. */
        val lengthUnits = setOf(
            "%", "em", "rem", "ex", "ch", "px", "pt", "pc", "in", "cm", "mm", "q",
            "vw", "vh", "vmin", "vmax",
        )

        // Shared text handling

        /**
         * Removes `/* … */`, which CSS permits anywhere. Left in, a comment
         * before a rule becomes part of its selector and a comment inside a
         * block corrupts the declaration it interrupts.
         */
        fun stripComments(css: String): String {
            val result = StringBuilder(css.length)
            var rest = 0
            while (true) {
                val open = css.indexOf("/*", rest)
                if (open < 0) break
                result.append(css, rest, open)
                val close = css.indexOf("*/", open + 2)
                // An unterminated comment swallows the rest of the sheet, which
                // is how a browser tokenises it.
                if (close < 0) return result.toString()
                rest = close + 2
            }
            result.append(css, rest, css.length)
            return result.toString()
        }

        fun unquote(text: String): String {
            var value = text.trimmingWhitespaceAndNewlines()
            for (quote in listOf("\"", "'")) {
                if (value.startsWith(quote) && value.endsWith(quote) && value.length > 1) {
                    value = value.substring(1, value.length - 1)
                }
            }
            return value
        }
    }
}
