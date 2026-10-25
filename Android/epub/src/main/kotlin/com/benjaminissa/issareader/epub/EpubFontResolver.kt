package com.benjaminissa.issareader.epub

import com.benjaminissa.issareader.core.model.removingPercentEncoding

/**
 * Finds the face a book asks to be set in.
 *
 * Two questions, both answered out of the book's own CSS: which files it
 * embeds, and which family its running text is set in. The cascade itself
 * lives in [EpubStyleSheet]; this is only about fonts.
 *
 * That is the whole of "the publisher's font" as an option beside Newsreader
 * and Public Sans: one family for the running text, which is what a reader
 * means by it — but *every member* of that family, which is what makes a word
 * in italic look italic. A family registered with only its upright member is a
 * book with no emphasis in it, and one registered with only its italic member
 * is a book entirely in italic; both have happened here.
 *
 * An obfuscated font is reported, never deobfuscated: [Unavailable.Obfuscated].
 */
object EpubFontResolver {
    /** A face a book ships, resolved to something that can be registered. */
    data class Face(
        /** The family as the stylesheet names it. */
        val family: String,
        /** Where the file is inside the container. */
        val path: String,
        /**
         * Which member of the family this file is, as the rule declares it.
         *
         * A stylesheet lists one `@font-face` per member, and nothing but these
         * two descriptors distinguishes them. Reading them is what lets the
         * *upright* member be the one the page is set in: taking the first rule
         * instead set one real book entirely in italic, because that is the
         * order its publisher happened to write them in.
         */
        val isItalic: Boolean = false,
        val isBold: Boolean = false,
    ) {
        /**
         * The file's extension, lowercased.
         *
         * [path] carries no query string — see [fontFaces], which strips it
         * before resolving. The first fix for the bulletproof
         * `url('fonts/Charis.otf?#iefix')` syntax stripped it *here* only, so
         * `format` said "otf" while `path` still ended in `?`: the face was
         * reported found and then failed silently in `archive.read`, which is
         * worse than the `UnreadableFormat("otf?")` it replaced.
         */
        val format: String get() = path.pathExtension.lowercase()
    }

    /** Why a book cannot be set in its own face. */
    sealed interface Unavailable {
        /** No `@font-face` rule anywhere, which is most of Project Gutenberg. */
        data object NoEmbeddedFont : Unavailable

        /** The font is there, in a format the platform's font loader cannot read. */
        data class UnreadableFormat(val format: String) : Unavailable

        /**
         * Obfuscated per the IDPF or Adobe scheme, and this app does not
         * deobfuscate. The bytes on disk are not a font.
         */
        data object Obfuscated : Unavailable
    }

    sealed interface Resolution {
        data class Found(val face: Face) : Resolution
        data class Unavailable(val reason: EpubFontResolver.Unavailable) : Resolution
    }

    /** The formats a face may be registered in: OpenType and TrueType, single or collected. */
    private val registrableFormats = setOf("otf", "ttf", "ttc", "otc")

    /** The body face this book asks for. */
    fun resolve(epubPackage: EpubPackage): Resolution {
        val obfuscated = obfuscatedPaths(epubPackage)
        val embedded = members(epubPackage)
        if (embedded.isEmpty()) return Resolution.Unavailable(Unavailable.NoEmbeddedFont)

        // The body's own family first; failing that, the single family the
        // book embeds. A book that embeds exactly one family means it for the
        // text.
        val candidates = bodyFamilies(epubPackage).mapNotNull { embedded[it.lowercase()] }
        val chosen = candidates.firstOrNull() ?: if (embedded.size == 1) embedded.values.first() else null
        val representative = chosen?.let(::upright) ?: return Resolution.Unavailable(Unavailable.NoEmbeddedFont)

        if (representative.path in obfuscated) return Resolution.Unavailable(Unavailable.Obfuscated)
        if (representative.format !in registrableFormats) {
            return Resolution.Unavailable(Unavailable.UnreadableFormat(representative.format))
        }
        return Resolution.Found(representative)
    }

    /**
     * Every face of one family the book embeds, in declaration order.
     *
     * What the publisher-font registration registers. The upright regular is
     * the face the page is set in; the others are what the font system needs
     * in order to have an italic to resolve to when a word asks for one — it is
     * never synthesised, so a missing member is a missing italic.
     */
    fun members(family: String, epubPackage: EpubPackage): List<Face> {
        val obfuscated = obfuscatedPaths(epubPackage)
        return (members(epubPackage)[family.lowercase()] ?: emptyList())
            .filter { it.format in registrableFormats }
            .filter { it.path !in obfuscated }
    }

    /** Every embedded face, grouped by lowercased family. */
    internal fun members(epubPackage: EpubPackage): Map<String, List<Face>> {
        val faces = LinkedHashMap<String, MutableList<Face>>()
        for (sheet in stylesheets(epubPackage)) {
            val text = css(sheet, epubPackage) ?: continue
            for (face in fontFaces(text, sheet)) {
                faces.getOrPut(face.family.lowercase()) { ArrayList() }.add(face)
            }
        }
        return faces
    }

