import Foundation
import Testing

@testable import IssaEPUB

/// What a file from the reader's own folders can claim about itself that a
/// server's never could: sizes the archive cannot hold, series positions that
/// are not numbers, a back cover named first. Each archive is built here, byte
/// by byte, from invented text.
private enum HostileZIP {
    struct Member {
        let name: String
        let payload: Data
        /// 0 = stored, 8 = deflate.
        var method: UInt16 = 0
        /// What the central directory claims, in place of the truth.
        var declared: UInt64?
        /// Moves both sizes into a zip64 extra field, as these values.
        var zip64: (uncompressed: UInt64, compressed: UInt64)?

        init(_ name: String, _ text: String) {
            self.name = name
            payload = Data(text.utf8)
        }

        init(_ name: String, payload: Data, method: UInt16 = 0, declared: UInt64? = nil,
             zip64: (uncompressed: UInt64, compressed: UInt64)? = nil) {
            self.name = name
            self.payload = payload
            self.method = method
            self.declared = declared
            self.zip64 = zip64
        }
    }

    static func le16(_ v: Int) -> Data { Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
    static func le32(_ v: UInt64) -> Data { Data((0 ..< 4).map { UInt8((v >> ($0 * 8)) & 0xFF) }) }
    static func le64(_ v: UInt64) -> Data { Data((0 ..< 8).map { UInt8((v >> ($0 * 8)) & 0xFF) }) }

    static func archive(_ members: [Member]) -> Data {
        var out = Data()
        var central = Data()
        for member in members {
            let name = Data(member.name.utf8)
            let offset = UInt64(out.count)
            let real = UInt64(member.payload.count)
            let declared = member.declared ?? real
            out += Data([0x50, 0x4B, 0x03, 0x04]) + le16(20) + le16(0) + le16(Int(member.method))
            out += le16(0) + le16(0) + le32(0) + le32(real) + le32(min(declared, 0xFFFF_FFFE))
            out += le16(name.count) + le16(0) + name + member.payload

            var extra = Data()
            var compressedField = real
            var uncompressedField = declared
            if let zip64 = member.zip64 {
                compressedField = 0xFFFF_FFFF
                uncompressedField = 0xFFFF_FFFF
                extra = le16(0x0001) + le16(16) + le64(zip64.uncompressed) + le64(zip64.compressed)
            }
            central += Data([0x50, 0x4B, 0x01, 0x02]) + le16(45) + le16(45) + le16(0)
            central += le16(Int(member.method)) + le16(0) + le16(0) + le32(0)
            central += le32(compressedField) + le32(uncompressedField)
            central += le16(name.count) + le16(extra.count) + le16(0) + le16(0) + le16(0) + le32(0)
            central += le32(offset) + name + extra
        }
        let directoryOffset = UInt64(out.count)
        out += central
        out += Data([0x50, 0x4B, 0x05, 0x06]) + le16(0) + le16(0) + le16(members.count)
        out += le16(members.count) + le32(UInt64(central.count)) + le32(directoryOffset) + le16(0)
        return out
    }

    static let container = """
    <?xml version="1.0"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
    <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
    </container>
    """

    /// A one-chapter book whose overlay plays each of `audio` for a second,
    /// with `metadata` and `manifest` added to the package document.
    static func book(
        audio: [Member] = [], metadata: String = "", manifest: String = "", extras: [Member] = [],
    ) -> Data {
        let audioItems = audio.enumerated().map { index, member in
            "<item id=\"a\(index)\" href=\"\(member.name.dropFirst("OEBPS/".count))\" media-type=\"audio/mpeg\"/>"
        }.joined(separator: "\n")
        let overlay = audio.isEmpty ? "" : " media-overlay=\"ch1_overlay\""
        let opf = """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="uid">urn:uuid:issa-hostile-fixture</dc:identifier>
        <dc:title>The Lamplighter's Ledger</dc:title><dc:language>en</dc:language>
        \(metadata)
        </metadata>
        <manifest>
        <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"\(overlay)/>
        <item id="ch1_overlay" href="ch1.smil" media-type="application/smil+xml"/>
        \(audioItems)
        \(manifest)
        </manifest>
        <spine><itemref idref="ch1"/></spine>
        </package>
        """
        let ids = audio.indices.map { "s\($0)" }
        let spans = ids.map { "<span id=\"\($0)\">A line the lamplighter wrote.</span>" }.joined()
        let chapter = """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>One</title></head>
        <body><p>\(spans.isEmpty ? "The ledger is open." : spans)</p></body></html>
        """
        let pars = audio.enumerated().map { index, member in
            "<par id=\"p\(index)\"><text src=\"ch1.xhtml#s\(index)\"/>"
                + "<audio src=\"\(member.name.dropFirst("OEBPS/".count))\" clipBegin=\"0s\" clipEnd=\"1s\"/></par>"
        }.joined(separator: "\n")
        let smil = """
        <?xml version="1.0" encoding="utf-8"?>
        <smil xmlns="http://www.w3.org/ns/SMIL" xmlns:epub="http://www.idpf.org/2007/ops" version="3.0">
        <body><seq epub:textref="ch1.xhtml">\(pars)</seq></body></smil>
        """
        var members: [Member] = [
            Member("mimetype", "application/epub+zip"),
            Member("META-INF/container.xml", container),
            Member("OEBPS/content.opf", opf),
            Member("OEBPS/ch1.xhtml", chapter),
        ]
        if !audio.isEmpty { members.append(Member("OEBPS/ch1.smil", smil)) }
        return archive(members + audio + extras)
    }
}

@Suite("A file from the reader's folders that lies about itself")
struct LocalImportHostileTests {
    // MARK: - Sizes (R-18, R-31, R-33)

