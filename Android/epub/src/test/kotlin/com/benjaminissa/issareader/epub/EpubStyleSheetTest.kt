package com.benjaminissa.issareader.epub

import com.benjaminissa.issareader.epub.EpubStyleSheet.Alignment
import com.benjaminissa.issareader.epub.EpubStyleSheet.Length
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What a book's stylesheet asks for: the CSS subset, and its edges.
 *
 * The edges are the point: a reader that reads *some* CSS has to be exact
 * about which, because a rule half-applied is invisible to the person holding
 * the book. Every case here that expects nothing is as deliberate as the ones
 * that expect something. Ported from `EPUBStyleSheetTests.swift`.
 */
class EpubStyleSheetTest {
    private fun sheet(css: String): EpubStyleSheet = EpubStyleSheet().adding(css)

    @Test
    fun classItalic() {
        // The shipped bug, in one line: this is how a trade ebook marks a
        // passage of italic dialogue, and it is not <em>.
        val sheet = sheet(".class_s5T-0 {font-style: italic; margin-bottom: 0}")
        val found = sheet.declarations(tag = "p", classes = "class_s5T-0", identifier = null)
        assertEquals(true, found.italic)
    }

    @Test
    fun unrelatedClass() {
        val sheet = sheet(".italic {font-style: italic}")
        assertNull(sheet.declarations(tag = "p", classes = "roman", identifier = null).italic)
    }

    @Test
    fun severalClasses() {
        val sheet = sheet(".a {font-style: italic} .b {font-weight: bold}")
        val found = sheet.declarations(tag = "p", classes = "a b", identifier = null)
        assertEquals(true, found.italic)
        assertEquals(true, found.bold)
    }

    /** A class beats a tag, and an id beats a class. */
    @Test
    fun specificity() {
        val sheet = sheet(
            """
                #here {text-align: right}
                .quiet {text-align: center}
                p {text-align: left}
            """.trimIndent(),
        )
        assertEquals(Alignment.LEFT, sheet.declarations(tag = "p", classes = null, identifier = null).alignment)
        assertEquals(Alignment.CENTER, sheet.declarations(tag = "p", classes = "quiet", identifier = null).alignment)
        assertEquals(Alignment.RIGHT, sheet.declarations(tag = "p", classes = "quiet", identifier = "here").alignment)
    }

    /** Equally specific rules break the tie by order. */
    @Test
    fun sourceOrder() {
        val sheet = sheet(".a {font-style: italic} .a {font-style: normal}")
        assertEquals(false, sheet.declarations(tag = "p", classes = "a", identifier = null).italic)
    }

    /** The element's own style attribute beats every rule. */
    @Test
    fun inlineStyleWins() {
        val sheet = sheet("#loud {font-style: italic}")
        val found = sheet.declarations(tag = "p", classes = null, identifier = "loud", inlineStyle = "font-style: normal")
        assertEquals(false, found.italic)
    }

    /** `tag.class` matches only that tag carrying that class. */
    @Test
    fun tagAndClass() {
        val sheet = sheet("p.lead {font-weight: bold}")
        assertEquals(true, sheet.declarations(tag = "p", classes = "lead", identifier = null).bold)
        assertNull(sheet.declarations(tag = "div", classes = "lead", identifier = null).bold)
        assertNull(sheet.declarations(tag = "p", classes = null, identifier = null).bold)
    }

    @Test
    fun universal() {
        val sheet = sheet("* {text-align: justify}")
        assertEquals(Alignment.JUSTIFY, sheet.declarations(tag = "div", classes = null, identifier = null).alignment)
    }

    /**
     * A selector this reader cannot evaluate must match *nothing*. Matching the
     * last simple part of it instead — the obvious shortcut — would apply a rule
     * meant for a footnote to every paragraph in the chapter.
     */
    @Test
    fun unsupportedSelectors() {
        for (selector in listOf("div p", "div > p", "p + p", "p ~ p", "p:first-child", "p[data-x]", ".a.b")) {
            val sheet = sheet("$selector {font-style: italic}")
            assertNull("$selector should match nothing", sheet.declarations(tag = "p", classes = "a b", identifier = null).italic)
        }
    }

