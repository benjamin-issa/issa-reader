import Foundation
import IssaCore

/// An opened EPUB: its package document, spine, manifest and navigation.
public struct EPUBPackage: Sendable {
    public let archive: EPUBArchive
    /// Directory the OPF lives in; every manifest href resolves against it.
    public let rootDirectory: String
    public let metadata: Metadata
    public let manifest: [String: ManifestItem]
    public let spine: [SpineItem]
    public let navigation: [NavPoint]
    /// Archive paths of the documents the book itself names as apparatus rather
    /// than story — the cover, the title page, the dedication, the copyright
    /// notice, the contents. See `parseFrontMatter` for the rule.
    public let frontMatter: Set<String>
    /// Each spine item's uncompressed size, read once from the ZIP central
    /// directory. Used to weight its share of the book.
    public let spineWeights: [Double]

    public struct Metadata: Sendable, Hashable {
        public var title: String?
        public var language: String?
        public var authors: [String] = []
        public var identifier: String?
        /// `media:duration` without a refines attribute — the whole book's
        /// narration length, present only on aligned EPUBs.
        public var mediaDuration: TimeInterval?
        /// The CSS class the reading system should apply to the active
        /// media-overlay fragment. Storyteller writes
        /// `-epub-media-overlay-active`, with a leading hyphen, which differs
        /// from the spec's usual example — so this must be read, not assumed.
        public var mediaActiveClass: String?
    }

    public struct ManifestItem: Sendable, Hashable {
        public let id: String
        /// Archive-relative, already resolved against the OPF directory.
        public let href: String
        public let mediaType: String
        public let properties: [String]
        /// Manifest id of this item's SMIL overlay, when it has one.
        public let mediaOverlay: String?
    }

    public struct SpineItem: Sendable, Hashable {
        public let idref: String
        public let linear: Bool
        public let href: String
        public let mediaOverlayID: String?
    }

    /// How far through the book a position in a spine item is, 0...1.
    ///
    /// Weighted by each item's uncompressed size rather than by its index, so
    /// the number means something on a book whose chapters differ in length.
    /// Sizes come from the ZIP central directory, which was already read when
    /// the container was opened, so this costs no inflation and no parsing.
    public func bookProgress(spineIndex: Int, within: Double) -> Double {
        guard spine.indices.contains(spineIndex) else { return 0 }
        let weights = spineWeights
        let total = weights.reduce(0, +)
        guard total > 0 else {
            // No sizes available: fall back to counting items equally.
            return (Double(spineIndex) + within) / Double(spine.count)
        }
        let before = weights.prefix(spineIndex).reduce(0, +)
        // `asProgression`, not `min(max(…))`: Swift's max returns the other
        // operand against NaN, so the inline clamp passed one straight through
        // and `ReaderModel.spinePosition` then fed `Int(scaled)` a NaN, which
        // traps.
        let place = within.asProgression ?? 0
        return ((before + weights[spineIndex] * place) / total).asProgression ?? 0
    }

    /// What an EPUB 2 table of contents is declared as in the manifest.
    ///
    /// Written down once, because `parseNavigation` looks for it and so does
    /// `navigationDocuments`, and the two disagreeing would mean a book whose
    /// contents is read as navigation in one place and as a chapter in the
    /// other.
    public static let ncxMediaType = "application/x-dtbncx+xml"

    /// The archive paths of the documents that *are* the navigation.
    ///
    /// The EPUB 3 navigation document (`properties="nav"`) and the EPUB 2 NCX,
    /// both read straight out of the manifest, which is exact: those two
    /// declarations are what a producer writes to say "this file is the table
    /// of contents", and nothing inferred from the text can be as reliable.
    ///
    /// Most books keep them out of the spine — both Gutenberg fixtures do — but
    /// plenty of EPUB 3 books put the nav document in it so the reader can page
    /// to the contents like any other section. Those are the ones anything
    /// reading the spine has to be able to tell from a chapter: a list of
    /// chapter titles is not prose, and the Ask index cites it as evidence.
    public var navigationDocuments: Set<String> {
        Set(
            manifest.values
                .filter { $0.properties.contains("nav") || $0.mediaType == Self.ncxMediaType }
                .map(\.href),
        )
    }

