package com.benjaminissa.issareader.epub

import com.benjaminissa.issareader.core.model.asProgression
import com.benjaminissa.issareader.core.model.removingPercentEncoding
import java.io.File

/** An opened EPUB: its package document, spine, manifest and navigation. */
data class EpubPackage(
    val archive: EpubArchive,
    /** Directory the OPF lives in; every manifest href resolves against it. */
    val rootDirectory: String,
    val metadata: Metadata,
    /**
     * By manifest id, in the manifest's own order. (Swift's is a dictionary,
     * so its "first" item of a kind is whichever hashes first; here it is the
     * first the book lists.)
     */
    val manifest: Map<String, ManifestItem>,
    val spine: List<SpineItem>,
    val navigation: List<NavPoint>,
    /**
     * Archive paths of the documents the book itself names as apparatus rather
     * than story — the cover, the title page, the dedication, the copyright
     * notice, the contents. See `parseFrontMatter` for the rule.
     */
    val frontMatter: Set<String>,
    /**
     * Each spine item's uncompressed size, read once from the ZIP central
     * directory. Used to weight its share of the book.
     */
    val spineWeights: List<Double>,
) {
    data class Metadata(
        val title: String? = null,
        val language: String? = null,
        val authors: List<String> = emptyList(),
        val identifier: String? = null,
        /**
         * `media:duration` without a refines attribute — the whole book's
         * narration length, present only on aligned EPUBs.
         */
        val mediaDuration: Double? = null,
        /**
         * The CSS class the reading system should apply to the active
         * media-overlay fragment. Storyteller writes
         * `-epub-media-overlay-active`, with a leading hyphen, which differs
         * from the spec's usual example — so this must be read, not assumed.
         */
        val mediaActiveClass: String? = null,

        // What a book read from the reader's own files is described by. A
        // server book carries all of this in its catalogue row, so nothing
        // that opens one reads these; a local book has nothing else.

        /**
         * Every `dc:creator` and `dc:contributor`, in document order, with the
         * role and sort name each was given.
         *
         * Beside [authors] rather than replacing it: [authors] is every
         * creator's name whatever its role, which is what it has always been,
         * and changing what it means would change it for every reader of a
         * server book.
         */
        val contributors: List<Contributor> = emptyList(),
        /** The title the book marks as its subtitle (`title-type`), if any. */
        val subtitle: String? = null,
        val description: String? = null,
        val publisher: String? = null,
        /** `dc:date` as written: a year, a day or a timestamp. */
        val date: String? = null,
        /**
         * The `dc:identifier` the package names as its unique identifier,
         * falling back to the first one. What makes two copies of a book the
         * same book when their bytes differ.
         */
        val uniqueIdentifier: String? = null,
        /**
         * The series the book declares — an EPUB 3 collection of type
         * `series`, else Calibre's `calibre:series`.
         */
        val series: Series? = null,
        /** The `version` attribute of `<package>`: "2.0", "3.0", "3.3". */
        val version: String? = null,
        /**
         * Whether the book is laid out as fixed pages (`rendition:layout` of
         * `pre-paginated`, or the older `fixed-layout` meta).
         */
        val isFixedLayout: Boolean = false,
        /** The manifest id an EPUB 2 `<meta name="cover">` names. */
        val coverId: String? = null,
    ) {
        /** Whether this is an EPUB 2 book, by its declared version. */
        val isEpub2: Boolean get() = version?.startsWith("2") ?: false
    }

    /** A creator or contributor, as the package declares them. */
    data class Contributor(
        val name: String,
        /** The name as it sorts: "Barrie, J. M.". */
        val fileAs: String? = null,
        /** The MARC relator code — `aut`, `nrt`, `trl`, `ill` — when one is given, lowercased. */
        val role: String? = null,
        /**
         * `dc:creator` rather than `dc:contributor`. A creator with no role is
         * an author by the spec's own reading; a contributor with none is not.
         */
        val isCreator: Boolean = true,
    )

    data class Series(
        val name: String,
        /** Where in the series, when the book says. */
        val position: Double? = null,
    )

    data class ManifestItem(
        val id: String,
        /** Archive-relative, already resolved against the OPF directory. */
        val href: String,
        val mediaType: String,
        val properties: List<String>,
        /** Manifest id of this item's SMIL overlay, when it has one. */
        val mediaOverlay: String?,
        /**
         * Where it sits in the manifest, first at 0: [manifest] is keyed by
         * id, and a rule that takes "the first" has to mean the book's order.
         */
        val documentOrder: Int = 0,
    )

    data class SpineItem(
        val idref: String,
        val linear: Boolean,
        val href: String,
        val mediaOverlayId: String?,
    )

    data class NavPoint(
        val title: String,
        /** Archive path of the document, with any fragment removed. */
        val href: String,
        /**
         * Element id the entry points at, when it targets part of a document.
         *
         * Books that pack many chapters into a few large spine files — which
         * Gutenberg's do — distinguish their chapters only by this fragment.
         * Dropping it collapses a seventeen-chapter book to four entries.
         */
        val fragment: String? = null,
        val depth: Int = 0,
    )

    /**
     * How far through the book a position in a spine item is, 0...1.
     *
     * Weighted by each item's uncompressed size rather than by its index, so
     * the number means something on a book whose chapters differ in length.
     * Sizes come from the ZIP central directory, which was already read when
     * the container was opened, so this costs no inflation and no parsing.
     *
     * This is the `totalProgression` saved to the server, so it is computed in
     * exactly the order the Swift side computes it.
     */
    fun bookProgress(spineIndex: Int, within: Double): Double {
        if (spineIndex !in spine.indices) return 0.0
        val weights = spineWeights
        var total = 0.0
        for (weight in weights) total += weight
        if (total <= 0) {
            // No sizes available: fall back to counting items equally.
            return (spineIndex.toDouble() + within) / spine.size.toDouble()
        }
        var before = 0.0
        for (index in 0 until minOf(spineIndex, weights.size)) before += weights[index]
        // `asProgression`, not `coerceIn`: a clamp passes NaN straight through,
        // and the Swift reader's `spinePosition` then fed `Int(scaled)` a NaN,
        // which traps.
        val place = within.asProgression ?: 0.0
        return ((before + weights[spineIndex] * place) / total).asProgression ?: 0.0
    }

    /**
     * The archive paths of the documents that *are* the navigation.
     *
     * The EPUB 3 navigation document (`properties="nav"`) and the EPUB 2 NCX,
     * both read straight out of the manifest, which is exact: those two
     * declarations are what a producer writes to say "this file is the table of
     * contents", and nothing inferred from the text can be as reliable.
     *
     * Most books keep them out of the spine — both Gutenberg fixtures do — but
     * plenty of EPUB 3 books put the nav document in it so the reader can page
     * to the contents like any other section. Those are the ones anything
     * reading the spine has to be able to tell from a chapter: a list of chapter
     * titles is not prose, and the Ask index cites it as evidence.
     */
    val navigationDocuments: Set<String>
        get() = manifest.values
            .filter { "nav" in it.properties || it.mediaType == ncxMediaType }
            .map { it.href }
            .toSet()

    companion object {
        /**
         * What an EPUB 2 table of contents is declared as in the manifest.
         *
         * Written down once, because `parseNavigation` looks for it and so does
         * [navigationDocuments], and the two disagreeing would mean a book whose
         * contents is read as navigation in one place and as a chapter in the
         * other.
         */
        const val ncxMediaType = "application/x-dtbncx+xml"

        /** Opens an EPUB from a file on disk. */
        fun open(file: File): EpubPackage = open(EpubArchive(file))

        fun open(archive: EpubArchive): EpubPackage {
            val containerData = archive.read("META-INF/container.xml")
            val container = EpubXml.parse(containerData)
            val rawOpfPath = container.descendants("rootfile").firstOrNull()?.get("full-path")
                ?: throw EpubError.MalformedPackage("container.xml has no rootfile")
            // A URI, like every href — see `resolve` for why it is decoded.
            val opfPath = rawOpfPath.removingPercentEncoding() ?: rawOpfPath

            val rootDirectory = opfPath.deletingLastPathComponent
            val opf = EpubXml.parse(archive.read(opfPath))

            val metadata = parseMetadata(opf)
            val manifest = parseManifest(opf, rootDirectory)
            val spine = parseSpine(opf, manifest)
            // Read here rather than inside each parse: the contents and the
            // landmarks are two `<nav>` elements of one document, and inflating
            // and parsing that document twice to read one of each buys nothing.
            // With HTML entities substituted, as a chapter's are: the nav
            // document is XHTML an author wrote, and one `&nbsp;` in a title
            // failed the parse and left the book with no contents.
            val navigationDocument = manifest.values
                .firstOrNull { "nav" in it.properties }
                ?.let { item ->
                    try {
                        NavigationDocument(EpubXml.parse(archive.read(item.href), substitutingHtmlEntities = true), item.href)
                    } catch (_: EpubError) {
                        null
                    }
                }
            val navigation = try {
                parseNavigation(archive, manifest, navigationDocument)
            } catch (_: EpubError) {
                emptyList()
            }
            // From the central directory, which was already read when the
            // container was opened — no inflation, no parsing. Hoisted out of
            // the constructor because the front-matter rule weighs a document
            // against the rest of the spine, and these are the sizes it weighs.
            val spineWeights = spine.map { (archive.sizeOf(it.href) ?: 0L).toDouble() }

            return EpubPackage(
                archive = archive,
                rootDirectory = rootDirectory,
                metadata = metadata,
                manifest = manifest,
                spine = spine,
                navigation = navigation,
                frontMatter = parseFrontMatter(opf, opfPath, navigationDocument, spine, spineWeights),
                spineWeights = spineWeights,
            )
        }

        /** The part of an href after `#`, if any. */
        fun fragmentIdentifier(href: String): String? {
            val hash = href.indexOf('#')
            if (hash < 0) return null
            return href.substring(hash + 1).nonEmpty
        }

        /**
         * Resolves an href that appears inside `base` to an archive path.
         *
         * Hrefs are URIs, so a space in a filename arrives as `%20` and an
         * accented letter as UTF-8 escapes — Calibre and Sigil encode them as a
         * matter of course — while the ZIP entry name holds the raw characters.
         * Decoding happens here, the funnel every href passes through, so
         * `Chapter%201.xhtml` finds the entry `Chapter 1.xhtml`. Only the path
         * is decoded, after the fragment is stripped; a sloppy unencoded href
         * with a bare `%` fails to decode and is kept verbatim, which is what
         * its producer meant by it.
         */
        fun resolve(href: String, relativeTo: String): String {
            // Everything before the first `#`, keeping an empty piece. For a
            // fragment-only href — `#chapter-1`, what a single-file book's nav
            // uses and what `NavPoint.fragment` exists for — Swift's default
            // split dropped the empty leading piece, so the target was
            // "chapter-1" rather than "", and every row of such a book's table
            // of contents pointed at a missing resource.
            val target = href.substringBefore('#')
            // A pure fragment names the document it sits in.
            if (target.isEmpty()) return EpubArchive.normalize(relativeTo)
            val decoded = target.removingPercentEncoding() ?: target
            if (decoded.startsWith("/")) return EpubArchive.normalize(decoded)
            val directory = relativeTo.deletingLastPathComponent
            val joined = if (directory.isEmpty()) decoded else "$directory/$decoded"
            return EpubArchive.normalize(joined)
        }

        // Parsing

        fun parseMetadata(opf: EpubXmlNode): Metadata {
            val version = opf["version"]?.trimmingWhitespace()
            val node = opf.firstChild("metadata") ?: opf.descendants("metadata").firstOrNull()
                ?: return Metadata(version = version)
            val title = node.descendants("title").firstOrNull()?.trimmedText
            val language = node.descendants("language").firstOrNull()?.trimmedText
            val identifier = node.descendants("identifier").firstOrNull()?.trimmedText
            val authors = node.descendants("creator").map { it.trimmedText }.filter { it.isNotEmpty() }

            // EPUB 3 says everything about an element through `<meta refines>`,
            // keyed by the element's id; collected first so the elements below
            // can look themselves up in one pass.
            val refinements = HashMap<String, HashMap<String, String>>()
            for (meta in node.descendants("meta")) {
                val property = meta["property"] ?: continue
                val refines = meta["refines"] ?: continue
                if (!refines.startsWith("#")) continue
                val value = meta.trimmedText
                if (value.isEmpty()) continue
                // The first one wins, as a reading system takes it.
                refinements.getOrPut(refines.substring(1)) { HashMap() }.putIfAbsent(property, value)
            }
            fun refined(element: EpubXmlNode, property: String): String? =
                element["id"]?.let { refinements[it]?.get(property) }

            // Both element names in one walk, so the order is the document's: a
            // contributor written between two creators stays between them.
            fun people(parent: EpubXmlNode): List<EpubXmlNode> = parent.children.flatMap { child ->
                if (child.name == "creator" || child.name == "contributor") listOf(child) else people(child)
            }
            val contributors = ArrayList<Contributor>()
            for (element in people(node)) {
                val text = element.trimmedText
                if (text.isEmpty()) continue
                // `opf:role` and `opf:file-as` are EPUB 2's spelling; the XML
                // helper indexes a prefixed attribute under its local name too.
                val role = (refined(element, "role") ?: element["role"])?.trimmingWhitespace()?.lowercase()
                contributors.add(
                    Contributor(
                        name = text,
                        fileAs = refined(element, "file-as") ?: element["file-as"],
                        role = role?.nonEmpty,
                        isCreator = element.name == "creator",
                    ),
                )
            }

            val subtitle = node.descendants("title")
                .firstOrNull { refined(it, "title-type")?.lowercase() == "subtitle" }
                ?.trimmedText
            val description = node.descendants("description").firstOrNull()?.allText
                ?.trimmingWhitespaceAndNewlines()
                ?.nonEmpty
            val publisher = node.descendants("publisher").firstOrNull()?.trimmedText?.nonEmpty
            val date = node.descendants("date").firstOrNull()?.trimmedText?.nonEmpty

            // The unique identifier is the one `<package unique-identifier>`
            // names by id. The first identifier is often an ISBN while the
            // unique one is a uuid, or the other way round, so the attribute is
            // read rather than the order assumed.
            val identifiers = node.descendants("identifier")
            val uniqueIdentifier = (
                opf["unique-identifier"]?.let { id -> identifiers.firstOrNull { it["id"] == id } }
                    ?: identifiers.firstOrNull()
                )?.trimmedText?.nonEmpty

            var coverId: String? = null
            var isFixedLayout = false
            var mediaDuration: Double? = null
            var mediaActiveClass: String? = null
            var series: Series? = null
            var calibreSeries: String? = null
            var calibreIndex: Double? = null
            for (meta in node.descendants("meta")) {
                // EPUB 2's `<meta name content>`, which EPUB 3 books keep for
                // older reading systems: the cover's id, Calibre's series and the
                // fixed-layout flag several retailers wrote before EPUB 3 had one.
                val name = meta["name"]
                val content = meta["content"]
                if (name != null && content != null) {
                    when (name) {
                        "cover" -> coverId = coverId ?: content.trimmingWhitespace()
                        "calibre:series" -> calibreSeries = content.trimmingWhitespace().nonEmpty
                        "calibre:series_index" -> calibreIndex = seriesPosition(content)
                        "fixed-layout" -> if (content.lowercase() == "true") isFixedLayout = true
                    }
                }
                val property = meta["property"] ?: continue
                val unrefined = meta["refines"] == null
                when {
                    property == "media:duration" && unrefined ->
                        mediaDuration = SmilClock.seconds(meta.trimmedText)
                    property == "media:active-class" ->
                        mediaActiveClass = meta.trimmedText
                    property == "rendition:layout" && unrefined ->
                        if (meta.trimmedText == "pre-paginated") isFixedLayout = true
                    property == "belongs-to-collection" && unrefined && series == null -> {
                        // A collection is a series only when it says so; one
                        // with no type is a set the publisher grouped, which is
                        // the next best thing and what reading systems show for
                        // it.
                        val type = refined(meta, "collection-type")?.lowercase()
                        if ((type == null || type == "series") && meta.trimmedText.isNotEmpty()) {
                            series = Series(
                                name = meta.trimmedText,
                                position = refined(meta, "group-position")?.let(::seriesPosition),
                            )
                        }
                    }
                }
            }
            if (series == null && calibreSeries != null) series = Series(calibreSeries, calibreIndex)
            return Metadata(
                title = title,
                language = language,
                authors = authors,
                identifier = identifier,
                mediaDuration = mediaDuration,
                mediaActiveClass = mediaActiveClass,
                contributors = contributors,
                subtitle = subtitle,
                description = description,
                publisher = publisher,
                date = date,
                uniqueIdentifier = uniqueIdentifier,
                series = series,
                version = version,
                isFixedLayout = isFixedLayout,
                coverId = coverId,
            )
        }

        /**
         * A series position, or null when the text is not a finite number.
         *
         * Swift's `Double(_:)` accepts "NaN", "inf", "Infinity" and "1e999",
         * and some tools write "NaN" for a book with no number. A non-finite
         * position reached the stored row, whose JSON encoder refuses it, so
         * the book could never be added: "Couldn't copy this book", and a Try
         * Again that could never succeed.
         */
        fun seriesPosition(text: String): Double? = swiftDouble(text.trimmingWhitespace())?.takeIf { it.isFinite() }

        private fun parseManifest(opf: EpubXmlNode, rootDirectory: String): Map<String, ManifestItem> {
            val manifestNode = opf.descendants("manifest").firstOrNull() ?: return emptyMap()
            val items = LinkedHashMap<String, ManifestItem>()
            for ((order, item) in manifestNode.children("item").withIndex()) {
                val id = item["id"] ?: continue
                val rawHref = item["href"] ?: continue
                // A URI, like every href — see `resolve` for why it is decoded.
                val href = rawHref.removingPercentEncoding() ?: rawHref
                val resolved = if (rootDirectory.isEmpty()) {
                    EpubArchive.normalize(href)
                } else {
                    EpubArchive.normalize("$rootDirectory/$href")
                }
                items[id] = ManifestItem(
                    id = id,
                    href = resolved,
                    mediaType = item["media-type"] ?: "application/octet-stream",
                    properties = (item["properties"] ?: "").swiftSplit(' '),
                    mediaOverlay = item["media-overlay"],
                    documentOrder = order,
                )
            }
            return items
        }

        private fun parseSpine(opf: EpubXmlNode, manifest: Map<String, ManifestItem>): List<SpineItem> {
            val spineNode = opf.descendants("spine").firstOrNull() ?: return emptyList()
            return spineNode.children("itemref").mapNotNull { ref ->
                val idref = ref["idref"] ?: return@mapNotNull null
                val item = manifest[idref] ?: return@mapNotNull null
                SpineItem(
                    idref = idref,
                    linear = (ref["linear"] ?: "yes") != "no",
                    href = item.href,
                    // An itemref may override the manifest item's overlay.
                    mediaOverlayId = ref["media-overlay"] ?: item.mediaOverlay,
                )
            }
        }

        /**
         * The `epub:type` tokens declared on a node.
         *
         * `epub:type` holds a space-separated token list, so `"toc bodymatter"`
         * is a table of contents and an equality test says it is not. Both
         * spellings of the attribute are read because [EpubXml] indexes
         * attributes under the qualified name and the local one, and books use
         * either.
         *
         * A fresh set per call, per node, and that is left alone deliberately.
         * This runs once per landmark and once per `<nav>` while a book is being
         * opened — tens of calls against an archive that has just been inflated
         * and XML-parsed — so the allocations are far below the noise floor of
         * the work around them, and caching them would trade a measurable
         * nothing for a second place where a node's tokens are decided.
         */
        private fun types(node: EpubXmlNode): Set<String> {
            val tokens = HashSet<String>()
            for (declared in listOfNotNull(node["type"], node["epub:type"])) {
                tokens.addAll(declared.swiftSplit { it.isSwiftWhitespace() })
            }
            return tokens
        }

        private fun hasType(token: String, node: EpubXmlNode): Boolean = token in types(node)

        private class NavigationDocument(val document: EpubXmlNode, val href: String)

        private fun parseNavigation(
            archive: EpubArchive,
            manifest: Map<String, ManifestItem>,
            navigationDocument: NavigationDocument?,
        ): List<NavPoint> {
            // EPUB 3 navigation document first, NCX as the fallback for older
            // books.
            //
            // The fallback has to cover a navigation document that is *there
            // but broken* as well as one that is absent: a throw here used to
            // abort the whole function, and the caller's catch then showed no
            // contents at all with a perfectly good NCX unread in the manifest.
            if (navigationDocument != null) {
                for (navElement in navigationDocument.document.descendants("nav")) {
                    // `epub:type` is a space-separated token list per spec, so
                    // exact equality skipped `epub:type="toc bodymatter"`
                    // entirely and such a book showed no contents at all.
                    if (!hasType("toc", navElement)) continue
                    // `<ul>` as well as `<ol>`: several conversion tools emit
                    // it, invalidly but commonly.
                    val list = navElement.descendants("ol").firstOrNull() ?: navElement.descendants("ul").firstOrNull()
                    val points = flatten(list, navigationDocument.href, depth = 0)
                    // Only return when there is something to return. An empty
                    // result used to short-circuit the NCX below, so a nav
                    // document that *parsed* but yielded nothing — a `<ul>`, or
                    // list items carrying headings with no anchor — left the
                    // reader with no table of contents while a perfectly good
                    // toc.ncx sat unread in the manifest. The comment above
                    // promised this fallback covered "there but broken"; it
                    // only covered "throws".
                    if (points.isNotEmpty()) return points
                }
            }
            val ncx = manifest.values.firstOrNull { it.mediaType == ncxMediaType } ?: return emptyList()
            // Substituted for the same reason as the nav document above.
            val document = EpubXml.parse(archive.read(ncx.href), substitutingHtmlEntities = true)
            return document.descendants("navPoint").mapNotNull { point ->
                val label = point.descendants("text").firstOrNull()?.trimmedText ?: return@mapNotNull null
                val href = point.descendants("content").firstOrNull()?.get("src") ?: return@mapNotNull null
                NavPoint(
                    title = label,
                    href = resolve(href, ncx.href),
                    fragment = fragmentIdentifier(href),
                    depth = 0,
                )
            }
        }

        // Front matter

        /**
         * `epub:type` tokens that name a document as apparatus, not story.
         *
         * Both vocabularies, because the same rule reads EPUB 3 landmarks and
         * the EPUB 2 `<guide>`: `titlepage` is the structural-semantics spelling
         * and `title-page` the guide's, and a book gets to use either.
         */
        private val frontMatterTypes = setOf(
            "cover", "titlepage", "title-page", "halftitlepage", "copyright-page",
            "dedication", "acknowledgments", "acknowledgements", "toc", "toc-brief",
            "landmarks", "loi", "lot", "colophon",
        )

        /**
         * `epub:type` tokens that name a document as story, whatever else it is
         * also called. Any one of these vetoes an exclusion.
         *
         * `epigraph` is on this list deliberately: a novel whose chapter
         * epigraphs carry an in-world document — a journal, a chronicle, a set
         * of letters — is telling its story in them as much as in the chapters.
         * `preface`, `foreword` and `introduction` are here for the same reason
         * — a preface can be in-fiction, and a false positive deletes real
         * prose, which is a far worse failure than leaving apparatus in the
         * index.
         */
        private val storyTypes = setOf(
            "prologue", "chapter", "part", "volume", "division", "epilogue",
            "preface", "foreword", "introduction", "epigraph", "afterword",
            "conclusion", "appendix", "glossary", "index", "bibliography",
            "notes", "endnotes", "rearnotes", "footnotes",
        )

        /**
         * The documents the book itself names as apparatus rather than story.
         *
         * Read from the EPUB 3 landmarks nav, falling back to the EPUB 2
         * `<guide>` for books that have no landmarks. Measured on a real novel,
         * sixteen front-matter passages — the dedication, the acknowledgments,
         * the author's preface — reached the model as evidence, and it answered
         * from them.
         *
         * **Only tokens naming a kind of content count, in either direction:
         * `bodymatter` and `frontmatter` are consulted for nothing.** The two
         * obvious designs both rest on those broad tokens and both were
         * verified wrong on the same book. Its `bodymatter` landmark points at
         * `title.xhtml#tit` — the *title page* — so "everything before the
         * bodymatter anchor is front matter" excludes the cover and nothing
         * else; and the novel's actual Prologue is a document declaring
         * `<body epub:type="frontmatter">`, so a body-level rule deletes the
         * prologue. Publishers use the structural tokens positionally, to mark
         * where a reading system should open the book, and position is not a
         * claim about what a document holds.
         *
         * The guards that follow from that:
         *
         * - **Only a fragmentless href may exclude a document.** Verified
         *   against a shipped fixture: Franklin's guide points its `toc`
         *   reference at `…20203-h-0.htm.html#pgepubid00004`, and that same
         *   document also holds the editor's Introduction and Chapter I.
         *   `resolve` strips fragments, so without this the guide deletes about
         *   46 KB of the book. A story tag is still collected from a fragmented
         *   href, because vetoing errs towards keeping prose.
         * - **A story tag vetoes an exclusion**, whichever landmark declared it
         *   — one document may be reached by two entries, and the one naming a
         *   kind of story wins.
         * - **If the result covers the whole spine, it is dropped.** A
         *   mis-tagged book should leave the bug in place rather than become
         *   unanswerable.
         * - **A document heavier than the spine's average stays in.** The
         *   whole-spine guard above only fires at 100 %, so a book that tags one
         *   real chapter as apparatus loses it in silence. Apparatus measures
         *   0.4–3 KB against 12–50 KB chapters in every book in hand, so size is
         *   a signal the tagging is not: Gutenberg's *Pride and Prejudice*
         *   declares its 156 KB first document front matter against a 105 KB
         *   mean, and it holds the opening chapters. Mean-relative rather than a
         *   share of the total, because any two- or three-document book puts
         *   each document at 33–50 % of it; and strictly greater, so a book
         *   whose documents are all the same size — every synthetic fixture in
         *   the suite — is unaffected, and an archive with no sizes at all (mean
         *   0) never trips it. The honest limit: no byte rule catches a combined
         *   `front.xhtml` whose prologue is shorter than a chapter.
         */
        private fun parseFrontMatter(
            opf: EpubXmlNode,
            opfPath: String,
            navigationDocument: NavigationDocument?,
            spine: List<SpineItem>,
            weights: List<Double>,
        ): Set<String> {
            val excluded = LinkedHashSet<String>()
            val vetoed = HashSet<String>()

            fun consider(node: EpubXmlNode, href: String, base: String) {
                val tokens = HashSet(types(node))
                // The type is as often on the enclosing `<li>` as on the `<a>` —
                // a common real-world variant, and reading only one of the two
                // loses half the books that declare anything at all.
                val item = node.parent
                if (item != null && item.name == "li") tokens.addAll(types(item))
                val path = resolve(href, base)
                if (tokens.any { it in storyTypes }) vetoed.add(path)
                if (fragmentIdentifier(href) != null) return
                if (tokens.any { it in frontMatterTypes }) excluded.add(path)
            }

            // A separate pass over the parsed tree, not a branch inside
            // `parseNavigation`: that loop returns the moment it finds a
            // contents list, which in every book that has both comes before the
            // landmarks.
            if (navigationDocument != null) {
                for (navElement in navigationDocument.document.descendants("nav")) {
                    if (!hasType("landmarks", navElement)) continue
                    val anchors = navElement.descendants("a")
                    if (isPageList(navElement, anchors)) continue
                    for (anchor in anchors) {
                        val href = anchor["href"] ?: continue
                        consider(anchor, href, navigationDocument.href)
                    }
                }
            }
            // The EPUB 2 `<guide>`, for books with no landmarks at all. Its
            // hrefs are relative to the package document, so that is the base.
            if (excluded.isEmpty()) {
                val guide = opf.descendants("guide").firstOrNull()
                if (guide != null) {
                    for (reference in guide.children("reference")) {
                        val href = reference["href"] ?: continue
                        consider(reference, href, opfPath)
                    }
                }
            }

            // A document longer than the average one in this book, whatever it
            // is tagged. `>` and not `>=` on purpose: with every document the
            // same size — a two-chapter book, or a hand-built fixture — every
            // one of them equals the mean, and `>=` would exempt the lot.
            var sum = 0.0
            for (weight in weights) sum += weight
            val mean = if (weights.isEmpty()) 0.0 else sum / weights.size.toDouble()
            val heavy = spine.zip(weights).filter { it.second > mean }.map { it.first.href }.toSet()

            val frontMatter = excluded.filterTo(LinkedHashSet()) { it !in vetoed && it !in heavy }
            val hrefs = spine.map { it.href }.toSet()
            if (hrefs.isNotEmpty() && frontMatter.containsAll(hrefs)) return emptySet()
            return frontMatter
        }

        /**
         * The most anchors a real landmarks list has, past which it is
         * something else wearing the name.
         *
         * The EPUB structural-semantics landmarks vocabulary has about thirty
         * tokens, so thirty-odd entries is the theoretical ceiling for a nav
         * that names each once; every landmarks nav in hand has eleven or fewer.
         * Forty leaves room for a book that repeats a token and still refuses a
         * page list, which starts at one anchor per printed page and does not
         * stop.
         */
        private const val landmarksCeiling = 40

        /**
         * Whether a `<nav>` calling itself landmarks is really a page list.
         *
         * The two are the same element with the same declaration in real books:
         * Gutenberg's EPUB 3 conversions write
         * `<nav epub:type="landmarks" aria-label="Page List">` over an
         * `<ol class="pagelist">` holding one anchor per printed page — 453 of
         * them in *Pride and Prejudice* — and every one of those was then read
         * as the book naming a kind of content. One fragmentless anchor among
         * them is enough to delete a chapter, and a non-empty result also
         * short-circuits the `<guide>` the book may have meant to be believed
         * instead.
         *
         * Four signals, any one of which is enough, because no single one is
         * present in every book that does this: the correct `page-list` token
         * when the producer wrote it, the label a reading system announces, the
         * class on the list itself, and sheer length.
         *
         * A false trip costs only this nav's exclusions — which is the behaviour
         * before landmarks were read at all, never a deletion — and skipping the
         * nav hands the `<guide>` fallback back to a book that has one.
         */
        private fun isPageList(nav: EpubXmlNode, anchors: List<EpubXmlNode>): Boolean {
            if ("page-list" in types(nav)) return true
            // Case-insensitively, and by containment: "Page List", "page-list"
            // and "List of Pages" are all in circulation.
            val label = nav["aria-label"]
            if (label != null && "page" in label.lowercase()) return true
            val list = nav.descendants("ol").firstOrNull() ?: nav.descendants("ul").firstOrNull()
            if (list != null) {
                val classes = (list["class"] ?: "").swiftSplit { it.isSwiftWhitespace() }.map { it.lowercase() }.toSet()
                if ("pagelist" in classes || "page-list" in classes) return true
            }
            return anchors.size > landmarksCeiling
        }

        private fun flatten(list: EpubXmlNode?, base: String, depth: Int): List<NavPoint> {
            if (list == null) return emptyList()
            val points = ArrayList<NavPoint>()
            for (item in list.children("li")) {
                val anchor = item.firstChild("a")
                val href = anchor?.get("href")
                if (anchor != null && href != null) {
                    // An anchor's label may be plain text or wrapped in a span.
                    val title = anchor.allText.trimmingWhitespaceAndNewlines()
                    points.add(
                        NavPoint(
                            title = title,
                            href = resolve(href, base),
                            fragment = fragmentIdentifier(href),
                            depth = depth,
                        ),
                    )
                }
                points.addAll(flatten(item.firstChild("ol"), base, depth + 1))
            }
            return points
        }
    }
}