    /**
     * The bug this suite missed: refusing the second class used to clear the
     * class and keep the tag, so a rule written for one kind of paragraph
     * applied to every paragraph in the book.
     */
    @Test
    fun tagWithTwoClasses() {
        val sheet = sheet("div.a.b {font-style: italic}")
        assertNull(sheet.declarations(tag = "div", classes = "a b", identifier = null).italic)
        assertNull(sheet.declarations(tag = "div", classes = "zzz", identifier = null).italic)
        assertNull(sheet.declarations(tag = "div", classes = null, identifier = null).italic)
    }

    /** Two ids, or an id beside a second class, are refused the same way. */
    @Test
    fun otherRefusedShapes() {
        for (selector in listOf("p#a#b", "#x.a.b", "p.a.b", "span#one#two")) {
            val sheet = sheet("$selector {font-weight: bold}")
            assertNull("$selector should match nothing", sheet.declarations(tag = "p", classes = "a b", identifier = "x").bold)
            assertNull("$selector should match nothing", sheet.declarations(tag = "span", classes = null, identifier = "one").bold)
        }
    }

    /** A separator with nothing after it is malformed, not a bare tag. */
    @Test
    fun trailingSeparator() {
        assertNull(sheet("p. {font-style: italic}").declarations(tag = "p", classes = null, identifier = null).italic)
        assertNull(sheet("p# {font-style: italic}").declarations(tag = "p", classes = null, identifier = null).italic)
    }

    @Test
    fun stillSupported() {
        assertEquals(true, sheet("p {font-style: italic}").declarations(tag = "p", classes = null, identifier = null).italic)
        assertEquals(true, sheet(".a {font-style: italic}").declarations(tag = "p", classes = "a", identifier = null).italic)
        assertEquals(true, sheet("#a {font-style: italic}").declarations(tag = "p", classes = null, identifier = "a").italic)
        assertEquals(true, sheet("p.a {font-style: italic}").declarations(tag = "p", classes = "a", identifier = null).italic)
    }

    /** A page set in a zero-point font is blank, and no reader setting brings it back. */
    @Test
    fun nonPositiveSizes() {
        for (value in listOf("0", "-1em", "0%", "-50%")) {
            assertNull(
                "font-size: $value should be ignored",
                sheet("p {font-size: $value}").declarations(tag = "p", classes = null, identifier = null).fontScale,
            )
        }
        assertEquals(1.3, sheet("p {font-size: 1.3em}").declarations(tag = "p", classes = null, identifier = null).fontScale)
    }

    @Test
    fun mediaQuery() {
        // Skipped, not misread: the closing brace of the inner rule must not be
        // taken for the end of the block, or the next rule in the sheet is
        // parsed with "}" as part of its selector.
        val sheet = sheet(
            """
                @media (min-width: 40em) { p {font-style: italic} }
                .after {font-weight: bold}
            """.trimIndent(),
        )
        assertNull(sheet.declarations(tag = "p", classes = null, identifier = null).italic)
        assertEquals(true, sheet.declarations(tag = "p", classes = "after", identifier = null).bold)
    }

    @Test
    fun fontFaceIgnored() {
        val sheet = sheet(
            """
                @font-face {font-family: AGaramondPro; font-style: italic; src: url(r.otf)}
                p {font-style: normal}
            """.trimIndent(),
        )
        // The @font-face's `font-style: italic` describes the *file*, not the
        // text. Read as a rule it would set every page in italic.
        assertEquals(false, sheet.declarations(tag = "p", classes = null, identifier = null).italic)
    }

    @Test
    fun comments() {
        val sheet = sheet("/* the quiet ones */ .quiet {font-style: /* here */ italic}")
        assertEquals(true, sheet.declarations(tag = "p", classes = "quiet", identifier = null).italic)
    }