    /// R-18: a zip64 extra declaring `Int.max` for a stored member passed the
    /// directory read, `size(of:)` repeated it, and the importer's space check
    /// added it to the copy's size — an overflow trap during "Checking the
    /// book…" instead of a damaged-book message.
    @Test("a stored member claiming Int.max bytes through zip64 has no size")
    func zip64ClaimPastTheArchive() throws {
        let archive = try EPUBArchive(data: HostileZIP.archive([
            .init("a.txt", "honest"),
            .init("a.mp3", payload: Data("ID3".utf8), zip64: (0x7FFF_FFFF_FFFF_FFFF, 0x7FFF_FFFF_FFFF_FFFF)),
            // Within every cap, and still more than the whole file.
            .init("b.mp3", payload: Data("ID3".utf8), zip64: (1 << 20, 1 << 20)),
        ]))
        #expect(archive.size(of: "a.mp3") == nil)
        #expect(archive.extractedSize(of: "a.mp3") == nil)
        #expect(archive.size(of: "b.mp3") == nil)
        #expect(archive.extractedSize(of: "b.mp3") == nil)
        #expect(archive.size(of: "a.txt") == 6)
    }

    @Test("narration whose members claim more than the archive holds counts nothing, and does not trap")
    func audioByteCountCannotOverflow() throws {
        let huge = (UInt64(1) << 62, UInt64(1) << 62)
        let data = HostileZIP.book(audio: [
            .init("OEBPS/a.mp3", payload: Data("ID3".utf8), zip64: huge),
            .init("OEBPS/b.mp3", payload: Data("ID3".utf8), zip64: huge),
            .init("OEBPS/c.mp3", payload: Data("ID3".utf8), zip64: (0x7FFF_FFFF_FFFF_FFFF, 0x7FFF_FFFF_FFFF_FFFF)),
        ])
        let inspection = try EPUBInspection.inspect(EPUBArchive(data: data))
        #expect(inspection.audioFiles.count == 3)
        #expect(inspection.audioFiles.allSatisfy { $0.byteCount == nil })
        #expect(inspection.audioByteCount == 0)
    }

    /// R-31: a deflated track declaring more than `read`'s 256 MB in-memory
    /// cap is one `extract` streams to disk on first open, so it counts
    /// towards the room an import needs. It counted as nothing.
    @Test("a deflated track past read's cap still counts towards the room narration needs")
    func largeDeflatedTrackCounts() throws {
        let declared: UInt64 = 300 * 1024 * 1024
        // Enough payload that deflate could honestly reach the claim
        // (1032:1); the bytes are never inflated by an inspection.
        let payload = Data(repeating: 0x5A, count: Int(declared / 1000))
        let data = HostileZIP.book(audio: [
            .init("OEBPS/a.wav", payload: payload, method: 8, declared: declared),
        ])
        let archive = try EPUBArchive(data: data)
        #expect(archive.size(of: "OEBPS/a.wav") == nil, "read could never hold it, so it has no in-memory size")
        #expect(archive.extractedSize(of: "OEBPS/a.wav") == Int(declared))
        let inspection = try EPUBInspection.inspect(archive)
        #expect(inspection.audioByteCount == Int64(declared))
    }

