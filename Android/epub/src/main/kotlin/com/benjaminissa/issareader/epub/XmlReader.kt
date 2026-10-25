package com.benjaminissa.issareader.epub

import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction

/** One attribute as the document spells it: its qualified name and its normalised value. */
internal class XmlAttribute(val qualifiedName: String, val value: String)

/**
 * What the reader reports, in document order — the three `XMLParserDelegate`
 * callbacks `EPUBXML.Builder` implements on the Swift side.
 */
internal interface XmlHandler {
    /**
     * An element opens. `localName` is the part after the prefix, as
     * `XMLParser` reports it with `shouldProcessNamespaces`; `attributes` keep
     * their qualified names and leave out the namespace declarations, as it
     * does. Returns false to stop the read, which is `abortParsing()`.
     */
    fun startElement(localName: String, attributes: List<XmlAttribute>): Boolean

    /** Character data, CDATA included, inside the root element. */
    fun characters(text: String)

    fun endElement()
}

/** A document that is not well-formed XML. The message names the first error and where it is. */
internal class XmlSyntaxError(message: String) : Exception(message)

/**
 * A strict XML 1.0 reader, written out by hand so that a book reads the same on
 * the JVM, on every Android release and on iOS.
 *
 * The Swift side parses with `XMLParser`, which is libxml2, and the books it
 * was proved on are the books this has to agree with. Android's XmlPullParser
 * (kxml2) and the JVM's javax.xml differ from libxml2 and from each other —
 * about undefined entities, about where whitespace goes, about what counts as
 * well-formed — so neither is used. What this does is libxml2's well-formedness
 * checking with `XMLParser`'s settings (namespaces processed, external entities
 * never loaded):
 *
 * - The encoding comes from a byte-order mark, else from the first four bytes
 *   (UTF-16 and UTF-32 without a mark), else from the XML declaration, else
 *   UTF-8. Bytes that are not in that encoding are an error, as libxml2's
 *   "Input is not proper UTF-8" is.
 * - Line ends are normalised (`\r\n` and a lone `\r` become `\n`) before
 *   anything else, as XML 1.0 §2.11 says; a `&#13;` still makes a real CR.
 * - Character references and the five predefined entities are resolved, and
 *   any other entity is fatal. The HTML names a chapter uses have already been
 *   rewritten as numeric references by `EpubXml.substitutingHtmlEntities` when
 *   the caller asked for that — the same pre-pass Swift makes.
 * - Attribute values are normalised as the spec says for CDATA attributes: each
 *   literal tab or newline becomes a space; nothing is collapsed.
 * - CDATA sections are character data. Comments and processing instructions
 *   are skipped, and so is the DOCTYPE, internal subset and all — no DTD is
 *   read, so an entity declared there is still undefined.
 * - Namespace prefixes are not resolved, because nothing downstream needs the
 *   URIs: elements are reported by local name and attributes by qualified name.
 *   An unbound prefix is a namespace error, which libxml2 reports without
 *   stopping, and this reads on too.
 *
 * Iterative, not recursive, so the reader itself imposes no depth limit; the
 * tree builder imposes `EpubXml.maximumDepth`, for the reason it gives.
 */
internal object XmlReader {
    /**
     * Reads `data`, reporting to `handler`. True when the document was read to
     * its end; false when the handler stopped it.
     *
     * @throws XmlSyntaxError at the first well-formedness error.
     */
    fun read(data: ByteArray, handler: XmlHandler): Boolean = Parser(decode(data), handler).parse()

