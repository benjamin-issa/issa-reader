package com.benjaminissa.issareader.epub

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The hand-written reader's own rules, which have no Swift suite because the
 * Swift side delegates them to libxml2.
 *
 * Every expectation here was checked against libxml2 itself (2.14, through
 * lxml) on the same bytes, and the whole of every fixture book's XML dumps
 * identically through both. The two places this reader departs from a bare
 * libxml2 are where `XMLParser` does: no depth limit of its own (see
 * `XmlDepthTest`), and an undefined entity is fatal even under a DOCTYPE that
 * names an external DTD.
 */
class XmlReaderTest {
    private fun parse(bytes: ByteArray): EpubXmlNode = EpubXml.parse(bytes)

    private fun parse(text: String): EpubXmlNode = parse(utf8(text))

    private fun refuses(text: String) {
        assertThrows(text, EpubError.MalformedPackage::class.java) { parse(text) }
    }

    // Encodings

    @Test
    fun aUtf8ByteOrderMarkIsNotText() {
        val root = parse(bytesOf(0xEF, 0xBB, 0xBF) + utf8("<?xml version=\"1.0\"?><r>café</r>"))
        assertEquals("café", root.text)
    }

    @Test
    fun utf16IsReadByItsMarkOrItsFirstBytes() {
        val document = "<?xml version=\"1.0\" encoding=\"UTF-16\"?><r a=\"é\">café 😀</r>"
        for (bytes in listOf(
            bytesOf(0xFF, 0xFE) + document.toByteArray(Charsets.UTF_16LE),
            bytesOf(0xFE, 0xFF) + document.toByteArray(Charsets.UTF_16BE),
            document.toByteArray(Charsets.UTF_16LE),
            document.toByteArray(Charsets.UTF_16BE),
        )) {
            val root = parse(bytes)
            assertEquals("café 😀", root.text)
            assertEquals("é", root["a"])
        }
    }

    @Test
    fun anEightBitEncodingIsTakenFromTheDeclaration() {
        assertEquals("café", parse("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><r>café</r>".toByteArray(Charsets.ISO_8859_1)).text)
        assertEquals(
            "café ’",
            parse("<?xml version='1.0' encoding='windows-1252'?><r>café ’</r>".toByteArray(charset("windows-1252"))).text,
        )
    }

    /** libxml2's "Input is not proper UTF-8", "labelled UTF-16 but has UTF-8 content" and "Unsupported encoding". */
    @Test
    fun bytesThatAreNotTheirEncodingAreRefused() {
        assertThrows(EpubError::class.java) { parse(bytesOf(0x3C, 0x72, 0x3E, 0x63, 0x61, 0x66, 0xE9, 0x3C, 0x2F, 0x72, 0x3E)) }
        refuses("<?xml version=\"1.0\" encoding=\"UTF-16\"?><r/>")
        refuses("<?xml version=\"1.0\" encoding=\"x-bogus\"?><r/>")
        assertThrows(EpubError::class.java) {
            parse("<?xml version=\"1.0\" encoding=\"US-ASCII\"?><r>café</r>".toByteArray(Charsets.ISO_8859_1))
        }
    }

    // Line ends

    /** `\r\n` and a lone `\r` are one `\n` before anything else reads the text; in an attribute that `\n` is a space. */
    @Test
    fun lineEndsAreNormalised() {
        val root = parse("<?xml version=\"1.0\"?>\r\n<r a=\"x\r\ny\">one\r\ntwo\rthree</r>")
        assertEquals("one\ntwo\nthree", root.text)
        assertEquals("x y", root["a"])
    }

    // References

    @Test
    fun characterReferencesAndThePredefinedEntitiesResolve() {
        val root = parse("<r a=\"&#9;&#10;&#13;&#x41;\">&#65;&#x1F600;&#38;&lt;&gt;&amp;&apos;&quot;</r>")
        assertEquals("A😀&<>&'\"", root.text)
        // A reference is not normalised the way a literal tab or newline is.
        assertEquals("\t\n\rA", root["a"])
    }