    /**
     * The upright, regular member of a family, or the first there is.
     *
     * Falling back to the first matters: a book may embed only an italic, and
     * setting the page in it is still better than ignoring the book's face —
     * but it is a last resort, not the default it used to be.
     */
    internal fun upright(members: List<Face>): Face? = members.firstOrNull { !it.isItalic && !it.isBold } ?: members.firstOrNull()

    internal fun css(href: String, epubPackage: EpubPackage): String? {
        val data = try {
            epubPackage.archive.read(href)
        } catch (_: EpubError) {
            return null
        }
        return decodeUtf8OrLatin1(data)
    }

    // Reading the CSS

    /**
     * Every stylesheet the book declares, sorted by path.
     *
     * Public because the renderer reads the same list for the same book: this
     * answers "which files", and [EpubStyleSheet] answers what is in them.
     */
    fun stylesheets(epubPackage: EpubPackage): List<String> = epubPackage.manifest.values
        .filter { it.mediaType == "text/css" || it.href.lowercase().endsWith(".css") }
        .map { it.href }
        .sorted()

    /**
     * Everything before the first `?`. Written once here rather than inline,
     * because the last inline copy lived on the wrong property.
     */
    internal fun withoutQuery(url: String): String = url.swiftSplit('?', maxSplits = 1).firstOrNull() ?: url

    /** `@font-face { font-family: X; src: url(Y) }`, and nothing else. */
    internal fun fontFaces(css: String, relativeTo: String): List<Face> {
        val faces = ArrayList<Face>()
        for (block in blocks("@font-face", css)) {
            val family = value("font-family", block)?.let(::unquote) ?: continue
            if (family.isEmpty()) continue
            val source = firstUrl(value("src", block) ?: "") ?: continue
            val style = (value("font-style", block) ?: "").lowercase()
            faces.add(
                Face(
                    family = family,
                    // Query stripped before resolving, so `path` is the archive
                    // path `archive.read` will be handed. `EpubPackage.resolve`
                    // strips a fragment but not a query, and publishers ship
                    // `url('fonts/Charis.otf?#iefix')`.
                    path = EpubPackage.resolve(withoutQuery(source), relativeTo),
                    // Lowercased like the weight below: CSS keywords are
                    // case-insensitive, and `Italic` read as upright made the
                    // italic file the face the page was set in.
                    isItalic = "italic" in style || "oblique" in style,
                    isBold = EpubStyleSheet.isBold(
                        (value("font-weight", block) ?: "").trimmingWhitespaceAndNewlines().lowercase(),
                    ) ?: false,
                ),
            )
        }
        return faces
    }

    /**
     * The families this book's running text is set in, most likely first.
     *
     * A bare `body` or `html` rule is the easy case and comes first. Failing
     * that, the book's own `<body>` element is read — its class and its id —
     * and the cascade asked what that element is set in. That second route is
     * not exotic: an InDesign export writes `<body class="class-1">` against
     * `.class-1 {font-family: AGaramondPro}` and never mentions `body` at all,
     * so before it, a book that plainly embeds and names a face reported that
     * it had none.
     */
    internal fun bodyFamilies(epubPackage: EpubPackage): List<String> {
        val families = ArrayList<String>()
        var sheet = EpubStyleSheet()
        for (href in stylesheets(epubPackage)) {
            val text = css(href, epubPackage) ?: continue
            families.addAll(bodyFontFamilies(text))
            sheet = sheet.adding(text)
        }
        if (sheet.isEmpty) return families
        // The first document that has a <body> with anything on it. They are
        // all set the same way, and reading one is enough.
        for (item in epubPackage.spine.take(3)) {
            val data = try {
                epubPackage.archive.read(item.href)
            } catch (_: EpubError) {
                continue
            }
            val body = bodyAttributes(decodeUtf8OrLatin1(data)) ?: continue
            val asked = sheet.declarations(
                tag = "body", classes = body["class"], identifier = body["id"], inlineStyle = body["style"],
            )
            val declared = asked.families
            if (declared != null) {
                families.addAll(declared)
                break
            }
        }
        return families
    }

    /**
     * The attributes on a document's `<body>` open tag.
     *
     * Scanned rather than parsed, and deliberately: an XHTML chapter routinely
     * names HTML entities that XML does not define, which fails a strict parse
     * outright — the renderer rewrites them first, and it would be a poor trade
     * to do that whole pass here so that a *font* heuristic can read two
     * attributes off one tag. The tag is the first `<body` in the file.
     */
    internal fun bodyAttributes(html: String): Map<String, String>? {
        val start = html.indexOf("<body", ignoreCase = true)
        if (start < 0) return null
        val tagStart = start + "<body".length
        val end = html.indexOf('>', tagStart)
        if (end < 0) return null
        val attributes = LinkedHashMap<String, String>()
        var rest = html.substring(tagStart, end)
        while (true) {
            val equals = rest.indexOf('=')
            if (equals < 0) break
            val name = rest.substring(0, equals).trimmingWhitespaceAndNewlines().lowercase()
            var value = rest.substring(equals + 1).dropWhile { it == ' ' || it == '\n' || it == '\t' }
            val quote = value.firstOrNull()
            if (quote != '"' && quote != '\'') break
            value = value.substring(1)
            val closing = value.indexOf(quote)
            if (closing < 0) break
            if (name.isNotEmpty() && ' ' !in name) attributes[name] = value.substring(0, closing)
            rest = value.substring(closing + 1)
        }
        return attributes.ifEmpty { null }
    }