    @Test("a deflated claim past what extract will ever write counts nothing")
    func pastTheStreamingCeiling() throws {
        let archive = try EPUBArchive(data: HostileZIP.archive([
            .init("a.wav", payload: Data(repeating: 0x5A, count: 16), method: 8, declared: 0xFFFF_FFFE),
        ]))
        #expect(archive.extractedSize(of: "a.wav") == nil)
    }

    /// R-33: a stored member was copied whole into the heap before any cap,
    /// and stored members had no cap at all — so a multi-gigabyte chapter or
    /// package document could get the app killed during the inspection.
    @Test("read refuses a stored member past its cap")
    func storedMemberIsCapped() throws {
        let archive = try EPUBArchive(data: HostileZIP.archive([
            .init("big.xhtml", payload: Data(repeating: 0x41, count: 4096)),
        ]))
        #expect(throws: EPUBError.self) { try archive.read("big.xhtml", maximumSize: 1024) }
        #expect(try archive.read("big.xhtml", maximumSize: 4096).count == 4096)
    }

    // MARK: - Series positions (R-32)

    @Test("a series position that is not a finite number is no position",
          arguments: ["NaN", "nan", "inf", "-Infinity", "1e999"])
    func nonFiniteCalibreIndex(_ raw: String) throws {
        let data = HostileZIP.book(metadata: """
        <meta name="calibre:series" content="The Lamplighters"/>
        <meta name="calibre:series_index" content="\(raw)"/>
        """)
        let package = try EPUBPackage.open(archive: EPUBArchive(data: data))
        #expect(package.metadata.series?.name == "The Lamplighters")
        #expect(package.metadata.series?.position == nil)
    }

    @Test("an EPUB 3 group-position that is not finite is no position, and a real one is kept")
    func nonFiniteGroupPosition() throws {
        let bad = HostileZIP.book(metadata: """
        <meta property="belongs-to-collection" id="c">The Lamplighters</meta>
        <meta refines="#c" property="collection-type">series</meta>
        <meta refines="#c" property="group-position">inf</meta>
        """)
        #expect(try EPUBPackage.open(archive: EPUBArchive(data: bad)).metadata.series?.position == nil)
        let good = HostileZIP.book(metadata: """
        <meta name="calibre:series" content="The Lamplighters"/>
        <meta name="calibre:series_index" content="2.5"/>
        """)
        #expect(try EPUBPackage.open(archive: EPUBArchive(data: good)).metadata.series?.position == 2.5)
    }

    // MARK: - The last-resort cover (R-34)

    private func cover(_ manifest: String, images: [String]) throws -> String? {
        let data = HostileZIP.book(
            manifest: manifest,
            extras: images.map { .init(payload: $0) })
        return try EPUBPackage.open(archive: EPUBArchive(data: data)).coverImageHref
    }

    @Test("a back cover listed first is not the cover")
    func backCoverIsNotTheCover() throws {
        let href = try cover("""
        <item id="back-cover" href="images/back.jpg" media-type="image/jpeg"/>
        <item id="cover" href="images/front.jpg" media-type="image/jpeg"/>
        """, images: ["OEBPS/images/back.jpg", "OEBPS/images/front.jpg"])
        #expect(href == "OEBPS/images/front.jpg")
    }

    @Test("a capitalised BackCover does not beat a front-cover")
    func capitalisedBackCover() throws {
        let href = try cover("""
        <item id="BackCover" href="images/b.jpg" media-type="image/jpeg"/>
        <item id="front-cover" href="images/f.jpg" media-type="image/jpeg"/>
        """, images: ["OEBPS/images/b.jpg", "OEBPS/images/f.jpg"])
        #expect(href == "OEBPS/images/f.jpg")
    }

    @Test("an image called exactly cover wins over one that only mentions it, in any order")
    func exactStemWins() throws {
        let href = try cover("""
        <item id="img-cover-thumb" href="images/cover-thumb.jpg" media-type="image/jpeg"/>
        <item id="img1" href="images/cover.jpg" media-type="image/jpeg"/>
        """, images: ["OEBPS/images/cover-thumb.jpg", "OEBPS/images/cover.jpg"])
        #expect(href == "OEBPS/images/cover.jpg")
    }

    @Test("with only a back cover, there is no cover to cut")
    func onlyABackCover() throws {
        let href = try cover("""
        <item id="back-cover" href="images/back.jpg" media-type="image/jpeg"/>
        """, images: ["OEBPS/images/back.jpg"])
        #expect(href == nil)
    }
}

private extension HostileZIP.Member {
    init(payload name: String) {
        self.init(name, payload: Data("not really a picture".utf8))
    }
}
