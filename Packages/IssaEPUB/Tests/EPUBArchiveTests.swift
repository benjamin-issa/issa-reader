import Foundation
import Testing

@testable import IssaEPUB

/// Byte-level ZIP construction, because these tests are about the bytes.
///
/// The real-book fixtures prove the happy path; what they cannot prove is that
/// a *hostile* archive — every field attacker-chosen, downloaded straight from
/// whatever server the reader points the app at — throws `malformedArchive`
/// rather than trapping. A trap here is an uncatchable crash on every attempt
/// to open the book, repeated forever because the download is cached.
private enum ZIPBytes {
    static func le16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    static func le32(_ value: UInt32) -> Data {
        Data((0 ..< 4).map { UInt8((value >> ($0 * 8)) & 0xFF) })
    }

    static func le64(_ value: UInt64) -> Data {
        Data((0 ..< 8).map { UInt8((value >> ($0 * 8)) & 0xFF) })
    }

    struct Entry {
        let name: String
        let payload: Data
        /// 0 = stored, 8 = deflate.
        var method: UInt16 = 0
        /// The size the central directory *claims*; defaults to the truth.
        var declaredUncompressedSize: UInt32?
    }

    /// A structurally valid archive built from whole cloth.
    static func archive(_ entries: [Entry]) -> Data {
        var out = Data()
        var central = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let uncompressed = entry.declaredUncompressedSize ?? UInt32(entry.payload.count)
            let offset = UInt32(out.count)

            out.append(contentsOf: [0x50, 0x4B, 0x03, 0x04]) // local header
            out.append(le16(20)) // version needed
            out.append(le16(0)) // flags
            out.append(le16(entry.method))
            out.append(le16(0)) // time
            out.append(le16(0)) // date
            out.append(le32(0)) // crc, unread
            out.append(le32(UInt32(entry.payload.count)))
            out.append(le32(uncompressed))
            out.append(le16(UInt16(name.count)))
            out.append(le16(0)) // extra length
            out.append(name)
            out.append(entry.payload)

            central.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
            central.append(le16(20)) // version made by
            central.append(le16(20)) // version needed
            central.append(le16(0)) // flags
            central.append(le16(entry.method))
            central.append(le16(0)) // time
            central.append(le16(0)) // date
            central.append(le32(0)) // crc
            central.append(le32(UInt32(entry.payload.count)))
            central.append(le32(uncompressed))
            central.append(le16(UInt16(name.count)))
            central.append(le16(0)) // extra length
            central.append(le16(0)) // comment length
            central.append(le16(0)) // disk start
            central.append(le16(0)) // internal attributes
            central.append(le32(0)) // external attributes
            central.append(le32(offset))
            central.append(name)
        }
        let directoryOffset = UInt32(out.count)
        out.append(central)
        out.append(contentsOf: [0x50, 0x4B, 0x05, 0x06]) // EOCD
        out.append(le16(0))
        out.append(le16(0))
        out.append(le16(UInt16(entries.count)))
        out.append(le16(UInt16(entries.count)))
        out.append(le32(UInt32(central.count)))
        out.append(le32(directoryOffset))
        out.append(le16(0))
        return out
    }

    /// An EOCD whose count and offset saturate, plus a Zip64 locator pointing
    /// at `recordOffset` — the smallest file that reaches the Zip64 path.
    static func zip64Locator(recordOffset: UInt64, prefix: Data = Data()) -> Data {
        var out = prefix
        out.append(contentsOf: [0x50, 0x4B, 0x06, 0x07]) // locator
        out.append(le32(0)) // disk
        out.append(le64(recordOffset))
        out.append(le32(1)) // total disks
        out.append(contentsOf: [0x50, 0x4B, 0x05, 0x06]) // EOCD
        out.append(le16(0))
        out.append(le16(0))
        out.append(le16(0xFFFF)) // count on disk, saturated
        out.append(le16(0xFFFF)) // total count, saturated
        out.append(le32(0)) // directory size
        out.append(le32(0xFFFF_FFFF)) // directory offset, saturated
        out.append(le16(0))
        return out
    }

    /// One central-directory entry whose 32-bit local-header offset saturates
    /// and whose Zip64 extra field carries `localOffset` as the real value.
    static func zip64ExtraArchive(localOffset: UInt64) -> Data {
        var out = Data()
        let name = Data("a".utf8)
        out.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
        out.append(le16(45))
        out.append(le16(45))
        out.append(le16(0))
        out.append(le16(0)) // stored
        out.append(le16(0)) // time
        out.append(le16(0)) // date
        out.append(le32(0)) // crc
        out.append(le32(4)) // compressed
        out.append(le32(4)) // uncompressed
        out.append(le16(UInt16(name.count)))
        out.append(le16(12)) // extra length: header + one 8-byte value
        out.append(le16(0)) // comment length
        out.append(le16(0)) // disk start
        out.append(le16(0)) // internal attributes
        out.append(le32(0)) // external attributes
        out.append(le32(0xFFFF_FFFF)) // local offset, saturated
        out.append(name)
        out.append(le16(0x0001)) // Zip64 extra header
        out.append(le16(8))
        out.append(le64(localOffset))

        let directorySize = UInt32(out.count)
        out.append(contentsOf: [0x50, 0x4B, 0x05, 0x06]) // EOCD
        out.append(le16(0))
        out.append(le16(0))
        out.append(le16(1))
        out.append(le16(1))
        out.append(le32(directorySize))
        out.append(le32(0)) // directory at the start
        out.append(le16(0))
        return out
    }
}

