import Compression
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
    /// The shape a real zip64 EPUB has: a well-formed record the parser must
    /// read rather than reject. With the wrong signature constant this threw
    /// "bad zip64 record", so every genuine zip64 archive was permanently
    /// unopenable — permanently because the download is cached.
    @Test("a well-formed zip64 record is read, not rejected")
    func acceptsARealZip64Record() throws {
        var record = Data([0x50, 0x4B, 0x06, 0x06])
        record.append(ZIPBytes.le64(44))
        record.append(ZIPBytes.le16(45))
        record.append(ZIPBytes.le16(45))
        record.append(ZIPBytes.le32(0))
        record.append(ZIPBytes.le32(0))
        record.append(ZIPBytes.le64(0))   // entries on disk
        record.append(ZIPBytes.le64(0))   // total entries
        record.append(ZIPBytes.le64(0))   // directory size
        record.append(ZIPBytes.le64(0))   // directory offset
        let data = ZIPBytes.zip64Locator(recordOffset: 0, prefix: record)
        // An empty directory: nothing to read, but the record itself parsed.
        let archive = try EPUBArchive(data: data)
        #expect(!archive.contains("anything"))
    }

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
    ///
    /// `PK\x06\x06`, the real zip64 signature. This used to be `PK\x05\x06`
    /// with a comment calling it "the signature the parser checks for" — which
    /// was true, and was the bug: the parser checked for the regular EOCD's
    /// signature, so the fixture encoded the defect rather than catching it.
    @Test("a zip64 record declaring an impossible entry count is a thrown error")
    func implausibleZip64Count() {
        var record = Data([0x50, 0x4B, 0x06, 0x06])
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

/// `EPUBArchive.init(data:)` is public and takes any `Data` — including a
/// slice, whose indices do not start at zero. The word helpers were rebased on
/// `startIndex`; the two `subdata(in:)` calls were not, so a slice read the
/// wrong bytes for every entry name and payload.
@Suite("Archives opened from a Data slice")
struct SlicedArchiveTests {
    @Test("a slice with a non-zero startIndex reads exactly like the whole")
    func sliceReadsLikeWhole() throws {
        let whole = ZIPBytes.archive([
            .init(name: "mimetype", payload: Data("application/epub+zip".utf8)),
            .init(name: "OEBPS/ch1.xhtml", payload: Data("<html><body>one</body></html>".utf8)),
        ])
        let padded = Data([0xDE, 0xAD, 0xBE, 0xEF]) + whole
        let slice = padded[4...]
        #expect(slice.startIndex == 4)

        let archive = try EPUBArchive(data: slice)
        #expect(archive.contains("OEBPS/ch1.xhtml"))
        #expect(String(decoding: try archive.read("mimetype"), as: UTF8.self) == "application/epub+zip")
        let fromWhole = try EPUBArchive(data: whole).read("OEBPS/ch1.xhtml")
        #expect(try archive.read("OEBPS/ch1.xhtml") == fromWhole)
    }
}

/// A Zip64 extra field shorter than the values it claims. The reads were
/// bounded by the file, not by the field, so the parser carried on into the
/// next central-directory record and adopted its bytes as this entry's offset.
@Suite("Short zip64 extra fields")
struct TruncatedZip64ExtraTests {
    /// The same shape as `zip64ExtraArchive`, but the 0x0001 field declares
    /// only `declared` bytes of payload while the archive keeps eight.
    private static func archive(declaredFieldSize declared: UInt16) -> Data {
        var out = Data()
        let name = Data("a".utf8)
        out.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
        out.append(ZIPBytes.le16(45))
        out.append(ZIPBytes.le16(45))
        out.append(ZIPBytes.le16(0))
        out.append(ZIPBytes.le16(0))
        out.append(ZIPBytes.le16(0))
        out.append(ZIPBytes.le16(0))
        out.append(ZIPBytes.le32(0))
        out.append(ZIPBytes.le32(4))
        out.append(ZIPBytes.le32(4))
        out.append(ZIPBytes.le16(UInt16(name.count)))
        out.append(ZIPBytes.le16(12)) // extra length as stored
        out.append(ZIPBytes.le16(0))
        out.append(ZIPBytes.le16(0))
        out.append(ZIPBytes.le16(0))
        out.append(ZIPBytes.le32(0))
        out.append(ZIPBytes.le32(0xFFFF_FFFF)) // local offset, saturated
        out.append(name)
        out.append(ZIPBytes.le16(0x0001))
        out.append(ZIPBytes.le16(declared))
        out.append(ZIPBytes.le64(0)) // the bytes that would be read past the field

        let directorySize = UInt32(out.count)
        out.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
        out.append(ZIPBytes.le16(0))
        out.append(ZIPBytes.le16(0))
        out.append(ZIPBytes.le16(1))
        out.append(ZIPBytes.le16(1))
        out.append(ZIPBytes.le32(directorySize))
        out.append(ZIPBytes.le32(0))
        out.append(ZIPBytes.le16(0))
        return out
    }

    @Test("a field too short for the value it must hold is a thrown error")
    func shortFieldThrows() {
        #expect(throws: EPUBError.self) { try EPUBArchive(data: Self.archive(declaredFieldSize: 4)) }
    }

    @Test("a field of the right size still reads")
    func fullFieldReads() throws {
        let archive = try EPUBArchive(data: Self.archive(declaredFieldSize: 8))
        #expect(archive.contains("a"))
    }
}

/// An EPUB 3 navigation document that is present but unparseable must not
/// cost the book its table of contents when a good NCX sits beside it.
@Suite("Navigation fallback")
struct NavigationFallbackTests {
    @Test("a broken nav document falls back to the NCX")
    func brokenNavFallsBackToNCX() throws {
        let container = """
        <?xml version="1.0"?>
        <container version="1.0"><rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
        </rootfiles></container>
        """
        let opf = """
        <?xml version="1.0"?>
        <package version="3.0">
        <metadata><title>Fallback</title></metadata>
        <manifest>
        <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
        <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
        <item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
        </manifest>
        <spine toc="ncx"><itemref idref="c1"/></spine>
        </package>
        """
        let ncx = """
        <?xml version="1.0"?>
        <ncx version="2005-1"><navMap>
        <navPoint id="n1"><navLabel><text>Down the Rabbit-Hole</text></navLabel><content src="c1.xhtml"/></navPoint>
        </navMap></ncx>
        """
        let archive = try EPUBArchive(data: ZIPBytes.archive([
            .init(name: "mimetype", payload: Data("application/epub+zip".utf8)),
            .init(name: "META-INF/container.xml", payload: Data(container.utf8)),
            .init(name: "OEBPS/content.opf", payload: Data(opf.utf8)),
            .init(name: "OEBPS/nav.xhtml", payload: Data("<html><body><nav epub:type=\"toc\"><ol><li>".utf8)),
            .init(name: "OEBPS/toc.ncx", payload: Data(ncx.utf8)),
            .init(name: "OEBPS/c1.xhtml", payload: Data("<html><body><p>Prose.</p></body></html>".utf8)),
        ]))
        let package = try EPUBPackage.open(archive: archive)
        #expect(package.navigation.map(\.title) == ["Down the Rabbit-Hole"])
        #expect(package.navigation.first?.href == "OEBPS/c1.xhtml")
    }
}

@Suite("Inflate answers honestly about what it decoded")
struct InflateHonestyTests {
    /// The canonical empty DEFLATE stream, which Python's zipfile writes for
    /// any zero-byte member. `compression_decode_buffer` returns 0 for it —
    /// indistinguishable from failure to the old loop, which retried four times
    /// and then threw, so a book with an empty stylesheet had that entry
    /// permanently unreadable.
    @Test("a valid empty entry decodes to nothing, not to an error")
    func emptyEntryIsNotAFailure() throws {
        let empty = try Inflate.raw(Data([0x03, 0x00]), expectedSize: 0)
        #expect(empty.isEmpty)
    }

    /// An entry whose declared size understates the truth used to come back
    /// silently truncated: the codec returns `dst_size` both when it filled the
    /// buffer exactly and when it had more to write, and the old code read the
    /// first as success. A chapter came back as a fragment.
    @Test("an entry that inflates past its declared size is refused, not truncated")
    func understatedSizeIsRefused() throws {
        let payload = String(repeating: "the quick brown fox ", count: 400)
        let compressed = try #require(Self.deflate(Data(payload.utf8)))
        #expect(throws: EPUBError.self) {
            try Inflate.raw(compressed, expectedSize: 16)
        }
        // …and the honest size still round-trips.
        let round = try Inflate.raw(compressed, expectedSize: payload.utf8.count)
        #expect(String(decoding: round, as: UTF8.self) == payload)
    }

    /// The ratio ceiling bounds compression ratio, not memory. A 4 MB entry
    /// declaring 4 GB passed it and the next line asked for a 4 GB allocation.
    @Test("a declared size beyond the absolute cap is refused whatever the ratio")
    func absoluteCapIsEnforced() {
        let fourMegabytes = Data(repeating: 0x41, count: 4 * 1024 * 1024)
        #expect(throws: EPUBError.self) {
            try Inflate.raw(fourMegabytes, expectedSize: 4_000_000_000)
        }
        #expect(Inflate.maximumEntrySize < 4_000_000_000)
    }

    private static func deflate(_ data: Data) -> Data? {
        let room = data.count + 1024
        var out = Data(count: room)
        let written: Int = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                      let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(
                    d, room, s, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        out.removeSubrange(written ..< out.count)
        return out
    }
}

