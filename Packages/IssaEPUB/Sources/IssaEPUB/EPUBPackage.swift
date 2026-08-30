import Foundation

/// An opened EPUB: its package document, spine, manifest and navigation.
public struct EPUBPackage: Sendable {
    public let archive: EPUBArchive
    /// Directory the OPF lives in; every manifest href resolves against it.
    public let rootDirectory: String
    public let metadata: Metadata
    public let manifest: [String: ManifestItem]
    public let spine: [SpineItem]
    public let navigation: [NavPoint]

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
              let opfPath = rootfile["full-path"]
        else {
            throw EPUBError.malformedPackage("container.xml has no rootfile")
        }

        let rootDirectory = (opfPath as NSString).deletingLastPathComponent
        let opf = try EPUBXML.parse(archive.read(opfPath))

        let metadata = parseMetadata(opf)
        let manifest = parseManifest(opf, rootDirectory: rootDirectory)
        let spine = parseSpine(opf, manifest: manifest)
        let navigation = (try? parseNavigation(
            opf: opf, archive: archive, manifest: manifest, rootDirectory: rootDirectory,
        )) ?? []

        return EPUBPackage(
            archive: archive,
            rootDirectory: rootDirectory,
            metadata: metadata,
            manifest: manifest,
            spine: spine,
            navigation: navigation,
        )
    }

    /// The part of an href after `#`, if any.
    static func fragmentIdentifier(of href: String) -> String? {
        guard let hash = href.firstIndex(of: "#") else { return nil }
        let fragment = String(href[href.index(after: hash)...])
        return fragment.isEmpty ? nil : fragment
    }

    /// Resolves an href that appears inside `base` to an archive path.
    static func resolve(_ href: String, relativeTo base: String) -> String {
        let target = href.split(separator: "#", maxSplits: 1).first.map(String.init) ?? href
        if target.hasPrefix("/") { return EPUBArchive.normalize(target) }
        let directory = (base as NSString).deletingLastPathComponent
        let joined = directory.isEmpty ? target : directory + "/" + target
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
            guard let id = item["id"], let href = item["href"] else { continue }
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

    private static func parseNavigation(
        opf: EPUBXMLNode, archive: EPUBArchive,
        manifest: [String: ManifestItem], rootDirectory: String,
    ) throws -> [NavPoint] {
        // EPUB 3 navigation document first, NCX as the fallback for older books.
        if let nav = manifest.values.first(where: { $0.properties.contains("nav") }) {
            let document = try EPUBXML.parse(archive.read(nav.href))
            for navElement in document.descendants("nav") {
                guard navElement["type"] == "toc" || navElement["epub:type"] == "toc" else { continue }
                return flatten(list: navElement.descendants("ol").first, base: nav.href, depth: 0)
            }
        }
        if let ncx = manifest.values.first(where: { $0.mediaType == "application/x-dtbncx+xml" }) {
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
