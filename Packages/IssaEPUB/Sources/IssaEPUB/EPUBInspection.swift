import Foundation

/// What a file the reader chose turns out to be, before it is added.
///
/// The checks a book from the reader's own files has to pass that a server's
/// never did: that it is an EPUB at all, that it is not locked by a shop's DRM,
/// that it has a chapter to read — and what it is, for the list and for
/// Book info: its version, its layout, its narration and its cover.
///
/// Everything is read from the central directory and the package document;
/// nothing is extracted. The one thing not decided here is whether the
/// narration's audio will *play*, which is AVFoundation's to say and this
/// package does not link it — `audioFiles` carries what the caller needs to ask.
public struct EPUBInspection: Sendable {
    /// Why a file cannot be added.
    public enum Problem: Error, Sendable, Equatable {
        /// Not a ZIP, or a ZIP with no `META-INF/container.xml` naming a
        /// package: not an EPUB at all.
        case notAnEPUB
        /// An EPUB whose package will not parse, or with no chapter that can
        /// be read.
        case damaged(String)
        /// Locked by a shop's DRM.
        case protected(Protection)
    }

    /// Whose lock a protected book carries, as far as the archive says.
    public enum Protection: String, Sendable, Equatable {
        /// `META-INF/rights.xml`: Adobe ADEPT, which Adobe Digital Editions,
        /// Kobo and most library loans use.
        case adobe
        /// A Readium LCP licence.
        case lcp
        /// `META-INF/sinf.xml`: Apple Books' FairPlay.
        case fairPlay
        /// An `encryption.xml` that encrypts something other than a font, or
        /// by an algorithm that is not font obfuscation.
        case unknown
    }

    /// One audio file the narration plays.
    public struct AudioFile: Sendable, Hashable {
        public let href: String
        /// As the manifest declares it, or nil when no manifest item names
        /// the file.
        public let mediaType: String?
        /// The uncompressed size, from the central directory.
        public let byteCount: Int?
        /// Whether the archive holds it at all.
        public let isPresent: Bool
    }

    public let package: EPUBPackage
    /// The package version: "2.0", "3.0".
    public var version: String? { package.metadata.version }
    public var isEPUB2: Bool { package.metadata.isEPUB2 }
    /// Fixed pages: `rendition:layout`, the older `fixed-layout` meta, or
    /// Apple's display options.
    public let isFixedLayout: Bool
    /// The narration, empty when the book has none.
    public let timeline: SMILTimeline
    /// Every distinct file the narration plays, in the order they first play.
    public let audioFiles: [AudioFile]
    /// The archive path of the cover image, if the book names one.
    public var coverHref: String? { package.coverImageHref }

    /// Whether the book carries narration with all of its audio in the
    /// archive. Whether that audio plays is the caller's question.
    public var hasCompleteNarration: Bool {
        !timeline.isEmpty && audioFiles.allSatisfy(\.isPresent)
    }

    /// The bytes narration will take once extracted on first open.
    public var audioByteCount: Int64 {
        audioFiles.reduce(0) { $0 + Int64($1.byteCount ?? 0) }
    }

    /// Inspects the EPUB at `url`.
    public static func inspect(_ url: URL) throws(Problem) -> EPUBInspection {
        let archive: EPUBArchive
        do {
            archive = try EPUBArchive(url: url)
        } catch {
            throw .notAnEPUB
        }
        return try inspect(archive)
    }

    /// Inspects an archive already open.
    public static func inspect(_ archive: EPUBArchive) throws(Problem) -> EPUBInspection {
        // A ZIP without the container document is a ZIP, not an EPUB: a
        // renamed .docx or a zipped folder of pictures.
        guard archive.contains("META-INF/container.xml") else { throw .notAnEPUB }

        // Before the package is parsed. A locked book's package usually reads
        // perfectly well, and a damaged-book message for a book that is simply
        // locked sends the reader looking for a fresh copy that will be locked
        // too.
        if let protection = protection(of: archive) { throw .protected(protection) }

        let package: EPUBPackage
        do {
            package = try EPUBPackage.open(archive: archive)
        } catch {
            // The container is there but names nothing usable.
            throw .damaged(String(describing: error))
        }
        guard hasReadableSpine(package) else {
            throw .damaged("no readable chapter")
        }

        let timeline = SMILParser.timeline(for: package)
        let mediaTypes = Dictionary(
            package.manifest.values.map { ($0.href, $0.mediaType) },
            uniquingKeysWith: { first, _ in first })
        var seen: Set<String> = []
        var audio: [AudioFile] = []
        for entry in timeline.entries where seen.insert(entry.audioHref).inserted {
            audio.append(AudioFile(
                href: entry.audioHref,
                mediaType: mediaTypes[entry.audioHref],
                byteCount: archive.size(of: entry.audioHref),
                isPresent: archive.contains(entry.audioHref)))
        }

        return EPUBInspection(
            package: package,
            isFixedLayout: package.metadata.isFixedLayout || appleFixedLayout(archive),
            timeline: timeline,
            audioFiles: audio)
    }