    public struct NavPoint: Sendable, Hashable {
        public let title: String
        /// Archive path of the document, with any fragment removed.
        public let href: String
        /// Element id the entry points at, when it targets part of a document.
        ///
        /// Books that pack many chapters into a few large spine files — which
        /// Gutenberg's do — distinguish their chapters only by this fragment.
        /// Dropping it collapses a seventeen-chapter book to four entries.
        public let fragment: String?
        public let depth: Int

        public init(title: String, href: String, fragment: String? = nil, depth: Int = 0) {
            self.title = title
            self.href = href
            self.fragment = fragment
            self.depth = depth
        }
    }
}

public extension EPUBPackage {
    /// Opens an EPUB from a file on disk.
    static func open(url: URL) throws -> EPUBPackage {
        try open(archive: EPUBArchive(url: url))
    }

    static func open(archive: EPUBArchive) throws -> EPUBPackage {
        let containerData = try archive.read("META-INF/container.xml")
        let container = try EPUBXML.parse(containerData)
        guard let rootfile = container.descendants("rootfile").first,
              let rawOPFPath = rootfile["full-path"]
        else {
            throw EPUBError.malformedPackage("container.xml has no rootfile")
        }
        // A URI, like every href — see `resolve` for why it is decoded.
        let opfPath = rawOPFPath.removingPercentEncoding ?? rawOPFPath

        let rootDirectory = (opfPath as NSString).deletingLastPathComponent
        let opf = try EPUBXML.parse(archive.read(opfPath))

        let metadata = parseMetadata(opf)
        let manifest = parseManifest(opf, rootDirectory: rootDirectory)
        let spine = parseSpine(opf, manifest: manifest)
        // Read here rather than inside each parse: the contents and the
        // landmarks are two `<nav>` elements of one document, and inflating and
        // parsing that document twice to read one of each buys nothing.
        let navigationDocument = manifest.values
            .first { $0.properties.contains("nav") }
            .flatMap { item in
                (try? EPUBXML.parse(archive.read(item.href))).map { (document: $0, href: item.href) }
            }
        let navigation = (try? parseNavigation(
            archive: archive, manifest: manifest, navigationDocument: navigationDocument,
        )) ?? []
        // From the central directory, which was already read when the container
        // was opened — no inflation, no parsing. Hoisted out of the initialiser
        // because the front-matter rule weighs a document against the rest of
        // the spine, and these are the sizes it weighs.
        let spineWeights = spine.map { Double(archive.size(of: $0.href) ?? 0) }

        return EPUBPackage(
            archive: archive,
            rootDirectory: rootDirectory,
            metadata: metadata,
            manifest: manifest,
            spine: spine,
            navigation: navigation,
            frontMatter: parseFrontMatter(
                opf: opf, opfPath: opfPath,
                navigationDocument: navigationDocument, spine: spine,
                weights: spineWeights,
            ),
            spineWeights: spineWeights,
        )
    }

    /// The part of an href after `#`, if any.
    static func fragmentIdentifier(of href: String) -> String? {
        guard let hash = href.firstIndex(of: "#") else { return nil }
        let fragment = String(href[href.index(after: hash)...])
        return fragment.isEmpty ? nil : fragment
    }