/// Two central-directory records for one normalised name.
///
/// `normalize` folds `./META-INF/container.xml` and `META-INF/container.xml`
/// into one key, and the first record has to win — `unzip`, epubcheck and every
/// server-side scanner take the first, so an archive whose trailing duplicate
/// points at a different OPF looked clean to all of them and loaded the second
/// here. That guard shipped as a bare `continue` above the loop's cursor
/// advance, so the one archive it existed for stalled the cursor on the
/// duplicate and lost every entry after it, throwing nothing. A book that opens
/// everywhere else became permanently unopenable, and the download is cached.
@Suite("A duplicate directory record")
struct DuplicateRecordTests {
    static let benign = "<container>benign</container>"
    static let hostile = "<container>hostile</container>"
    static let chapter = "<html>chapter one</html>"

    static func archive() -> Data {
        ZIPBytes.archive([
            .init(name: "META-INF/container.xml", payload: Data(benign.utf8)),
            .init(name: "./META-INF/container.xml", payload: Data(hostile.utf8)),
            .init(name: "OEBPS/ch1.xhtml", payload: Data(chapter.utf8)),
        ])
    }

    @Test("the first record wins")
    func firstRecordWins() throws {
        let archive = try EPUBArchive(data: Self.archive())
        let container = try archive.read("META-INF/container.xml")
        #expect(String(decoding: container, as: UTF8.self) == Self.benign,
                "the trailing duplicate shadowed the first record")
    }

    /// The regression the guard introduced: everything after the duplicate
    /// vanished. `ch1.xhtml` is the third record, behind the duplicate, and it
    /// has to still be there.
    @Test("the entries after the duplicate are still read")
    func laterEntriesSurvive() throws {
        let archive = try EPUBArchive(data: Self.archive())
        #expect(archive.contains("OEBPS/ch1.xhtml"),
                "the directory scan stalled on the duplicate and dropped what followed")
        let chapter = try archive.read("OEBPS/ch1.xhtml")
        #expect(String(decoding: chapter, as: UTF8.self) == Self.chapter)
        #expect(archive.paths.count == 2, "one key for the duplicate pair, plus the chapter")
    }
}
