package com.benjaminissa.issareader.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Book metadata carries HTML written by people and by scrapers. Ported from `HTMLTextTests.swift`. */
class HtmlTextTest {
    private fun plain(html: String) = HtmlText.plain(html)

    @Test fun `tags are removed and the words survive`() {
        assertEquals("It is a truth universally acknowledged.", plain("<p>It is a truth <i>universally acknowledged</i>.</p>"))
    }

    @Test fun `an unescaped ampersand and an unclosed tag do not lose the text`() {
        assertEquals(
            "Plain description with an unescaped & ampersand and an unclosed bold tag",
            plain("Plain description with an unescaped & ampersand and an <b>unclosed bold tag"),
        )
    }

    @Test fun `a fragment with no root element renders`() {
        assertEquals("A great book. Really.", plain("A great book. <i>Really.</i>"))
    }

    @Test fun `entities decode, including numeric and hex`() {
        assertEquals("Austen's wit & sharpness", plain("Austen&#39;s wit &amp; sharpness"))
        assertEquals("café — …", plain("caf&eacute; &mdash; &#x2026;"))
        assertEquals("Tom & Jerry & Co;", plain("Tom & Jerry & Co;"))
    }

    @Test fun `every HTML named entity decodes, capitals kept`() {
        assertEquals("Émile Peña’s müsic", plain("<p>&Eacute;mile Pe&ntilde;a&rsquo;s m&uuml;sic</p>"))
        assertEquals("garçon á ß € ≈ ∴ Ωω", plain("gar&ccedil;on &aacute; &szlig; &euro; &asymp; &there4; &Omega;&omega;"))
        assertEquals("<&> \"a'", plain("&lt;&amp;&gt; &quot;a&apos;"))
    }

    @Test fun `paragraphs become breaks and br a single newline`() {
        assertEquals("One\n\nTwo", plain("<p>One</p><p>Two</p>"))
        assertEquals("First\nSecond", plain("First<br>Second"))
        assertFalse(plain("<p>One</p>").startsWith("\n"))
    }

    @Test fun `whitespace collapses the way a browser lays it out`() {
        assertEquals("Pretty printed description", plain("Pretty\n   printed\t\tdescription"))
    }

    @Test fun `a non-breaking space is kept, not collapsed into a breakable one`() {
        assertEquals("Vol. II", plain("Vol.&nbsp;II"))
        assertEquals("Chapter  One", plain("Chapter&nbsp;&nbsp;One"))
        assertEquals("a b", plain("a&#160;b"))
        assertEquals("a b", plain("a b"))
        assertEquals("10 km", plain("10 km"))
        assertEquals("    Indented line", plain("&nbsp;&nbsp;&nbsp;&nbsp;Indented line"))
        assertEquals("a   b", plain("a \n &nbsp;\t b"))
    }

    @Test fun `unknown tags are dropped rather than shown or thrown`() {
        assertEquals("Kept text", plain("<span class=\"x\">Kept</span> <madeup>text</madeup>"))
    }

    @Test fun `a stray closing tag does not swallow what follows`() {
        assertEquals("Start\n\nend", plain("Start </b></i></p> end"))
    }

    @Test fun `emphasis and links reach the styled output`() {
        assertTrue(HtmlText.runs("<b>Loud</b>").any { it.bold })
        val linked = HtmlText.runs("See <a href=\"https://example.com/x\">this</a>.")
        assertEquals("https://example.com/x", linked.firstNotNullOf { it.link })
        assertEquals("See this.", plain("See <a href=\"https://example.com/x\">this</a>."))
    }

    @Test fun `a lone angle bracket is text, not a broken tag`() {
        assertEquals("5 < 6 and that is that", plain("5 < 6 and that is that"))
    }

    @Test fun `empty and whitespace-only input produce nothing`() {
        assertEquals("", plain(""))
        assertEquals("", plain("<p></p>"))
    }

    // Description markup that came from somewhere else (HTMLTextSafetyTests).

    @Test fun `bold and italic differ from the text around them`() {
        val bold = HtmlText.runs("plain <b>loud</b>")
        assertTrue(bold.size >= 2)
        assertNotEquals(bold.first().bold, bold.last().bold)
        val italic = HtmlText.runs("plain <i>leaning</i>")
        assertNotEquals(italic.first().italic, italic.last().italic)
    }

    @Test fun `only http and https links survive`() {
        for (hostile in listOf("javascript:alert(1)", "data:text/html;base64,PHA+", "file:///etc/passwd")) {
            assertTrue(HtmlText.runs("<a href=\"$hostile\">tap</a>").all { it.link == null })
            assertEquals("tap", plain("<a href=\"$hostile\">tap</a>"))
        }
        assertEquals("https://example.com/x", HtmlText.runs("<a href=\"https://example.com/x\">tap</a>").firstNotNullOf { it.link })
    }

    @Test fun `href is matched as an attribute, not as a substring`() {
        assertEquals("https://example.com/real", HtmlText.runs("<a class=\"nohref\" href=\"https://example.com/real\">tap</a>").firstNotNullOf { it.link })
        assertNull(HtmlText.attribute("href", "a class=\"nohref\""))
    }

    @Test fun `entities inside a link's destination are decoded`() {
        assertEquals("https://example.com/s?a=1&b=2", HtmlText.runs("<a href=\"https://example.com/s?a=1&amp;b=2\">tap</a>").firstNotNullOf { it.link })
    }

    @Test fun `consecutive breaks add up rather than collapsing`() {
        assertEquals("A\nB", plain("A<br>B"))
        assertEquals("A\n\nB", plain("A<br><br>B"))
        assertEquals("A\n\nB", plain("<p>A</p><p>B</p>"))
    }

    // Remembering a rendered description (HTMLTextCacheTests).

    private fun cachedPlain(html: String) = HtmlText.cached(html).joinToString("") { it.text }

    @Test fun `the remembered answer is the same as the computed one`() {
        val html = "<p>It is a truth <i>universally acknowledged</i>.</p>"
        assertEquals(plain(html), cachedPlain(html))
        assertEquals(plain(html), cachedPlain(html))
    }

    @Test fun `two descriptions do not share an answer`() {
        assertEquals("Down the rabbit hole.", cachedPlain("<p>Down the rabbit hole.</p>"))
        assertEquals("Fog everywhere.", cachedPlain("<p>Fog everywhere.</p>"))
        assertEquals("Down the rabbit hole.", cachedPlain("<p>Down the rabbit hole.</p>"))
    }

    @Test fun `a full cache still answers correctly`() {
        for (index in 1..100) assertEquals("Blurb number $index.", cachedPlain("<p>Blurb number $index.</p>"))
        assertEquals("Blurb number 1.", cachedPlain("<p>Blurb number 1.</p>"))
    }
}