    /// Resolves an href that appears inside `base` to an archive path.
    ///
    /// Hrefs are URIs, so a space in a filename arrives as `%20` and an
    /// accented letter as UTF-8 escapes — Calibre and Sigil encode them as a
    /// matter of course — while the ZIP entry name holds the raw characters.
    /// Decoding happens here, the funnel every href passes through, so
    /// `Chapter%201.xhtml` finds the entry `Chapter 1.xhtml`. Only the path is
    /// decoded, after the fragment is stripped; a sloppy unencoded href with a
    /// bare `%` fails to decode and is kept verbatim, which is what its
    /// producer meant by it.
    static func resolve(_ href: String, relativeTo base: String) -> String {
        // `omittingEmptySubsequences: false`, which is not the default. For a
        // fragment-only href — `#chapter-1`, what a single-file book's nav uses
        // and what `NavPoint.fragment` exists for — the default drops the empty
        // leading piece, so `.first` was "chapter-1" rather than "", and the
        // result was `<base dir>/chapter-1`: a path no entry has. Every row of
        // such a book's table of contents pointed at a missing resource.
        let target = href
            .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? href
        // A pure fragment names the document it sits in.
        if target.isEmpty { return EPUBArchive.normalize(base) }
        let decoded = target.removingPercentEncoding ?? target
        if decoded.hasPrefix("/") { return EPUBArchive.normalize(decoded) }
        let directory = (base as NSString).deletingLastPathComponent
        let joined = directory.isEmpty ? decoded : directory + "/" + decoded
        return EPUBArchive.normalize(joined)
    }

    // MARK: - Parsing

    private static func parseMetadata(_ opf: EPUBXMLNode) -> Metadata {
        var metadata = Metadata()
        guard let node = opf.firstChild("metadata") ?? opf.descendants("metadata").first else {
            return metadata
        }
        metadata.title = node.descendants("title").first?.trimmedText
        metadata.language = node.descendants("language").first?.trimmedText
        metadata.identifier = node.descendants("identifier").first?.trimmedText
        metadata.authors = node.descendants("creator").map(\.trimmedText).filter { !$0.isEmpty }

        for meta in node.descendants("meta") {
            guard let property = meta["property"] else { continue }
            switch property {
            case "media:duration" where meta["refines"] == nil:
                metadata.mediaDuration = SMILClock.seconds(from: meta.trimmedText)
            case "media:active-class":
                metadata.mediaActiveClass = meta.trimmedText
            default:
                continue
            }
        }
        return metadata
    }

    private static func parseManifest(_ opf: EPUBXMLNode, rootDirectory: String) -> [String: ManifestItem] {
        guard let manifestNode = opf.descendants("manifest").first else { return [:] }
        var items: [String: ManifestItem] = [:]
        for item in manifestNode.children("item") {
            guard let id = item["id"], let rawHref = item["href"] else { continue }
            // A URI, like every href — see `resolve` for why it is decoded.
            let href = rawHref.removingPercentEncoding ?? rawHref
            let resolved = rootDirectory.isEmpty
                ? EPUBArchive.normalize(href)
                : EPUBArchive.normalize(rootDirectory + "/" + href)
            items[id] = ManifestItem(
                id: id,
                href: resolved,
                mediaType: item["media-type"] ?? "application/octet-stream",
                properties: (item["properties"] ?? "").split(separator: " ").map(String.init),
                mediaOverlay: item["media-overlay"],
            )
        }
        return items
    }

    private static func parseSpine(_ opf: EPUBXMLNode, manifest: [String: ManifestItem]) -> [SpineItem] {
        guard let spineNode = opf.descendants("spine").first else { return [] }
        return spineNode.children("itemref").compactMap { ref in
            guard let idref = ref["idref"], let item = manifest[idref] else { return nil }
            return SpineItem(
                idref: idref,
                linear: (ref["linear"] ?? "yes") != "no",
                href: item.href,
                // An itemref may override the manifest item's overlay.
                mediaOverlayID: ref["media-overlay"] ?? item.mediaOverlay,
            )
        }
    }

    /// The `epub:type` tokens declared on a node.
    ///
    /// `epub:type` holds a space-separated token list, so `"toc bodymatter"` is
    /// a table of contents and an equality test says it is not. Both spellings
    /// of the attribute are read because `EPUBXML` indexes attributes under the
    /// qualified name and the local one, and books use either.
    ///
    /// A fresh `Set` per call, per node, and that is left alone deliberately.
    /// This runs once per landmark and once per `<nav>` while a book is being
    /// opened — tens of calls against an archive that has just been inflated and
    /// XML-parsed — so the allocations are far below the noise floor of the work
    /// around them, and caching them would trade a measurable nothing for a
    /// second place where a node's tokens are decided.
    private static func types(of node: EPUBXMLNode) -> Set<String> {
        var tokens: Set<String> = []
        for declared in [node["type"], node["epub:type"]].compactMap({ $0 }) {
            tokens.formUnion(declared.split(whereSeparator: \.isWhitespace).map(String.init))
        }
        return tokens
    }