@Suite("Hostile archives throw instead of trapping")
struct MalformedArchiveTests {
    /// The trap the fix removes: `Int(UInt64)` has no representable result for
    /// a locator offset with the top bit set, and aborted the process.
    @Test("a zip64 locator offset above Int.max is a thrown error")
    func locatorOffsetAboveIntMax() {
        let data = ZIPBytes.zip64Locator(recordOffset: 0x8000_0000_0000_0000)
        #expect(throws: EPUBError.self) { try EPUBArchive(data: data) }
    }

    /// Just under `Int.max` survives the conversion; the old `zip64 + 56`
    /// bounds check then overflowed instead. Subtraction-side bounds throw.
    @Test("a zip64 locator offset just under Int.max is a thrown error")
    func locatorOffsetJustUnderIntMax() {
        let data = ZIPBytes.zip64Locator(recordOffset: 0x7FFF_FFFF_FFFF_FFF0)
        #expect(throws: EPUBError.self) { try EPUBArchive(data: data) }
    }

    /// A fake Zip64 EOCD record the parser accepts, whose entry count no file
    /// this size could hold — unbounded, it fed `reserveCapacity` directly.
    /// The record deliberately opens with the signature the parser checks for.
    @Test("a zip64 record declaring an impossible entry count is a thrown error")
    func implausibleZip64Count() {
        var record = Data([0x50, 0x4B, 0x05, 0x06])
        record.append(ZIPBytes.le64(44)) // record size
        record.append(ZIPBytes.le16(45))
        record.append(ZIPBytes.le16(45))
        record.append(ZIPBytes.le32(0)) // disk
        record.append(ZIPBytes.le32(0)) // directory disk
        record.append(ZIPBytes.le64(0xFFFF_FFFF_FFFF)) // entries on disk
        record.append(ZIPBytes.le64(0xFFFF_FFFF_FFFF)) // total entries
        record.append(ZIPBytes.le64(46)) // directory size
        record.append(ZIPBytes.le64(0)) // directory offset
        let data = ZIPBytes.zip64Locator(recordOffset: 0, prefix: record)
        #expect(throws: EPUBError.self) { try EPUBArchive(data: data) }
    }

    /// The per-entry variant of the same trap: the Zip64 *extra field* carried
    /// the unrepresentable value, and `Int(UInt64)` aborted during open.
    @Test("a zip64 extra field above Int.max is a thrown error at open")
    func extraFieldAboveIntMax() {
        let data = ZIPBytes.zip64ExtraArchive(localOffset: 0x8000_0000_0000_0000)
        #expect(throws: EPUBError.self) { try EPUBArchive(data: data) }
    }

    /// A representable but absurd local-header offset opened fine and then
    /// trapped on `base + 30` in `extract`. It must fail as a *read* error —
    /// on the entry, when it is asked for, not the whole archive.
    @Test("an absurd zip64 local-header offset fails the read, not the process")
    func extraFieldJustUnderIntMax() throws {
        let archive = try EPUBArchive(data: ZIPBytes.zip64ExtraArchive(localOffset: 0x7FFF_FFFF_FFFF_FFF0))
        #expect(archive.contains("a"))
        #expect(throws: EPUBError.self) { try archive.read("a") }
    }

    /// The builder itself must produce archives the reader accepts, or every
    /// test above passes by failing early for the wrong reason.
    @Test("the crafted-archive builder round-trips through the reader")
    func builderRoundTrips() throws {
        let archive = try EPUBArchive(data: ZIPBytes.archive([
            .init(name: "mimetype", payload: Data("application/epub+zip".utf8)),
            .init(name: "dir/inner.txt", payload: Data("payload".utf8)),
        ]))
        #expect(String(decoding: try archive.read("mimetype"), as: UTF8.self) == "application/epub+zip")
        #expect(String(decoding: try archive.read("dir/inner.txt"), as: UTF8.self) == "payload")
        #expect(archive.size(of: "dir/inner.txt") == 7)
    }
}

@Suite("Inflate refuses implausible sizes")
struct InflateBoundsTests {
    /// Raw DEFLATE of "hello" — five bytes in, five out, a 0.7:1 ratio.
    static let helloDeflated = Data([0xCB, 0x48, 0xCD, 0xC9, 0xC9, 0x07, 0x00])

