package com.benjaminissa.issareader.render

import com.ibm.icu.lang.UCharacter
import com.ibm.icu.lang.UProperty
import org.junit.Assert.assertEquals
import org.junit.Test
import java.text.BreakIterator

/**
 * The whitespace rules the string depends on, pinned to what Swift does.
 *
 * Swift's `HTMLContentParser.collapseWhitespace` walks `Character`s — extended
 * grapheme clusters — and asks whether each one's *first scalar* has Unicode's
 * White_Space property, exempting four characters compared as whole clusters.
 * Kotlin's own notion of whitespace differs on six code points that books
 * really contain (it leaves out the no-break spaces and takes in U+001C–U+001F),
 * and a JVM `String` has no clusters at all, so each piece is checked here
 * against ICU, which is what Foundation itself is built on.
 */
class WhitespaceCollapseTest {
    /** The table is White_Space exactly — all 25 code points, and nothing else. */
    @Test
    fun `the whitespace table is Unicode's White_Space property`() {
        var count = 0
        for (codePoint in 0..0x10FFFF) {
            val expected = UCharacter.hasBinaryProperty(codePoint, UProperty.WHITE_SPACE)
            assertEquals("U+%04X".format(codePoint), expected, isSwiftWhitespace(codePoint))
            if (expected) count += 1
        }
        assertEquals(25, count)
    }

    /** Where Kotlin's `isWhitespace` would have been wrong, and the string with it. */
    @Test
    fun `the code points Kotlin disagrees about`() {
        // Spared as no-break spaces: the author asked for no break here.
        assertEquals("a\u00A0b", ChapterParser.collapseWhitespace("a\u00A0b"))
        assertEquals("a\u202Fb", ChapterParser.collapseWhitespace("a\u202Fb"))
        assertEquals("a\u2007b", ChapterParser.collapseWhitespace("a\u2007b"))
        // Not whitespace at all to Swift, though Kotlin says they are.
        for (separator in '\u001C'..'\u001F') {
            assertEquals("a${separator}b", ChapterParser.collapseWhitespace("a${separator}b"))
        }
        // Whitespace to Swift, and collapsed with their neighbours.
        assertEquals("a b", ChapterParser.collapseWhitespace("a\u0085\u2028\u3000\u1680b"))
        assertEquals("a b", ChapterParser.collapseWhitespace("a \t\n\u000B\u000C\r b"))
    }

    /**
     * Clusters, not code units. A space carrying a combining mark is one
     * cluster whose first scalar is a space, so the whole of it collapses —
     * the mark with it, as it does in Swift. A no-break space carrying a mark
     * is not the no-break space the exemption names, so it collapses too.
     */
    @Test
    fun `whitespace is judged a cluster at a time`() {
        assertEquals("a b", ChapterParser.collapseWhitespace("a \u0301b"))
        assertEquals("a b", ChapterParser.collapseWhitespace("a\u00A0\u0301b"))
        // CR LF is one cluster: one space, not two collapsed into one.
        assertEquals("a b", ChapterParser.collapseWhitespace("a\r\nb"))
        // A mark after a newline is its own cluster (nothing joins a control),
        // and is kept.
        assertEquals("a \u0301b", ChapterParser.collapseWhitespace("a\n\u0301b"))
        // Astral text passes through whole.
        assertEquals("😀 😀", ChapterParser.collapseWhitespace("😀  😀"))
    }

    /**
     * The drop at the start of a block re-clusters the collapsed text, as
     * Swift's `drop(while:)` walks the new string's own characters: collapsing
     * can bring a space and a mark together into a cluster that is not a
     * space, and that cluster is kept.
     */
    @Test
    fun `the leading drop takes only clusters that are exactly a space`() {
        assertEquals("x", ChapterParser.dropLeadingSpaces("  x"))
        assertEquals(" \u0301x", ChapterParser.dropLeadingSpaces(" \u0301x"))
        assertEquals("\u00A0x", ChapterParser.dropLeadingSpaces("\u00A0x"))
        assertEquals("", ChapterParser.dropLeadingSpaces("   "))
        // In a chapter, the final trim then takes the space, mark or no mark:
        // it works on UTF-16 units, as `NSString` does.
        val text = parse("<html><body><p>\n\u0301x</p></body></html>").text
        assertEquals("\u0301x", text)
    }

    /** The trim is the Swift parser's four code units and no more: a no-break space at either end stays. */
    @Test
    fun `the final trim takes newline, space, tab and return only`() {
        assertEquals("\u00A0x\u00A0", parse("<html><body><p>\u00A0x\u00A0</p></body></html>").text)
        assertEquals("x", parse("<html><body><pre>\t\r\n x \t</pre></body></html>").text)
        assertEquals("\u2028x", parse("<html><body><pre>\n\u2028x\n</pre></body></html>").text)
    }

    /**
     * The JVM's cluster walk against ICU's, on the shapes the collapse can
     * meet. On a device `java.text.BreakIterator` *is* ICU; on the JVM it is
     * the JDK's own extended-grapheme implementation, and the tests run there.
     *
     * Only clusters that begin with, or swallow, whitespace can change the
     * string, so the samples are those — and not, say, a Devanagari conjunct,
     * which Unicode 15.1 (GB9c) joins and the JDK's Unicode 15.0 does not,
     * with no whitespace anywhere in it.
     */
    @Test
    fun `the cluster walk agrees with ICU`() {
        val samples = listOf(
            "a \u0301b", "\r\n", "\n\u0301", "\u00A0\u0301", "e\u0301\u0302 x", "👩\u200D💻 y",
            "🇬🇧🇫🇷", "각 ", "x\u200D y",
            "\u0600 1", " \uFE0F", "\t\u0300", "\u3000\u3099",
        )
        for (sample in samples) {
            assertEquals(sample, boundaries(BreakIterator.getCharacterInstance(), sample), icuBoundaries(sample))
        }
    }

    private fun boundaries(iterator: BreakIterator, text: String): List<Int> {
        iterator.setText(text)
        val found = ArrayList<Int>()
        var at = iterator.first()
        while (at != BreakIterator.DONE) {
            found.add(at)
            at = iterator.next()
        }
        return found
    }

    private fun icuBoundaries(text: String): List<Int> {
        val iterator = com.ibm.icu.text.BreakIterator.getCharacterInstance()
        iterator.setText(text)
        val found = ArrayList<Int>()
        var at = iterator.first()
        while (at != com.ibm.icu.text.BreakIterator.DONE) {
            found.add(at)
            at = iterator.next()
        }
        return found
    }
}