    private static func hasType(_ token: String, in node: EPUBXMLNode) -> Bool {
        types(of: node).contains(token)
    }

    private static func parseNavigation(
        archive: EPUBArchive, manifest: [String: ManifestItem],
        navigationDocument: (document: EPUBXMLNode, href: String)?,
    ) throws -> [NavPoint] {
        // EPUB 3 navigation document first, NCX as the fallback for older books.
        //
        // The fallback has to cover a navigation document that is *there but
        // broken* as well as one that is absent: a throw here used to abort
        // the whole function, and the caller's `try?` then showed no contents
        // at all with a perfectly good NCX unread in the manifest.
        if let nav = navigationDocument {
            for navElement in nav.document.descendants("nav") {
                // `epub:type` is a space-separated token list per spec, so
                // exact equality skipped `epub:type="toc bodymatter"`
                // entirely and such a book showed no contents at all.
                guard Self.hasType("toc", in: navElement) else { continue }
                // `<ul>` as well as `<ol>`: several conversion tools emit
                // it, invalidly but commonly.
                let list = navElement.descendants("ol").first
                    ?? navElement.descendants("ul").first
                let points = flatten(list: list, base: nav.href, depth: 0)
                // Only return when there is something to return. An empty
                // result used to short-circuit the NCX below, so a nav
                // document that *parsed* but yielded nothing — a `<ul>`, or
                // list items carrying headings with no anchor — left the
                // reader with no table of contents while a perfectly good
                // toc.ncx sat unread in the manifest. The comment above
                // promised this fallback covered "there but broken"; it
                // only covered "throws".
                if !points.isEmpty { return points }
            }
        }
        if let ncx = manifest.values.first(where: { $0.mediaType == ncxMediaType }) {
            let document = try EPUBXML.parse(archive.read(ncx.href))
            return document.descendants("navPoint").compactMap { point in
                guard let label = point.descendants("text").first?.trimmedText,
                      let href = point.descendants("content").first?["src"] else { return nil }
                return NavPoint(
                    title: label,
                    href: resolve(href, relativeTo: ncx.href),
                    fragment: fragmentIdentifier(of: href),
                    depth: 0,
                )
            }
        }
        return []
    }

    // MARK: - Front matter

    /// `epub:type` tokens that name a document as apparatus, not story.
    ///
    /// Both vocabularies, because the same rule reads EPUB 3 landmarks and the
    /// EPUB 2 `<guide>`: `titlepage` is the structural-semantics spelling and
    /// `title-page` the guide's, and a book gets to use either.
    private static let frontMatterTypes: Set<String> = [
        "cover", "titlepage", "title-page", "halftitlepage", "copyright-page",
        "dedication", "acknowledgments", "acknowledgements", "toc", "toc-brief",
        "landmarks", "loi", "lot", "colophon",
    ]

    /// `epub:type` tokens that name a document as story, whatever else it is
    /// also called. Any one of these vetoes an exclusion.
    ///
    /// `epigraph` is on this list deliberately: a novel whose chapter epigraphs
    /// carry an in-world document — a journal, a chronicle, a set of letters —
    /// is telling its story in them as much as in the chapters.
    /// `preface`, `foreword` and `introduction` are here for the same reason —
    /// a preface can be in-fiction, and a false positive deletes real prose,
    /// which is a far worse failure than leaving apparatus in the index.
    private static let storyTypes: Set<String> = [
        "prologue", "chapter", "part", "volume", "division", "epilogue",
        "preface", "foreword", "introduction", "epigraph", "afterword",
        "conclusion", "appendix", "glossary", "index", "bibliography",
        "notes", "endnotes", "rearnotes", "footnotes",
    ]

