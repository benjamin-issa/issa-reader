import Foundation
import IssaCore
import Testing

@testable import IssaEPUB

/// What a book from the reader's own files is found to be before it is added:
/// its cover, what it says about itself, and whether it can be added at all.
///
/// The generated fixtures are `Tools/scripts/make-local-import-fixtures.py`'s,
/// from invented text; `alice.epub` and `time-machine.epub` are Gutenberg's.
@Suite("Inspecting an EPUB from the reader's files")
struct LocalImportInspectionTests {
    static func url(_ name: String) throws -> URL {
        try #require(
            Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "epub"),
            "\(name).epub is not in the test bundle")
    }

    static func package(_ name: String) throws -> EPUBPackage {
        try EPUBPackage.open(url: url(name))
    }

    /// A stored ZIP of the given members, for the archives no fixture is.
    static func zip(_ members: [(String, String)]) -> Data {
        func le16(_ v: Int) -> Data { Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
        func le32(_ v: Int) -> Data { Data((0 ..< 4).map { UInt8((v >> ($0 * 8)) & 0xFF) }) }
        var out = Data()
        var central = Data()
        for (name, text) in members {
            let nameData = Data(name.utf8)
            let payload = Data(text.utf8)
            let offset = out.count
            out += Data([0x50, 0x4B, 0x03, 0x04]) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0)
            out += le32(0) + le32(payload.count) + le32(payload.count) + le16(nameData.count) + le16(0)
            out += nameData + payload
            central += Data([0x50, 0x4B, 0x01, 0x02]) + le16(20) + le16(20) + le16(0) + le16(0)
            central += le16(0) + le16(0) + le32(0) + le32(payload.count) + le32(payload.count)
            central += le16(nameData.count) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0)
            central += le32(offset) + nameData
        }
        let directoryOffset = out.count
        out += central
        out += Data([0x50, 0x4B, 0x05, 0x06]) + le16(0) + le16(0) + le16(members.count)
        out += le16(members.count) + le32(central.count) + le32(directoryOffset) + le16(0)
        return out
    }

    static let container = """
    <?xml version="1.0"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
    <rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles>
    </container>
    """

    // MARK: - Cover

    @Test("EPUB 3's cover-image is the cover")
    func coverImageProperty() throws {
        #expect(try Self.package("alice").coverImageHref == "OEBPS/4597445089497030724_cover.jpg")
        #expect(try Self.package("time-machine").coverImageHref == "OEBPS/3887432791584396968_cover.jpg")
    }

    /// The image's id and path say nothing about covers, and the book has a
    /// second image, so only the `<meta name="cover">` id can have found it.
    @Test("EPUB 2's meta-name cover is the cover when nothing else says so")
    func metaNameCover() throws {
        let package = try Self.package("epub2-meta-cover")
        #expect(package.metadata.coverID == "img-front")
        #expect(package.coverImageHref == "OEBPS/images/frontispiece.png")
    }

    @Test("a book with no images has no cover")
    func noCover() throws {
        #expect(try Self.package("readalong").coverImageHref == nil)
    }

    // MARK: - Metadata

    @Test("EPUB 3 refinements give each creator a role and a sort name")
    func refinedCreators() throws {
        let package = try Self.package("alice")
        #expect(package.metadata.contributors == [
            .init(name: "Lewis Carroll", fileAs: "Carroll, Lewis", role: "aut", isCreator: true),
        ])
        let local = package.localMetadata(fallbackTitle: "alice")
        #expect(local.title == "Alice's Adventures in Wonderland")
        #expect(local.authors == [LocalContributor(name: "Lewis Carroll", fileAs: "Carroll, Lewis", role: "aut")])
        #expect(local.narrators.isEmpty)
        #expect(local.identifier == "http://www.gutenberg.org/11")
        #expect(local.date == "2008-06-27")
        #expect(package.metadata.version == "3.0")
    }

    /// `opf:role` and `opf:file-as`, and a narrator, which a server book
    /// carries in its own field and a local one only here.
    @Test("EPUB 2's opf:role and opf:file-as sort authors, narrators and the rest")
    func epub2Roles() throws {
        let package = try Self.package("epub2-meta-cover")
        #expect(package.metadata.version == "2.0")
        #expect(package.metadata.isEPUB2)
        let local = package.localMetadata(fallbackTitle: "epub2-meta-cover")
        #expect(local.title == "The Keeper of the Lamp")
        #expect(local.authors == [LocalContributor(name: "Ada Fixture", fileAs: "Fixture, Ada", role: "aut")])
        #expect(local.narrators == [LocalContributor(name: "Noel Reader", fileAs: "Reader, Noel", role: "nrt")])
        #expect(local.creators == [LocalContributor(name: "Tomas Translator", role: "trl")])
        // Calibre's series, which is how EPUB 2 books say it.
        #expect(local.series == LocalSeries(name: "Lamps and Ledgers", position: 2))
        #expect(local.identifier == "urn:uuid:issa-fixture-epub2")
    }

    @Test("a subtitle, a series, a fixed layout and the package's own identifier are read")
    func epub3Details() throws {
        let package = try Self.package("epub3-details")
        let metadata = package.metadata
        #expect(metadata.title == "The Lighthouse Book")
        #expect(metadata.subtitle == "Further Notes on Lamps")
        #expect(metadata.isFixedLayout)
        #expect(metadata.publisher == "Invented Press")
        #expect(metadata.description == "A short book about a lighthouse, invented for a test.")
        // The first identifier is an ISBN; the package names the uuid.
        #expect(metadata.identifier == "urn:isbn:0000000000000")
        #expect(metadata.uniqueIdentifier == "urn:uuid:issa-fixture-epub3-details")

        let local = package.localMetadata(fallbackTitle: "x")
        #expect(local.subtitle == "Further Notes on Lamps")
        #expect(local.series == LocalSeries(name: "Lamps and Ledgers", position: 3))
        #expect(local.authors.map(\.name) == ["A. Fixture"])
        // An illustrator keeps their role; a contributor with none is a
        // contributor, not an author.
        #expect(local.creators == [
            LocalContributor(name: "Iris Illustrator", role: "ill"),
            LocalContributor(name: "Casey Contributor", role: "ctb"),
        ])
        #expect(local.identifier == "urn:uuid:issa-fixture-epub3-details")
    }

    @Test("a book with no title is called by its file's name")
    func fallbackTitle() throws {
        let opf = """
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>  </dc:title></metadata>
        <manifest><item id="c" href="c.xhtml" media-type="application/xhtml+xml"/></manifest>
        <spine><itemref idref="c"/></spine>
        </package>
        """
        let archive = try EPUBArchive(data: Self.zip([
            ("META-INF/container.xml", Self.container), ("content.opf", opf),
            ("c.xhtml", "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>Words.</p></body></html>"),
        ]))
        let package = try EPUBPackage.open(archive: archive)
        #expect(package.localMetadata(fallbackTitle: "untitled-book").title == "untitled-book")
    }

    // MARK: - Inspection

    @Test("font obfuscation alone is not a lock")
    func obfuscatedFontIsNotDRM() throws {
        let inspection = try EPUBInspection.inspect(Self.url("obfuscated-font"))
        #expect(inspection.timeline.isEmpty)
    }

    @Test("Adobe's rights.xml is a lock")
    func adobe() throws {
        #expect(throws: EPUBInspection.Problem.protected(.adobe)) {
            try EPUBInspection.inspect(Self.url("drm-adobe"))
        }
    }

    @Test("an LCP licence is a lock, with or without the licence file")
    func lcp() throws {
        #expect(throws: EPUBInspection.Problem.protected(.lcp)) {
            try EPUBInspection.inspect(Self.url("drm-lcp"))
        }
        #expect(throws: EPUBInspection.Problem.protected(.lcp)) {
            try EPUBInspection.inspect(Self.url("drm-lcp-no-licence"))
        }
    }

    /// Encrypting a chapter with the font-obfuscation algorithm is still
    /// encrypting a chapter: only a font may be obfuscated and let through.
    @Test("obfuscation applied to anything but a font is a lock")
    func obfuscatedChapter() throws {
        let encryption = """
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <EncryptedData xmlns="http://www.w3.org/2001/04/xmlenc#">
        <EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/>
        <CipherData><CipherReference URI="c.xhtml"/></CipherData>
        </EncryptedData></encryption>
        """
        let archive = try EPUBArchive(data: Self.zip([
            ("META-INF/container.xml", Self.container), ("META-INF/encryption.xml", encryption),
        ]))
        #expect(EPUBInspection.protection(of: archive) == .unknown)
    }

    @Test("a file that is not a ZIP is not an EPUB")
    func notAZip() throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "issa-not-an-epub-\(UUID().uuidString).epub")
        try Data("These are a reader's notes, not a book.".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: EPUBInspection.Problem.notAnEPUB) { try EPUBInspection.inspect(file) }
    }

    @Test("a ZIP with no container document is not an EPUB")
    func noContainer() throws {
        let archive = try EPUBArchive(data: Self.zip([("notes.txt", "A zipped folder of notes.")]))
        #expect(throws: EPUBInspection.Problem.notAnEPUB) { try EPUBInspection.inspect(archive) }
    }

    @Test("a package with nothing in its spine is damaged")
    func emptySpine() throws {
        let opf = """
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Hollow</dc:title></metadata>
        <manifest><item id="c" href="missing.xhtml" media-type="application/xhtml+xml"/></manifest>
        <spine><itemref idref="c"/></spine>
        </package>
        """
        let archive = try EPUBArchive(data: Self.zip([
            ("META-INF/container.xml", Self.container), ("content.opf", opf),
        ]))
        #expect(throws: EPUBInspection.Problem.damaged("no readable chapter")) {
            try EPUBInspection.inspect(archive)
        }
    }

    @Test("a container naming a package that is not there is damaged")
    func missingPackage() throws {
        let archive = try EPUBArchive(data: Self.zip([("META-INF/container.xml", Self.container)]))
        #expect {
            try EPUBInspection.inspect(archive)
        } throws: { error in
            if case EPUBInspection.Problem.damaged = error { return true }
            return false
        }
    }

    @Test("a read-along's narration and audio files are found")
    func readalongNarration() throws {
        let inspection = try EPUBInspection.inspect(Self.url("readalong"))
        #expect(!inspection.timeline.isEmpty)
        #expect(inspection.hasCompleteNarration)
        #expect(inspection.audioFiles.map(\.href) == ["OEBPS/Audio/track1.mp3", "OEBPS/Audio/track2.mp3"])
        #expect(inspection.audioFiles.allSatisfy { $0.mediaType == "audio/mpeg" && $0.isPresent })
        #expect(inspection.audioByteCount == 2 * 2052)
        #expect(!inspection.isFixedLayout)
        #expect(!inspection.isEPUB2)
    }

    /// Present and complete, and declared as Opus: whether that plays is
    /// AVFoundation's to say (`AudioPlayabilityTests`), so this only has to
    /// carry the type through.
    @Test("an Opus read-along carries its media type through")
    func opusNarration() throws {
        let inspection = try EPUBInspection.inspect(Self.url("readalong-opus"))
        #expect(inspection.hasCompleteNarration)
        #expect(inspection.audioFiles.map(\.mediaType) == ["audio/opus", "audio/opus"])
    }

    @Test("clips with no clipEnd still make a narration")
    func openClips() throws {
        let inspection = try EPUBInspection.inspect(Self.url("readalong-open-clips"))
        #expect(inspection.timeline.entries.count == 5)
        #expect(inspection.hasCompleteNarration)
    }

    /// Sentence ids restart in every chapter, which Storyteller never writes
    /// and other tools do; each chapter's sentences stay its own.
    @Test("sentence ids repeated per chapter are kept apart by document")
    func repeatedIDs() throws {
        let inspection = try EPUBInspection.inspect(Self.url("readalong-repeated-ids"))
        let timeline = inspection.timeline
        #expect(timeline.entries.count == 5)
        let first = try #require(timeline.exactEntry(forFragment: "s0", inDocument: "OEBPS/ch1.xhtml"))
        let second = try #require(timeline.exactEntry(forFragment: "s0", inDocument: "OEBPS/ch2.xhtml"))
        #expect(first.audioHref == "OEBPS/Audio/ch1.mp3")
        #expect(second.audioHref == "OEBPS/Audio/ch2.mp3")
        #expect(first.cumulativeEnd < second.cumulativeEnd)
    }

    @Test("fixed layout and EPUB 2 are found, and neither is a problem")
    func layoutAndVersion() throws {
        #expect(try EPUBInspection.inspect(Self.url("epub3-details")).isFixedLayout)
        let epub2 = try EPUBInspection.inspect(Self.url("epub2-meta-cover"))
        #expect(epub2.isEPUB2)
        #expect(epub2.timeline.isEmpty)
        #expect(epub2.coverHref == "OEBPS/images/frontispiece.png")
    }
}
