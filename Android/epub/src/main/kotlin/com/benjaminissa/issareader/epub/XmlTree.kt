package com.benjaminissa.issareader.epub

import com.benjaminissa.issareader.core.model.HtmlEntities

/**
 * A minimal XML tree, built by [XmlReader].
 *
 * Models mixed content properly: [text] is what appears before the first
 * child, and each child carries the [tail] text that follows it. Without that
 * distinction `<p>Hello <b>world</b> again</p>` loses the word "again", or
 * reorders it — which is exactly the class of bug that makes a reader subtly
 * mangle ordinary prose.
 */
class EpubXmlNode internal constructor(
    /** The element's local name: `dc:title` is `title`. */
    val name: String,
    /**
     * Every attribute under its qualified name, and a prefixed one under its
     * local name too — see [EpubXml.parse].
     */
    var attributes: Map<String, String> = emptyMap(),
) {
    /** Character data before the first child element. */
    var text: String = ""

    /** Character data immediately after this element, belonging to its parent. */
    var tail: String = ""

    private val childNodes = ArrayList<EpubXmlNode>()
    val children: List<EpubXmlNode> get() = childNodes

    var parent: EpubXmlNode? = null

    internal fun add(child: EpubXmlNode) {
        child.parent = this
        childNodes.add(child)
    }

    fun children(localName: String): List<EpubXmlNode> = childNodes.filter { it.name == localName }

    fun firstChild(localName: String): EpubXmlNode? = childNodes.firstOrNull { it.name == localName }

    /** Depth-first search by local name. */
    fun descendants(localName: String): List<EpubXmlNode> {
        val found = ArrayList<EpubXmlNode>()
        collectDescendants(localName, found)
        return found
    }

    private fun collectDescendants(localName: String, into: MutableList<EpubXmlNode>) {
        for (child in childNodes) {
            if (child.name == localName) into.add(child)
            child.collectDescendants(localName, into)
        }
    }

    /** This node or the first beneath it with this name, compared case-insensitively. */
    fun firstDescendant(named: String): EpubXmlNode? {
        if (name.lowercase() == named.lowercase()) return this
        for (child in childNodes) {
            child.firstDescendant(named)?.let { return it }
        }
        return null
    }

    /** All character data beneath this node, in document order. */
    val allText: String get() = StringBuilder().also { appendAllText(it) }.toString()

    private fun appendAllText(into: StringBuilder) {
        into.append(text)
        for (child in childNodes) {
            child.appendAllText(into)
            into.append(child.tail)
        }
    }

    /** Leading text with surrounding whitespace removed, for metadata fields. */
    val trimmedText: String get() = text.trimmingWhitespaceAndNewlines()

    operator fun get(attribute: String): String? = attributes[attribute]
}

object EpubXml {
    /**
     * Parses into a tree, matching on local names.
     *
     * EPUB documents vary wildly in whether and how they prefix `opf:`, `dc:`,
     * `epub:` and `smil:`. Matching the local name is what makes this work
     * against real books rather than only tidy ones.
     *
     * Attribute keys stay qualified (`epub:type`), and a prefixed one is
     * indexed under its local name (`type`) as well. Where the two collide —
     * `type` and `epub:type` on one element — the unprefixed attribute keeps
     * its own name and the first prefixed one supplies the alias; the Swift
     * side takes whichever its attribute dictionary happens to iterate last.
     * Every caller here reads both spellings or prefers the qualified one, so
     * none depends on the choice.
     *
     * @throws EpubError.MalformedPackage for a document that is not
     *   well-formed, or that nests deeper than [maximumDepth].
     */
    fun parse(data: ByteArray): EpubXmlNode {
        val builder = Builder()
        val completed = try {
            XmlReader.read(data, builder)
        } catch (error: XmlSyntaxError) {
            throw EpubError.MalformedPackage(error.message ?: "XML parse failed")
        }
        if (builder.exceededDepth) {
            throw EpubError.MalformedPackage("elements nested deeper than $maximumDepth; refusing to walk it")
        }
        val root = builder.root
        if (!completed || root == null) throw EpubError.MalformedPackage("XML parse failed")
        return root
    }

    /**
     * Parses XHTML that may name HTML entities XML does not define.
     *
     * For anything a book's author wrote as HTML — a chapter, a navigation
     * document, an NCX — rather than a package file a tool generated. Those
     * routinely say `&nbsp;`, and an XHTML file under the HTML5 short DOCTYPE
     * (or none, which is nearly all of them) declares no entities at all, so a
     * strict parser fails the whole document. With `substitutingHtmlEntities`
     * false this is exactly [parse].
     */
    fun parse(data: ByteArray, substitutingHtmlEntities: Boolean): EpubXmlNode =
        parse(if (substitutingHtmlEntities) substitutingHtmlEntities(data) else data)