    /** Indents resolve as a fraction of the column or a multiple of the type. */
    @Test
    fun indentLengths() {
        val sheet = sheet(".a {text-indent: 4.688%} .b {text-indent: 1.5em} .c {text-indent: 0}")
        assertEquals(Length.Fraction(0.04688), sheet.declarations(tag = "p", classes = "a", identifier = null).textIndent)
        assertEquals(Length.Ems(1.5), sheet.declarations(tag = "p", classes = "b", identifier = null).textIndent)
        assertEquals(Length.Fraction(0.0), sheet.declarations(tag = "p", classes = "c", identifier = null).textIndent)
    }

    /**
     * Honouring `font-size: 11pt` would pin the page to the publisher's idea of
     * size and leave the reader's own Text size control doing nothing — on
     * every InDesign-exported book, which is most of them.
     */
    @Test
    fun onlyRelativeSizes() {
        val sheet = sheet(".pt {font-size: 11pt} .px {font-size: 16px} .em {font-size: 1.3em}")
        assertNull(sheet.declarations(tag = "p", classes = "pt", identifier = null).fontScale)
        assertNull(sheet.declarations(tag = "p", classes = "px", identifier = null).fontScale)
        assertEquals(1.3, sheet.declarations(tag = "p", classes = "em", identifier = null).fontScale)
    }

    /** A numeric weight is bold from semibold up. */
    @Test
    fun numericWeights() {
        assertEquals(true, EpubStyleSheet.isBold("700"))
        assertEquals(true, EpubStyleSheet.isBold("600"))
        assertEquals(false, EpubStyleSheet.isBold("500"))
        assertEquals(true, EpubStyleSheet.isBold("bold"))
        assertEquals(false, EpubStyleSheet.isBold("normal"))
        assertNull(EpubStyleSheet.isBold("inherit"))
    }

    /**
     * Colour and text-transform are never read. Both would change which
     * characters are rendered (or, for colour, whose page it is), and every
     * fragment range, passage offset and saved highlight is measured in those.
     */
    @Test
    fun refusedProperties() {
        val sheet = sheet(".a {color: #0000fe; text-transform: uppercase; font-style: italic}")
        val found = sheet.declarations(tag = "p", classes = "a", identifier = null)
        // Only the one property that can be honoured survives.
        assertEquals(true, found.italic)
        assertNull(found.alignment)
        assertNull(found.fontScale)
    }

    /** Underline is read, and turning it off is read too. */
    @Test
    fun decoration() {
        val sheet = sheet(".a {text-decoration: underline} .b {text-decoration: none}")
        assertEquals(true, sheet.declarations(tag = "a", classes = "a", identifier = null).underlined)
        assertEquals(false, sheet.declarations(tag = "a", classes = "b", identifier = null).underlined)
    }

    /** A family is read for the font resolver, quotes and all. */
    @Test
    fun families() {
        val sheet = sheet(".class-1 {font-family: \"AGaramond Pro\", serif}")
        assertEquals(
            listOf("agaramond pro", "serif"),
            sheet.declarations(tag = "body", classes = "class-1", identifier = null).families,
        )
    }

    /** A sheet with nothing this reader understands is empty. */
    @Test
    fun empty() {
        assertTrue(sheet("p {margin-top: 0; page-break-before: avoid}").isEmpty)
        assertTrue(EpubStyleSheet().isEmpty)
    }

    /** A truncated sheet does not hang or throw. */
    @Test
    fun truncated() {
        // Real books ship broken CSS, and an unterminated block must not spin.
        assertTrue(sheet(".a {font-style: italic").isEmpty)
        assertTrue(sheet("/* unterminated").isEmpty)
        assertFalse(sheet(".a {font-style: italic} .b {").isEmpty)
    }

    // Braceless at-rules

    /**
     * `@charset`, `@import` and `@namespace` end at a `;`, not a block. Their
     * text used to glue itself onto the next rule's selector, which then
     * matched nothing — one rule lost per run of them, and on the sheets every
     * Gutenberg book ships, the one lost is the `body` rule.
     */
    @Test
    fun charsetKeepsTheBodyRule() {
        val sheet = sheet(
            """
                @charset "UTF-8";
                body { text-align: justify; text-indent: 1.5em }
                p.x {font-style: italic}
            """.trimIndent(),
        )
        val body = sheet.declarations(tag = "body", classes = null, identifier = null)
        assertEquals(Alignment.JUSTIFY, body.alignment)
        assertEquals(Length.Ems(1.5), body.textIndent)
        assertEquals(true, sheet.declarations(tag = "p", classes = "x", identifier = null).italic)
    }