    /** The document as text, in the encoding it declares or is detected in, with line ends normalised. */
    fun decode(data: ByteArray): String {
        fun at(index: Int): Int = if (index < data.size) data[index].toInt() and 0xFF else -1
        var start = 0
        val charset: Charset = when {
            at(0) == 0x00 && at(1) == 0x00 && at(2) == 0xFE && at(3) == 0xFF -> Charset.forName("UTF-32BE").also { start = 4 }
            at(0) == 0xFF && at(1) == 0xFE && at(2) == 0x00 && at(3) == 0x00 -> Charset.forName("UTF-32LE").also { start = 4 }
            at(0) == 0xEF && at(1) == 0xBB && at(2) == 0xBF -> Charsets.UTF_8.also { start = 3 }
            at(0) == 0xFE && at(1) == 0xFF -> Charsets.UTF_16BE.also { start = 2 }
            at(0) == 0xFF && at(1) == 0xFE -> Charsets.UTF_16LE.also { start = 2 }
            at(0) == 0x00 && at(1) == 0x00 && at(2) == 0x00 && at(3) == 0x3C -> Charset.forName("UTF-32BE")
            at(0) == 0x3C && at(1) == 0x00 && at(2) == 0x00 && at(3) == 0x00 -> Charset.forName("UTF-32LE")
            at(0) == 0x00 && at(1) == 0x3C && at(2) == 0x00 && at(3) == 0x3F -> Charsets.UTF_16BE
            at(0) == 0x3C && at(1) == 0x00 && at(2) == 0x3F && at(3) == 0x00 -> Charsets.UTF_16LE
            // Eight-bit and ASCII-compatible: the declaration says which.
            else -> declaredEncoding(data)?.let(::charsetNamed) ?: Charsets.UTF_8
        }
        val text = try {
            charset.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(data, start, data.size - start))
                .toString()
        } catch (_: CharacterCodingException) {
            throw XmlSyntaxError("Input is not proper ${charset.name()}, indicate encoding")
        }
        if ('\r' !in text) return text
        val normalised = StringBuilder(text.length)
        var i = 0
        while (i < text.length) {
            val character = text[i]
            if (character == '\r') {
                normalised.append('\n')
                if (i + 1 < text.length && text[i + 1] == '\n') i += 1
            } else {
                normalised.append(character)
            }
            i += 1
        }
        return normalised.toString()
    }

    private val encodingDeclaration = Regex("""^<\?xml[ \t\r\n][^>]*?encoding[ \t\r\n]*=[ \t\r\n]*(["'])([^"']*)\1""")

    /** The `encoding` an ASCII-compatible document's declaration names, read before the document is decoded. */
    private fun declaredEncoding(data: ByteArray): String? {
        if (data.size < 6 || data[0] != '<'.code.toByte() || data[1] != '?'.code.toByte()) return null
        val head = String(data, 0, minOf(data.size, 512), Charsets.ISO_8859_1)
        return encodingDeclaration.find(head)?.groupValues?.get(2)
    }

    /**
     * The charset an eight-bit document may name.
     *
     * A sixteen- or thirty-two-bit name on bytes that are plainly not is
     * libxml2's "Document labelled UTF-16 but has UTF-8 content", a fatal
     * error. Anything else is looked up only among the encodings both the JVM
     * and Android ship, so a book never reads on one and not the other.
     */
    private fun charsetNamed(name: String): Charset {
        val upper = name.uppercase()
        if (upper.startsWith("UTF-16") || upper.startsWith("UTF16") || upper.startsWith("UTF-32") ||
            upper.startsWith("UCS-") || upper.startsWith("UTF32")
        ) {
            throw XmlSyntaxError("Document labelled $name but has UTF-8 content")
        }
        return when (upper) {
            "UTF-8", "UTF8" -> Charsets.UTF_8
            "US-ASCII", "ASCII" -> Charsets.US_ASCII
            "ISO-8859-1", "ISO_8859-1", "ISO8859-1", "LATIN1", "LATIN-1", "ISO-LATIN-1", "L1", "CP819", "IBM819" ->
                Charsets.ISO_8859_1
            else -> {
                if (!sharedEncodings.matches(upper)) throw XmlSyntaxError("Unsupported encoding $name")
                try {
                    Charset.forName(name)
                } catch (_: IllegalArgumentException) {
                    throw XmlSyntaxError("Unsupported encoding $name")
                }
            }
        }
    }

    private val sharedEncodings = Regex(
        "ISO-8859-([2-9]|1[0356])|WINDOWS-125[0-8]|CP125[0-8]|KOI8-[RU]|SHIFT_JIS|EUC-JP|EUC-KR|GB2312|GBK|GB18030|BIG5",
    )

    private class Parser(private val s: String, private val handler: XmlHandler) {
        private var pos = 0
        private val n = s.length
        private val openNames = ArrayList<String>()
        private val text = StringBuilder()

        fun parse(): Boolean {
            if (s.startsWith("<?xml") && n > 5 && isSpace(s[5])) xmlDeclaration()
            var sawDoctype = false
            while (true) {
                skipSpaces()
                if (pos >= n) fail("Document is empty")
                when {
                    s.startsWith("<!--", pos) -> comment()
                    s.startsWith("<?", pos) -> processingInstruction()
                    s.startsWith("<!DOCTYPE", pos) -> {
                        if (sawDoctype) fail("Extra content at the end of the document")
                        doctype()
                        sawDoctype = true
                    }
                    s[pos] == '<' && pos + 1 < n && nameStartLength(pos + 1) > 0 -> break
                    else -> fail("Start tag expected, '<' not found")
                }
            }
            if (!content()) return false
            while (true) {
                skipSpaces()
                if (pos >= n) return true
                when {
                    s.startsWith("<!--", pos) -> comment()
                    s.startsWith("<?", pos) -> processingInstruction()
                    else -> fail("Extra content at the end of the document")
                }
            }
        }

        /** The root element and everything in it, without recursion. */
        private fun content(): Boolean {
            if (!startTag()) return false
            while (openNames.isNotEmpty()) {
                if (pos >= n) fail("Premature end of data in tag ${openNames.last()}")
                when (s[pos]) {
                    '<' -> when {
                        s.startsWith("</", pos) -> {
                            flushText()
                            endTag()
                        }
                        s.startsWith("<!--", pos) -> comment()
                        s.startsWith("<![CDATA[", pos) -> cdata()
                        s.startsWith("<?", pos) -> processingInstruction()
                        s.startsWith("<!", pos) -> fail("StartTag: invalid element name")
                        else -> {
                            flushText()
                            if (!startTag()) return false
                        }
                    }
                    '&' -> reference(text)
                    else -> characterData()
                }
            }
            return true
        }

        private fun flushText() {
            if (text.isEmpty()) return
            handler.characters(text.toString())
            text.setLength(0)
        }

        private fun startTag(): Boolean {
            pos += 1
            val name = name() ?: fail("StartTag: invalid element name")
            val attributes = ArrayList<XmlAttribute>()
            val seen = HashSet<String>()
            val empty: Boolean
            while (true) {
                val spaced = skipSpaces()
                if (pos >= n) fail("Couldn't find end of Start Tag $name")
                if (s[pos] == '>') {
                    pos += 1
                    empty = false
                    break
                }
                if (s.startsWith("/>", pos)) {
                    pos += 2
                    empty = true
                    break
                }
                if (!spaced) fail("attributes construct error")
                val attribute = name() ?: fail("attributes construct error")
                skipSpaces()
                if (pos >= n || s[pos] != '=') fail("Specification mandates value for attribute $attribute")
                pos += 1
                skipSpaces()
                val value = attributeValue()
                if (!seen.add(attribute)) fail("Attribute $attribute redefined")
                // Namespace declarations are not attributes once namespaces are
                // processed: `XMLParser` reports neither `xmlns` nor `xmlns:p`.
                if (attribute == "xmlns" || attribute.startsWith("xmlns:")) continue
                attributes.add(XmlAttribute(attribute, value))
            }
            openNames.add(name)
            if (!handler.startElement(localName(name), attributes)) return false
            if (empty) {
                openNames.removeAt(openNames.size - 1)
                handler.endElement()
            }
            return true
        }

        private fun endTag() {
            pos += 2
            val name = name() ?: fail("ending tag: invalid element name")
            skipSpaces()
            if (pos >= n || s[pos] != '>') fail("expected '>'")
            pos += 1
            val open = openNames.last()
            if (name != open) fail("Opening and ending tag mismatch: $open and $name")
            openNames.removeAt(openNames.size - 1)
            handler.endElement()
        }

        /**
         * The part of a qualified name after its prefix, split as libxml2's
         * `xmlParseQName` splits it: at the first colon, unless that leaves
         * either side empty.
         */
        private fun localName(qualified: String): String {
            val colon = qualified.indexOf(':')
            if (colon <= 0 || colon == qualified.length - 1) return qualified
            return qualified.substring(colon + 1)
        }

        private fun attributeValue(): String {
            if (pos >= n || (s[pos] != '"' && s[pos] != '\'')) fail("AttValue: \" or ' expected")
            val quote = s[pos]
            pos += 1
            val value = StringBuilder()
            while (true) {
                if (pos >= n) fail("AttValue: ' expected")
                when (val character = s[pos]) {
                    quote -> {
                        pos += 1
                        return value.toString()
                    }
                    '<' -> fail("Unescaped '<' not allowed in attributes values")
                    '&' -> reference(value)
                    '\t', '\n' -> {
                        value.append(' ')
                        pos += 1
                    }
                    else -> {
                        val length = charLength(pos)
                        if (length == 1) value.append(character) else value.append(s, pos, pos + length)
                        pos += length
                    }
                }
            }
        }

        /** `&#…;`, `&#x…;` or `&name;`, appended to `into`. */
        private fun reference(into: StringBuilder) {
            if (s.startsWith("&#", pos)) {
                val hex = s.startsWith("&#x", pos)
                pos += if (hex) 3 else 2
                var value = 0
                var digits = 0
                while (pos < n && s[pos] != ';') {
                    val character = s[pos]
                    val digit = when {
                        character in '0'..'9' -> character - '0'
                        hex && character in 'a'..'f' -> character - 'a' + 10
                        hex && character in 'A'..'F' -> character - 'A' + 10
                        else -> fail("xmlParseCharRef: invalid ${if (hex) "hexadecimal" else "decimal"} value")
                    }
                    // Saturating: past the last code point it is invalid however
                    // many more digits follow.
                    value = if (value > 0x10FFFF) value else value * (if (hex) 16 else 10) + digit
                    digits += 1
                    pos += 1
                }
                if (pos >= n || digits == 0) fail("xmlParseCharRef: invalid xmlChar value")
                pos += 1
                if (!isXmlChar(value)) fail("xmlParseCharRef: invalid xmlChar value $value")
                into.appendCodePoint(value)
                return
            }
            pos += 1
            val name = name() ?: fail("xmlParseEntityRef: no name")
            if (pos >= n || s[pos] != ';') fail("EntityRef: expecting ';'")
            pos += 1
            val replacement = when (name) {
                "lt" -> '<'
                "gt" -> '>'
                "amp" -> '&'
                "apos" -> '\''
                "quot" -> '"'
                else -> fail("Entity '$name' not defined")
            }
            into.append(replacement)
        }

        /** A run of character data up to the next markup or reference. */
        private fun characterData() {
            val start = pos
            while (pos < n) {
                val character = s[pos]
                if (character == '<' || character == '&') break
                if (character == ']' && s.startsWith("]]>", pos)) fail("Sequence ']]>' not allowed in content")
                pos += charLength(pos)
            }
            text.append(s, start, pos)
        }

        private fun cdata() {
            pos += 9
            val end = s.indexOf("]]>", pos)
            if (end < 0) fail("CData section not finished")
            validate(pos, end)
            text.append(s, pos, end)
            pos = end + 3
        }

        private fun comment() {
            pos += 4
            val end = s.indexOf("--", pos)
            if (end < 0) fail("Comment not terminated")
            validate(pos, end)
            if (end + 2 >= n || s[end + 2] != '>') fail("Double hyphen within comment")
            pos = end + 3
        }

        private fun processingInstruction() {
            pos += 2
            val target = name() ?: fail("xmlParsePI : no target name")
            if (target.equals("xml", ignoreCase = true)) fail("XML declaration allowed only at the start of the document")
            if (s.startsWith("?>", pos)) {
                pos += 2
                return
            }
            if (pos >= n || !isSpace(s[pos])) fail("ParsePI: PI $target space expected")
            val end = s.indexOf("?>", pos)
            if (end < 0) fail("ParsePI: PI $target never end")
            validate(pos, end)
            pos = end + 2
        }

        private fun xmlDeclaration() {
            pos = 5
            skipSpaces()
            if (!s.startsWith("version", pos)) fail("Malformed declaration expecting version")
            pos += 7
            val version = pseudoAttributeValue()
            if (!Regex("[0-9]+\\.[0-9]+").matches(version)) fail("Malformed declaration expecting version")
            if (!version.startsWith("1.")) fail("Unsupported version '$version'")
            var spaced = skipSpaces()
            if (s.startsWith("encoding", pos)) {
                if (!spaced) fail("Blank needed here")
                pos += 8
                val encoding = pseudoAttributeValue()
                if (!Regex("[A-Za-z][A-Za-z0-9._-]*").matches(encoding)) fail("Invalid XML encoding name")
                spaced = skipSpaces()
            }
            if (s.startsWith("standalone", pos)) {
                if (!spaced) fail("Blank needed here")
                pos += 10
                val standalone = pseudoAttributeValue()
                if (standalone != "yes" && standalone != "no") fail("standalone accepts only 'yes' or 'no'")
                skipSpaces()
            }
            if (!s.startsWith("?>", pos)) fail("parsing XML declaration: '?>' expected")
            pos += 2
        }

        private fun pseudoAttributeValue(): String {
            skipSpaces()
            if (pos >= n || s[pos] != '=') fail("Malformed declaration: '=' expected")
            pos += 1
            skipSpaces()
            return quotedLiteral()
        }

        private fun quotedLiteral(): String {
            if (pos >= n || (s[pos] != '"' && s[pos] != '\'')) fail("String not started expecting ' or \"")
            val quote = s[pos]
            val end = s.indexOf(quote, pos + 1)
            if (end < 0) fail("String not closed expecting \" or '")
            validate(pos + 1, end)
            val value = s.substring(pos + 1, end)
            pos = end + 1
            return value
        }

        /** `<!DOCTYPE name ExternalID? [internal subset]? >`, read and discarded. */
        private fun doctype() {
            pos += 9
            if (!skipSpaces()) fail("Space required after 'DOCTYPE'")
            name() ?: fail("xmlParseDocTypeDecl : no DOCTYPE name !")
            skipSpaces()
            if (s.startsWith("SYSTEM", pos)) {
                pos += 6
                if (!skipSpaces()) fail("Space required after 'SYSTEM'")
                quotedLiteral()
            } else if (s.startsWith("PUBLIC", pos)) {
                pos += 6
                if (!skipSpaces()) fail("Space required after 'PUBLIC'")
                val publicId = quotedLiteral()
                if (publicId.any { !isPublicIdChar(it) }) fail("Unfinished PubidLiteral")
                if (!skipSpaces()) fail("Space required after the Public Identifier")
                quotedLiteral()
            }
            skipSpaces()
            if (pos < n && s[pos] == '[') {
                pos += 1
                internalSubset()
                pos += 1
                skipSpaces()
            }
            if (pos >= n || s[pos] != '>') fail("DOCTYPE improperly terminated")
            pos += 1
        }

        private fun internalSubset() {
            while (pos < n) {
                when {
                    s[pos] == ']' -> return
                    s.startsWith("<!--", pos) -> comment()
                    s.startsWith("<?", pos) -> processingInstruction()
                    s[pos] == '"' || s[pos] == '\'' -> quotedLiteral()
                    else -> pos += charLength(pos)
                }
            }
            fail("DOCTYPE internal subset not terminated")
        }

        // Characters and names

        private fun skipSpaces(): Boolean {
            val start = pos
            while (pos < n && isSpace(s[pos])) pos += 1
            return pos > start
        }

        private fun isSpace(character: Char) = character == ' ' || character == '\t' || character == '\n' || character == '\r'

        private fun name(): String? {
            val start = pos
            val first = nameStartLength(pos)
            if (first == 0) return null
            pos += first
            while (pos < n) {
                val length = nameLength(pos)
                if (length == 0) break
                pos += length
            }
            return s.substring(start, pos)
        }

        /** How many UTF-16 units the name-start character at `index` takes, or 0 when it is not one. */
        private fun nameStartLength(index: Int): Int {
            if (index >= n) return 0
            val point = s.codePointAt(index)
            return if (isNameStart(point)) Character.charCount(point) else 0
        }

        private fun nameLength(index: Int): Int {
            if (index >= n) return 0
            val point = s.codePointAt(index)
            return if (isNameStart(point) || isNameOnly(point)) Character.charCount(point) else 0
        }

        /** XML 1.0 (fifth edition) NameStartChar, which libxml2 uses. */
        private fun isNameStart(c: Int): Boolean =
            c == ':'.code || c in 'A'.code..'Z'.code || c == '_'.code || c in 'a'.code..'z'.code ||
                c in 0xC0..0xD6 || c in 0xD8..0xF6 || c in 0xF8..0x2FF || c in 0x370..0x37D ||
                c in 0x37F..0x1FFF || c in 0x200C..0x200D || c in 0x2070..0x218F || c in 0x2C00..0x2FEF ||
                c in 0x3001..0xD7FF || c in 0xF900..0xFDCF || c in 0xFDF0..0xFFFD || c in 0x10000..0xEFFFF

        private fun isNameOnly(c: Int): Boolean =
            c == '-'.code || c == '.'.code || c in '0'.code..'9'.code || c == 0xB7 ||
                c in 0x300..0x36F || c in 0x203F..0x2040

        private fun isXmlChar(c: Int): Boolean =
            c == 0x9 || c == 0xA || c == 0xD || c in 0x20..0xD7FF || c in 0xE000..0xFFFD || c in 0x10000..0x10FFFF

        private fun isPublicIdChar(c: Char): Boolean =
            c == ' ' || c == '\r' || c == '\n' || c in 'a'..'z' || c in 'A'..'Z' || c in '0'..'9' || c in "-'()+,./:=?;!*#@\$_%"

        /** The UTF-16 length of the character at `index`, failing on one XML does not allow. */
        private fun charLength(index: Int): Int {
            val character = s[index]
            if (character.code >= 0x20 && character.code < 0xD800) return 1
            if (character == '\t' || character == '\n' || character == '\r') return 1
            if (character.code in 0xE000..0xFFFD) return 1
            if (Character.isHighSurrogate(character) && index + 1 < n && Character.isLowSurrogate(s[index + 1])) return 2
            fail("PCDATA invalid Char value ${character.code}")
        }

        private fun validate(from: Int, to: Int) {
            var index = from
            while (index < to) index += charLength(index)
        }

        private fun fail(message: String): Nothing {
            var line = 1
            var column = 1
            for (i in 0 until minOf(pos, n)) {
                if (s[i] == '\n') {
                    line += 1
                    column = 1
                } else {
                    column += 1
                }
            }
            throw XmlSyntaxError("$message (line $line, column $column)")
        }
    }
}