    /// The documents the book itself names as apparatus rather than story.
    ///
    /// Read from the EPUB 3 landmarks nav, falling back to the EPUB 2 `<guide>`
    /// for books that have no landmarks. Measured on a real novel, sixteen
    /// front-matter passages — the dedication, the acknowledgments, the author's
    /// preface — reached the model as evidence, and it answered from them.
    ///
    /// **Only tokens naming a kind of content count, in either direction:
    /// `bodymatter` and `frontmatter` are consulted for nothing.** The two
    /// obvious designs both rest on those broad tokens and both were verified
    /// wrong on the same book. Its `bodymatter` landmark points at
    /// `title.xhtml#tit` — the *title page* — so "everything before the
    /// bodymatter anchor is front matter" excludes the cover and nothing else;
    /// and the novel's actual Prologue is a document declaring
    /// `<body epub:type="frontmatter">`, so a body-level rule deletes the
    /// prologue. Publishers use the structural tokens positionally, to mark
    /// where a reading system should open the book, and position is not a claim
    /// about what a document holds.
    ///
    /// Three guards follow from that:
    ///
    /// - **Only a fragmentless href may exclude a document.** Verified against a
    ///   shipped fixture: Franklin's guide points its `toc` reference at
    ///   `…20203-h-0.htm.html#pgepubid00004`, and that same document also holds
    ///   the editor's Introduction and Chapter I. `resolve` strips fragments, so
    ///   without this the guide deletes about 46 KB of the book. A story tag is
    ///   still collected from a fragmented href, because vetoing errs towards
    ///   keeping prose.
    /// - **A story tag vetoes an exclusion**, whichever landmark declared it —
    ///   one document may be reached by two entries, and the one naming a kind
    ///   of story wins.
    /// - **If the result covers the whole spine, it is dropped.** A mis-tagged
    ///   book should leave the bug in place rather than become unanswerable.
    /// - **A document heavier than the spine's average stays in.** The
    ///   whole-spine guard above only fires at 100 %, so a book that tags one
    ///   real chapter as apparatus loses it in silence. Apparatus measures
    ///   0.4–3 KB against 12–50 KB chapters in every book in hand, so size is a
    ///   signal the tagging is not: Gutenberg's *Pride and Prejudice* declares
    ///   its 156 KB first document front matter against a 105 KB mean, and it
    ///   holds the opening chapters. Mean-relative rather than a share of the
    ///   total, because any two- or three-document book puts each document at
    ///   33–50 % of it; and strictly greater, so a book whose documents are all
    ///   the same size — every synthetic fixture in the suite — is unaffected,
    ///   and an archive with no sizes at all (mean 0) never trips it. The honest
    ///   limit: no byte rule catches a combined `front.xhtml` whose prologue is
    ///   shorter than a chapter.
    private static func parseFrontMatter(
        opf: EPUBXMLNode, opfPath: String,
        navigationDocument: (document: EPUBXMLNode, href: String)?,
        spine: [SpineItem],
        weights: [Double],
    ) -> Set<String> {
        var excluded: Set<String> = []
        var vetoed: Set<String> = []

        func consider(_ node: EPUBXMLNode, href: String, base: String) {
            var tokens = types(of: node)
            // The type is as often on the enclosing `<li>` as on the `<a>` — a
            // common real-world variant, and reading only one of the two loses
            // half the books that declare anything at all.
            if let item = node.parent, item.name == "li" { tokens.formUnion(types(of: item)) }
            let path = resolve(href, relativeTo: base)
            if !tokens.isDisjoint(with: storyTypes) { vetoed.insert(path) }
            guard fragmentIdentifier(of: href) == nil else { return }
            if !tokens.isDisjoint(with: frontMatterTypes) { excluded.insert(path) }
        }

        // A separate pass over the parsed tree, not a branch inside
        // `parseNavigation`: that loop returns the moment it finds a contents
        // list, which in every book that has both comes before the landmarks.
        if let nav = navigationDocument {
            for navElement in nav.document.descendants("nav")
                where hasType("landmarks", in: navElement)
            {
                let anchors = navElement.descendants("a")
                guard !isPageList(navElement, anchors: anchors) else { continue }
                for anchor in anchors {
                    guard let href = anchor["href"] else { continue }
                    consider(anchor, href: href, base: nav.href)
                }
            }
        }
        // The EPUB 2 `<guide>`, for books with no landmarks at all. Its hrefs
        // are relative to the package document, so that is the base.
        if excluded.isEmpty, let guide = opf.descendants("guide").first {
            for reference in guide.children("reference") {
                guard let href = reference["href"] else { continue }
                consider(reference, href: href, base: opfPath)
            }
        }

        // A document longer than the average one in this book, whatever it is
        // tagged. `>` and not `>=` on purpose: with every document the same
        // size — a two-chapter book, or a hand-built fixture — every one of
        // them equals the mean, and `>=` would exempt the lot.
        let mean = weights.isEmpty ? 0 : weights.reduce(0, +) / Double(weights.count)
        let heavy = Set(zip(spine, weights).filter { $0.1 > mean }.map { $0.0.href })

        let frontMatter = excluded.subtracting(vetoed).subtracting(heavy)
        let hrefs = Set(spine.map(\.href))
        if !hrefs.isEmpty, hrefs.isSubset(of: frontMatter) { return [] }
        return frontMatter
    }