    @Test
    fun importAndNamespaceKeepTheirNeighbours() {
        assertEquals(
            true,
            sheet("@import url(x.css);\n.c {font-style: italic}").declarations(tag = "p", classes = "c", identifier = null).italic,
        )
        val sheet = sheet(
            """
                @namespace h "http://www.w3.org/1999/xhtml";
                @charset "utf-8";
                .c {font-style: italic}
                .e {font-weight: bold}
            """.trimIndent(),
        )
        assertEquals(true, sheet.declarations(tag = "p", classes = "c", identifier = null).italic)
        assertEquals(true, sheet.declarations(tag = "p", classes = "e", identifier = null).bold)
    }

    // Zero, whatever its unit

    /**
     * A zero is a zero in any unit. Only `0` and `0em` used to read as one, so
     * `p.first {text-indent: 0pt}` beneath `p {text-indent: 1.5em}` came back
     * null — and a null merges as "no opinion", leaving the 1.5em the book was
     * cancelling.
     */
    @Test
    fun zeroInAnyUnit() {
        for (zero in listOf("0pt", "0px", "0in", "0cm", "0.0", "0.00em", "-0", "0%", "0")) {
            val sheet = sheet("p {text-indent: 1.5em} p.first {text-indent: $zero}")
            assertEquals(
                "text-indent: $zero should cancel the indent",
                Length.Fraction(0.0),
                sheet.declarations(tag = "p", classes = "first", identifier = null).textIndent,
            )
        }
        // An absolute non-zero length is still refused, and a zero size is
        // still not a size.
        assertNull(sheet("p {text-indent: 12pt}").declarations(tag = "p", classes = null, identifier = null).textIndent)
        assertNull(sheet("p {font-size: 0pt}").declarations(tag = "p", classes = null, identifier = null).fontScale)
        assertEquals(Length.Ems(0.5), EpubStyleSheet.length("0.5em"))
        assertNull(EpubStyleSheet.length("0auto"))
    }

    // !important

    /**
     * `!important` used to ride along into the value, so `italic !important`
     * was neither `italic` nor `normal` and read as no opinion at all — the
     * shipped bug this type exists to fix, on any sheet that uses it.
     */
    @Test
    fun importantIsHonoured() {
        val sheet = sheet(
            """
                .a {font-style: italic !important}
                .b {text-align: justify!important}
                .c {font-weight: bold ! IMPORTANT}
                .d {text-indent: 1.5em !important}
                .e {font-size: 1.2em !important}
                .f {font-family: Minion, serif !important}
            """.trimIndent(),
        )
        assertEquals(true, sheet.declarations(tag = "p", classes = "a", identifier = null).italic)
        assertEquals(Alignment.JUSTIFY, sheet.declarations(tag = "p", classes = "b", identifier = null).alignment)
        assertEquals(true, sheet.declarations(tag = "p", classes = "c", identifier = null).bold)
        assertEquals(Length.Ems(1.5), sheet.declarations(tag = "p", classes = "d", identifier = null).textIndent)
        assertEquals(1.2, sheet.declarations(tag = "p", classes = "e", identifier = null).fontScale)
        assertEquals(listOf("minion", "serif"), sheet.declarations(tag = "p", classes = "f", identifier = null).families)
        // Inline styles go through the same reader.
        assertEquals(
            true,
            EpubStyleSheet().declarations(tag = "p", classes = null, identifier = null, inlineStyle = "font-style: italic !important").italic,
        )
    }

    /**
     * The renderer skips the whole cascade for an empty sheet, so a sheet whose
     * only honoured rules were `!important` lost all of them.
     */
    @Test
    fun importantOnlySheetIsNotEmpty() {
        assertFalse(sheet(".a {font-style: italic !important}").isEmpty)
    }
}