    /**
     * Rewrites every HTML 4.01 named entity XML does not predefine as a numeric
     * reference, in one pass.
     *
     * One pass, not one per entity: the first Swift version was a
     * `replacingOccurrences` per name, a full scan and a new string per name,
     * which on a 400 KB chapter was slow enough to notice once the table was
     * complete. Scanning once and looking each name up costs the same for a
     * table of any size.
     *
     * Data that is not UTF-8, or holds no `&`, is returned untouched.
     */
    fun substitutingHtmlEntities(data: ByteArray): ByteArray {
        val text = decodeUtf8OrNull(data) ?: return data
        if ('&' !in text) return data

        val out = StringBuilder(text.length)
        var index = 0
        while (true) {
            val amp = text.indexOf('&', index)
            if (amp < 0) break
            out.append(text, index, amp)
            // A name is letters and digits, then a semicolon. Bail out at a
            // reasonable width rather than scanning to the end of the document
            // for a stray `&` — prose is full of them.
            val after = amp + 1
            val limit = minOf(after + 12, text.length)
            var semicolon = -1
            for (i in after until limit) {
                if (text[i] == ';') {
                    semicolon = i
                    break
                }
            }
            if (semicolon >= 0) {
                val code = htmlNamedEntities[text.substring(after, semicolon)]
                if (code != null) {
                    out.append("&#").append(code).append(';')
                    index = semicolon + 1
                    continue
                }
            }
            // Not one of ours: the five XML predefined entities, a numeric
            // reference, or a bare ampersand. All are the parser's business.
            out.append('&')
            index = after
        }
        out.append(text, index, text.length)
        return out.toString().toByteArray(Charsets.UTF_8)
    }

    /**
     * Every HTML 4.01 named entity that XML does not predefine, mapped to its
     * code point. The table is `HtmlEntities.named` in `:core`, shared with the
     * descriptions `HtmlText` renders, so a book's chapters and its description
     * decode the same names; why it has to be complete is written there.
     */
    val htmlNamedEntities: Map<String, Int> = HtmlEntities.named

    /**
     * How deeply an element may nest before the document is refused.
     *
     * `XMLParser` imposes no limit of its own — measured on the Swift side:
     * 200, 300, 1,000 and 50,000 levels all parse — and neither does
     * [XmlReader], which is iterative. But the tree is walked recursively by
     * `descendants`, `firstDescendant`, `allText`, the renderer, `SmilParser`'s
     * walk and `EpubPackage`'s navigation flattening, none of which has a base
     * case other than running out of children.
     *
     * That makes deep nesting a stack overflow — a crash, not a thrown error,
     * so the catches around every parse catch nothing. 150,000 nested elements
     * is about 1.2 MB of XHTML that deflates to a few hundred bytes, a ratio
     * well inside the archive guards, and a thread's stack on a phone is a
     * fraction of a desktop's.
     *
     * 512 is far past anything a book does — real XHTML rarely exceeds twenty —
     * and far short of what any of those walks can survive.
     */
    internal const val maximumDepth = 512

    private class Builder : XmlHandler {
        var root: EpubXmlNode? = null
        private val stack = ArrayList<EpubXmlNode>()
        var exceededDepth = false
            private set

        override fun startElement(localName: String, attributes: List<XmlAttribute>): Boolean {
            // Elements arrive by local name, but attribute keys arrive
            // qualified (e.g. `epub:type`), so both forms are indexed.
            val indexed = LinkedHashMap<String, String>(attributes.size * 2)
            for (attribute in attributes) indexed[attribute.qualifiedName] = attribute.value
            for (attribute in attributes) {
                val colon = attribute.qualifiedName.indexOf(':')
                if (colon >= 0) indexed.putIfAbsent(attribute.qualifiedName.substring(colon + 1), attribute.value)
            }
            if (stack.size >= maximumDepth) {
                // Abort rather than keep building: the tree is already deep
                // enough that walking it is the hazard, and stopping the read
                // makes `parse` throw `MalformedPackage` at the call site.
                exceededDepth = true
                return false
            }
            val node = EpubXmlNode(localName, indexed)
            val current = stack.lastOrNull()
            if (current != null) current.add(node) else root = node
            stack.add(node)
            return true
        }

        override fun characters(text: String) {
            val current = stack.lastOrNull() ?: return
            // Text after a child belongs to that child's tail, not to the
            // parent's leading text.
            val lastChild = current.children.lastOrNull()
            if (lastChild != null) lastChild.tail += text else current.text += text
        }

        override fun endElement() {
            stack.removeAt(stack.size - 1)
        }
    }
}