    /** The families a `body` or `html` rule sets, most specific first. */
    internal fun bodyFontFamilies(css: String): List<String> {
        val families = ArrayList<String>()
        for (selector in listOf("body", "html")) {
            for (block in blocks(selector, css)) {
                val declared = value("font-family", block) ?: continue
                families.addAll(
                    declared.swiftSplit(',')
                        .map { unquote(it.trimmingWhitespaceAndNewlines()) }
                        .filter { it.isNotEmpty() },
                )
            }
        }
        return families
    }

    /** Bodies of every rule whose selector list mentions `name` as a whole word. */
    internal fun blocks(name: String, css: String): List<String> {
        val blocks = ArrayList<String>()
        val selector = StringBuilder()
        var depth = 0
        val body = StringBuilder()
        for (character in stripComments(css)) {
            if (character == '{') {
                depth += 1
                if (depth == 1) {
                    body.setLength(0)
                    continue
                }
            }
            if (character == '}') {
                depth -= 1
                if (depth == 0) {
                    if (matches(name, selector.toString())) blocks.add(body.toString())
                    selector.setLength(0)
                    continue
                }
            }
            // A `;` at the top level ends a braceless at-rule — `@charset`,
            // `@import`, `@namespace`. Without this reset their text glues
            // itself onto the next rule's selector, and `matches` (an exact
            // equality test, deliberately) then rejects that rule outright.
            if (depth == 0 && character == ';') {
                selector.setLength(0)
                continue
            }
            if (depth == 0) selector.append(character) else body.append(character)
        }
        return blocks
    }

    /**
     * Removes `/* ... */` comments, which CSS permits anywhere. Left in, a
     * comment ahead of a rule becomes part of its selector, and a comment
     * inside a block corrupts the declaration it interrupts — either way a
     * perfectly ordinary stylesheet loses its `@font-face` or `body` rule.
     */
    internal fun stripComments(css: String): String = EpubStyleSheet.stripComments(css)

    /**
     * Whether a selector list targets `name` plainly — `body`, or `html, body`.
     *
     * `body.chapter` and `#body` do not count: they are the cascade, and the
     * cascade is exactly what is not being implemented.
     */
    internal fun matches(name: String, selector: String): Boolean =
        selector.swiftSplit(',').map { it.trimmingWhitespaceAndNewlines().lowercase() }.contains(name.lowercase())

    /** A declaration's value, by property name. */
    internal fun value(property: String, block: String): String? {
        for (declaration in block.swiftSplit(';')) {
            val parts = declaration.swiftSplit(':', maxSplits = 1)
            if (parts.size != 2) continue
            val name = parts[0].trimmingWhitespaceAndNewlines().lowercase()
            if (name != property.lowercase()) continue
            return parts[1].trimmingWhitespaceAndNewlines()
        }
        return null
    }

    /**
     * The first `url(...)` in a `src` list.
     *
     * `src` may list several formats; the first is taken and then checked, so a
     * book listing WOFF2 before OTF reports the format it named first. That is
     * a deliberate simplification, and the reason `UnreadableFormat` says which
     * format it found.
     */
    internal fun firstUrl(source: String): String? {
        val start = source.indexOf("url(")
        if (start < 0) return null
        val end = source.indexOf(')', start + 4)
        if (end < 0) return null
        val cleaned = unquote(source.substring(start + 4, end).trimmingWhitespaceAndNewlines())
        return cleaned.nonEmpty
    }

    internal fun unquote(text: String): String = EpubStyleSheet.unquote(text)

    // Obfuscation

    /**
     * Paths `META-INF/encryption.xml` says are obfuscated.
     *
     * EPUB permits a publisher to scramble the first 1040 bytes of a font so it
     * cannot be lifted out of the book. Registering those bytes produces
     * nothing; the reader is told the book's font cannot be used instead.
     */
    internal fun obfuscatedPaths(epubPackage: EpubPackage): Set<String> {
        val root = try {
            EpubXml.parse(epubPackage.archive.read("META-INF/encryption.xml"))
        } catch (_: EpubError) {
            return emptySet()
        }
        val paths = HashSet<String>()
        for (reference in root.descendants("CipherReference")) {
            val uri = reference.attributes["URI"] ?: continue
            // Normalised, because `representative.path` came through
            // `EpubArchive.normalize` and this is compared against it. Adobe
            // InDesign and several Java toolchains write
            // `URI="./OEBPS/fonts/Body.otf"`, so the two spellings never
            // matched, the guard missed, and the font system was handed 1040
            // XOR-scrambled bytes as a font — the book rendered in a broken face
            // instead of reporting `Obfuscated`.
            val decoded = uri.removingPercentEncoding() ?: uri
            paths.add(EpubArchive.normalize(decoded))
        }
        return paths
    }
}