    /// The most anchors a real landmarks list has, past which it is something
    /// else wearing the name.
    ///
    /// The EPUB structural-semantics landmarks vocabulary has about thirty
    /// tokens, so thirty-odd entries is the theoretical ceiling for a nav that
    /// names each once; every landmarks nav in hand has eleven or fewer. Forty
    /// leaves room for a book that repeats a token and still refuses a page
    /// list, which starts at one anchor per printed page and does not stop.
    private static let landmarksCeiling = 40

    /// Whether a `<nav>` calling itself landmarks is really a page list.
    ///
    /// The two are the same element with the same declaration in real books:
    /// Gutenberg's EPUB 3 conversions write
    /// `<nav epub:type="landmarks" aria-label="Page List">` over an
    /// `<ol class="pagelist">` holding one anchor per printed page — 453 of them
    /// in *Pride and Prejudice* — and every one of those was then read as the
    /// book naming a kind of content. One fragmentless anchor among them is
    /// enough to delete a chapter, and a non-empty result also short-circuits
    /// the `<guide>` the book may have meant to be believed instead.
    ///
    /// Four signals, any one of which is enough, because no single one is
    /// present in every book that does this: the correct `page-list` token when
    /// the producer wrote it, the label a reading system announces, the class on
    /// the list itself, and sheer length.
    ///
    /// A false trip costs only this nav's exclusions — which is the behaviour
    /// before landmarks were read at all, never a deletion — and skipping the
    /// nav hands the `<guide>` fallback back to a book that has one.
    private static func isPageList(_ nav: EPUBXMLNode, anchors: [EPUBXMLNode]) -> Bool {
        if types(of: nav).contains("page-list") { return true }
        // Case-insensitively, and by containment: "Page List", "page-list" and
        // "List of Pages" are all in circulation.
        if let label = nav["aria-label"], label.lowercased().contains("page") { return true }
        if let list = nav.descendants("ol").first ?? nav.descendants("ul").first {
            let classes = Set(
                (list["class"] ?? "").split(whereSeparator: \.isWhitespace)
                    .map { $0.lowercased() },
            )
            if !classes.isDisjoint(with: ["pagelist", "page-list"]) { return true }
        }
        return anchors.count > landmarksCeiling
    }

    private static func flatten(list: EPUBXMLNode?, base: String, depth: Int) -> [NavPoint] {
        guard let list else { return [] }
        var points: [NavPoint] = []
        for item in list.children("li") {
            if let anchor = item.firstChild("a"), let href = anchor["href"] {
                // An anchor's label may be plain text or wrapped in a span.
                let title = anchor.allText.trimmingCharacters(in: .whitespacesAndNewlines)
                points.append(NavPoint(
                    title: title,
                    href: resolve(href, relativeTo: base),
                    fragment: fragmentIdentifier(of: href),
                    depth: depth,
                ))
            }
            points.append(contentsOf: flatten(list: item.firstChild("ol"), base: base, depth: depth + 1))
        }
        return points
    }
}