    @Test
    fun aReferenceToNoCharacterIsRefused() {
        refuses("<r>&#0;</r>")
        refuses("<r>&#xD800;</r>")
        refuses("<r>&#x110000;</r>")
        refuses("<r>&#65</r>")
        refuses("<r>&;</r>")
        refuses("<r>a & b</r>")
    }

    /**
     * Any entity XML does not predefine is fatal — with no DOCTYPE, the HTML5
     * one, or one naming an external DTD, which is never loaded. libxml2 alone
     * only warns in the last case; `XMLParser` stops the parse in all three.
     */
    @Test
    fun anUndefinedEntityIsFatalUnderAnyDoctype() {
        refuses("<r>&nbsp;</r>")
        refuses("<!DOCTYPE html><r>&nbsp;</r>")
        refuses("<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.1//EN\" \"x.dtd\"><r>&nbsp;</r>")
    }

    // Attributes

    @Test
    fun attributeValuesAreNormalisedButNotCollapsed() {
        val root = parse("<r a=\"  x\ty\n z  \" b='single \"q\"' c=\"&amp;&lt;&#x20;&quot;\"/>")
        assertEquals("  x y  z  ", root["a"])
        assertEquals("single \"q\"", root["b"])
        assertEquals("&< \"", root["c"])
    }

    @Test
    fun malformedAttributesAreRefused() {
        refuses("<r a=\"1\" a=\"2\"/>")
        refuses("<r a=\"<\"/>")
        refuses("<r disabled/>")
        refuses("<r a=1/>")
        refuses("<r a=\"1\"b=\"2\"/>")
    }

    // Character data, comments, instructions and the DOCTYPE

    /** CDATA is character data; comments and instructions are skipped, and the text either side of one is one run. */
    @Test
    fun cdataJoinsTheTextAndCommentsDoNot() {
        val root = parse("<?xml version=\"1.0\"?><!--lead--><?pi data?><r>a<![CDATA[<b>&amp;]]><!--c-->b<?p x?>c<x/>d<!--e-->f<![CDATA[g]]></r><!--trail-->")
        assertEquals("a<b>&amp;bc", root.text)
        assertEquals("dfg", root.children.single().tail)
    }

    @Test
    fun theDoctypeIsSkippedSubsetAndAll() {
        assertEquals("x", parse("<!DOCTYPE r [ <!ELEMENT r ANY> <!-- ] --> <!ATTLIST r a CDATA \"q]\"> ]><r>x</r>").text)
        assertEquals(
            "p",
            parse("<?xml version=\"1.0\"?>\n<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.1//EN\" \"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd\">\n<html><p>x</p></html>")
                .children.single().name,
        )
        // A PUBLIC id needs its system literal, and only public-id characters.
        refuses("<!DOCTYPE r PUBLIC \"-//X//Y\">\n<r/>")
        refuses("<!DOCTYPE r PUBLIC \"a{b\" \"x\"><r/>")
        refuses("<r/><!DOCTYPE r>")
        refuses("<!DOCTYPE r><!DOCTYPE r><r/>")
    }

    @Test
    fun aDocumentThatIsNotWellFormedIsRefused() {
        for (text in listOf(
            "", "   \n", "x<r/>", "<r/>x", "<r/><s/>", "<r><a></b></r>", "<r><a>",
            "<r>a]]>b</r>", "<r><!-- a -- b --></r>", "<r><!-- a ---></r>",
            " <?xml version=\"1.0\"?><r/>", "<r><?xml version=\"1.0\"?></r>", "<?XML version=\"1.0\"?><r/>",
            "<?xml encoding=\"UTF-8\"?><r/>", "<?xml version=\"2.0\"?><r/>", "<?xml version=\"1.0\" standalone=\"maybe\"?><r/>",
            "<r>a\u0001b</r>", "<r>a￾b</r>", "<1r/>", "< r/>", "<![CDATA[x]]><r/>", "<r><?pi", "<r><!-- x",
        )) {
            refuses(text)
        }
    }