    @Test("a correct declared size still inflates")
    func inflatesWithDeclaredSize() throws {
        let inflated = try Inflate.raw(Self.helloDeflated, expectedSize: 5)
        #expect(String(decoding: inflated, as: UTF8.self) == "hello")
    }

    @Test("an unknown declared size still inflates")
    func inflatesWithUnknownSize() throws {
        let inflated = try Inflate.raw(Self.helloDeflated, expectedSize: 0)
        #expect(String(decoding: inflated, as: UTF8.self) == "hello")
    }

    /// DEFLATE cannot beat ~1032:1, so a seven-byte payload claiming
    /// gigabytes is a zip bomb. `Data(count:)` of that claim aborted the
    /// process before a single compressed byte was examined.
    @Test("a declared size no deflate stream could produce is a thrown error")
    func refusesImplausibleSize() {
        #expect(throws: EPUBError.self) { try Inflate.raw(Self.helloDeflated, expectedSize: Int.max) }
        #expect(throws: EPUBError.self) { try Inflate.raw(Self.helloDeflated, expectedSize: 1 << 40) }
    }

    /// The same bomb end-to-end: the declared size travels from the central
    /// directory through `extract`, and the first read throws.
    @Test("a zip bomb's first read throws rather than allocating its claim")
    func refusesBombInsideArchive() throws {
        let archive = try EPUBArchive(data: ZIPBytes.archive([
            .init(
                name: "bomb.xhtml", payload: Self.helloDeflated,
                method: 8, declaredUncompressedSize: 0xFFFF_FFFE,
            ),
        ]))
        #expect(throws: EPUBError.self) { try archive.read("bomb.xhtml") }
    }
}

/// Manifest hrefs are URIs: every mainstream producer writes a space as `%20`
/// and an accented letter as UTF-8 escapes, while the ZIP entry name holds the
/// raw characters. Compared byte-for-byte the two never match, and a
/// spec-conformant book was unreadable — every chapter a `missingResource`.
@Suite("Percent-encoded hrefs")
struct PercentEncodedHrefTests {
    @Test("resolve decodes the escapes producers actually write")
    func resolveDecodes() {
        #expect(EPUBPackage.resolve("Text/Chapter%201.xhtml", relativeTo: "OEBPS/content.opf")
            == "OEBPS/Text/Chapter 1.xhtml")
        #expect(EPUBPackage.resolve("Caf%C3%A9.xhtml", relativeTo: "OEBPS/content.opf")
            == "OEBPS/Café.xhtml")
        // A fragment is stripped before decoding, never decoded into the path.
        #expect(EPUBPackage.resolve("Chapter%201.xhtml#s%31", relativeTo: "OEBPS/nav.xhtml")
            == "OEBPS/Chapter 1.xhtml")
    }

    /// A bare `%` is not a legal escape; a sloppy producer that wrote one
    /// meant it literally, and decoding must not eat the whole href.
    @Test("an unencodable href is kept verbatim")
    func sloppyHrefSurvives() {
        #expect(EPUBPackage.resolve("100%.xhtml", relativeTo: "OEBPS/content.opf")
            == "OEBPS/100%.xhtml")
    }

    @Test("a book whose filenames need encoding opens end to end")
    func spacedFilenamesReadable() throws {
        let container = """
        <?xml version="1.0"?>
        <container version="1.0"><rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
        </rootfiles></container>
        """
        let opf = """
        <?xml version="1.0"?>
        <package version="3.0">
        <metadata><title>Spaced</title></metadata>
        <manifest>
        <item id="c1" href="Text/Chapter%201.xhtml" media-type="application/xhtml+xml"/>
        <item id="c2" href="Caf%C3%A9.xhtml" media-type="application/xhtml+xml"/>
        </manifest>
        <spine><itemref idref="c1"/><itemref idref="c2"/></spine>
        </package>
        """
        let chapter = "<html><body><p>Prose.</p></body></html>"
        let archive = try EPUBArchive(data: ZIPBytes.archive([
            .init(name: "mimetype", payload: Data("application/epub+zip".utf8)),
            .init(name: "META-INF/container.xml", payload: Data(container.utf8)),
            .init(name: "OEBPS/content.opf", payload: Data(opf.utf8)),
            .init(name: "OEBPS/Text/Chapter 1.xhtml", payload: Data(chapter.utf8)),
            .init(name: "OEBPS/Café.xhtml", payload: Data(chapter.utf8)),
        ]))
        let package = try EPUBPackage.open(archive: archive)

        #expect(package.spine.map(\.href) == ["OEBPS/Text/Chapter 1.xhtml", "OEBPS/Café.xhtml"])
        for item in package.spine {
            #expect(!(try package.archive.read(item.href).isEmpty), "unreadable spine item \(item.href)")
        }
        // The sizes must land too, or progress silently degrades to
        // index-weighting for exactly these books.
        #expect(package.spineWeights.allSatisfy { $0 > 0 })
    }
}