    // MARK: - DRM

    /// The two algorithms that only scramble a font so it cannot be lifted out
    /// of the book. A book carrying nothing else in `encryption.xml` is not
    /// locked: `EPUBFontResolver` reports such a font as unusable and the book
    /// reads in the reader's own face.
    static let fontObfuscation: Set<String> = [
        "http://www.idpf.org/2008/embedding",
        "http://ns.adobe.com/pdf/enc#RC",
    ]

    /// Extensions a font has, for telling an obfuscated font from anything else.
    static let fontExtensions: Set<String> = ["otf", "ttf", "woff", "woff2", "ttc", "otc"]

    /// Whose lock the archive carries, or nil when it is not locked.
    ///
    /// The licence files first, because they are unambiguous. Then
    /// `encryption.xml`, read the way `EPUBFontResolver.obfuscatedPaths`
    /// reads it: any encrypted resource that is not a font, or any algorithm
    /// that is not font obfuscation, is a lock — whatever the file is called.
    static func protection(of archive: EPUBArchive) -> Protection? {
        if archive.contains("META-INF/license.lcpl") || archive.contains("license.lcpl") {
            return .lcp
        }
        if archive.contains("META-INF/rights.xml") { return .adobe }
        if archive.contains("META-INF/sinf.xml") { return .fairPlay }

        guard archive.contains("META-INF/encryption.xml") else { return nil }
        guard let data = try? archive.read("META-INF/encryption.xml"),
              let root = try? EPUBXML.parse(data)
        else {
            // An encryption document that will not parse says something is
            // encrypted and will not say what. Treating that as unlocked would
            // add a book every chapter of which may be ciphertext.
            return .unknown
        }
        for encrypted in root.descendants("EncryptedData") {
            let algorithm = encrypted.descendants("EncryptionMethod").first?["Algorithm"] ?? ""
            let target = encrypted.descendants("CipherReference").first?["URI"]
                .map { EPUBArchive.normalize($0.removingPercentEncoding ?? $0) } ?? ""
            let isFont = fontExtensions.contains((target as NSString).pathExtension.lowercased())
            guard fontObfuscation.contains(algorithm), isFont else {
                // LCP's own encryption document names its licence in a
                // `RetrievalMethod`; a book that lost the licence file but
                // kept that still says whose lock it is.
                let retrieval = encrypted.descendants("RetrievalMethod").first?["URI"] ?? ""
                return retrieval.contains("license.lcpl") ? .lcp : .unknown
            }
        }
        return nil
    }

    // MARK: - Layout and spine

    /// Apple's `com.apple.ibooks.display-options.xml`, which is how a book
    /// made for iBooks says it is fixed layout without EPUB 3's property.
    static func appleFixedLayout(_ archive: EPUBArchive) -> Bool {
        let path = "META-INF/com.apple.ibooks.display-options.xml"
        guard archive.contains(path),
              let data = try? archive.read(path),
              let root = try? EPUBXML.parse(data)
        else { return false }
        return root.descendants("option").contains {
            $0["name"] == "fixed-layout" && $0.trimmedText.lowercased() == "true"
        }
    }

    /// Whether at least one spine item is in the archive and inflates.
    ///
    /// One is enough: a book with a single corrupt chapter still opens, and
    /// the reader says which chapter would not. A spine of nothing but
    /// missing or broken entries is a book that would open onto nothing.
    static func hasReadableSpine(_ package: EPUBPackage) -> Bool {
        package.spine.contains { item in
            guard let data = try? package.archive.read(item.href) else { return false }
            return !data.isEmpty
        }
    }
}