    @Test
    fun whatXmlAllowsIsRead() {
        assertEquals("r", parse("<?xml version=\"1.1\" standalone=\"yes\"?><r/>").name)
        assertEquals("a > b", parse("<r>a > b</r>").text)
        assertEquals("a\u0085b c", parse("<r>a\u0085b c</r>").text)
        val unicode = parse("<ré><日本>x</日本></ré>")
        assertEquals("ré", unicode.name)
        assertEquals("日本", unicode.children.single().name)
        assertEquals("a", parse("<r ><a\n/></r \n>").children.single().name)
    }

    // Namespaces

    /** Elements by local name; attributes by qualified name and, when prefixed, by local name too; declarations not at all. */
    @Test
    fun namesAreLocalAndAttributesAreIndexedBothWays() {
        val root = parse("<r xmlns=\"u\" xmlns:e=\"v\" e:t=\"1\" xml:lang=\"en\"><e:c e:x=\"y\"/></r>")
        assertEquals("r", root.name)
        assertEquals(mapOf("e:t" to "1", "xml:lang" to "en", "t" to "1", "lang" to "en"), root.attributes)
        val child = root.children.single()
        assertEquals("c", child.name)
        assertEquals("y", child["x"])
        assertEquals("y", child["e:x"])
        assertNull(root["xmlns"])
        assertNull(root["xmlns:e"])
    }

    /** An unprefixed attribute keeps its own name when a prefixed one shares its local name. */
    @Test
    fun anUnprefixedAttributeKeepsItsName() {
        val root = parse("<a xmlns:epub=\"http://www.idpf.org/2007/ops\" type=\"u\" epub:type=\"x\"/>")
        assertEquals("u", root["type"])
        assertEquals("x", root["epub:type"])
    }

    /**
     * An unbound prefix is a namespace error, which libxml2 reports without
     * stopping the parse; this reads on, by local name, as `XMLParser` reports
     * such an element.
     */
    @Test
    fun anUnboundPrefixIsReadOn() {
        val root = parse("<html><nav epub:type=\"toc\">x</nav><epub:aside>y</epub:aside></html>")
        assertEquals(listOf("nav", "aside"), root.children.map { it.name })
        assertEquals("toc", root.children[0]["type"])
        assertEquals("toc", root.children[0]["epub:type"])
    }

    // Depth

    /** The builder takes 512 nested elements, the root among them, and refuses the 513th. */
    @Test
    fun theDepthLimitIsExact() {
        fun nested(elements: Int) = "<d>".repeat(elements) + "</d>".repeat(elements)
        assertEquals("d", parse(nested(EpubXml.maximumDepth)).name)
        refuses(nested(EpubXml.maximumDepth + 1))
    }

    /** The reader reports to its handler in order, and a handler that says stop stops it. */
    @Test
    fun aHandlerCanStopTheRead() {
        val seen = ArrayList<String>()
        val handler = object : XmlHandler {
            override fun startElement(localName: String, attributes: List<XmlAttribute>): Boolean {
                seen.add(localName)
                return localName != "stop"
            }

            override fun characters(text: String) {
                seen.add("'$text'")
            }

            override fun endElement() {
                seen.add("/")
            }
        }
        assertFalse(XmlReader.read(utf8("<r>a<b/>c<stop/>never</r>"), handler))
        assertEquals(listOf("r", "'a'", "b", "/", "'c'", "stop"), seen)
        seen.clear()
        assertTrue(XmlReader.read(utf8("<r>a<b/>c</r>"), handler))
        assertEquals(listOf("r", "'a'", "b", "/", "'c'", "/"), seen)
    }
}
