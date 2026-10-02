import Foundation
import IssaEPUB

/// A small EPUB built in the test, byte by byte, for the shapes no fixture has.
///
/// Built here rather than added to the bundle: the app test target's resources
/// are listed in `project.yml`, which no stream edits, and a book written out in
/// the test says what it is right where it is used — a chapter whose markup
/// will not parse, or one long enough that a stale offset crosses a page.
///
/// Stored, not deflated, and with no checksums: `EPUBArchive` reads neither,
/// and the bytes stay legible in a debugger.
enum TestEPUB {
    struct Chapter {
        /// The manifest id, and the file's name without its extension.
        let id: String
        /// What the contents list calls it.
        let title: String
        /// Everything inside `<body>`, as markup.
        let body: String
        /// The element ids its media overlay narrates, in order, a second
        /// each of the book's one audio file. Empty for a chapter with none.
        var narrated: [String] = []
    }

    /// The spine href `open` gives a chapter, for asserting against.
    static func href(of chapter: Chapter) -> String { "OEBPS/\(chapter.id).xhtml" }

    /// The archive path of the audio every narrated chapter plays.
    static let audioHref = "OEBPS/narration.wav"

    /// The whole book, as the bytes of a `.epub`.
    ///
    /// - Parameter audio: the bytes of the one audio file the overlays point
    ///   at; needed whenever a chapter is narrated.
    static func data(title: String = "A Test Book", chapters: [Chapter], audio: Data? = nil) -> Data {
        let container = """
        <?xml version="1.0" encoding="utf-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """
        var manifest = chapters.map { chapter in
            let overlay = chapter.narrated.isEmpty ? "" : " media-overlay=\"\(chapter.id)_overlay\""
            return "<item id=\"\(chapter.id)\" href=\"\(chapter.id).xhtml\" "
                + "media-type=\"application/xhtml+xml\"\(overlay)/>"
        }.joined(separator: "\n")
        for chapter in chapters where !chapter.narrated.isEmpty {
            manifest += "\n<item id=\"\(chapter.id)_overlay\" href=\"\(chapter.id).smil\" "
                + "media-type=\"application/smil+xml\"/>"
        }
        if audio != nil {
            manifest += "\n<item id=\"narration\" href=\"narration.wav\" media-type=\"audio/wav\"/>"
        }
        let spine = chapters.map { "<itemref idref=\"\($0.id)\"/>" }.joined()
        let opf = """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="uid">urn:uuid:issa-test-epub</dc:identifier>
        <dc:title>\(title)</dc:title><dc:language>en</dc:language>
        </metadata>
        <manifest>
        <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
        \(manifest)
        </manifest>
        <spine>\(spine)</spine>
        </package>
        """
        let entries = chapters.map {
            "<li><a href=\"\($0.id).xhtml\">\($0.title)</a></li>"
        }.joined()
        let nav = """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>Contents</title></head>
        <body><nav epub:type="toc"><ol>\(entries)</ol></nav></body>
        </html>
        """
        var files: [(String, String)] = [
            ("mimetype", "application/epub+zip"),
            ("META-INF/container.xml", container),
            ("OEBPS/content.opf", opf),
            ("OEBPS/nav.xhtml", nav),
        ]
        // Clips run on through the one file from chapter to chapter, a second
        // each, so no two sentences claim the same moment of it.
        var second = 0
        for chapter in chapters {
            files.append((href(of: chapter), """
            <?xml version="1.0" encoding="utf-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml">
            <head><title>\(chapter.title)</title></head>
            <body>\(chapter.body)</body>
            </html>
            """))
            guard !chapter.narrated.isEmpty else { continue }
            let first = second
            second += chapter.narrated.count
            let pars = chapter.narrated.enumerated().map { index, id in
                """
                <par id="\(chapter.id)-par\(index)"><text src="\(chapter.id).xhtml#\(id)"/>\
                <audio src="narration.wav" clipBegin="\(first + index).000s" \
                clipEnd="\(first + index + 1).000s"/></par>
                """
            }.joined(separator: "\n")
            files.append(("OEBPS/\(chapter.id).smil", """
            <?xml version="1.0" encoding="utf-8"?>
            <smil xmlns="http://www.w3.org/ns/SMIL" xmlns:epub="http://www.idpf.org/2007/ops" version="3.0">
            <body><seq epub:textref="\(chapter.id).xhtml">
            \(pars)
            </seq></body>
            </smil>
            """))
        }
        var members = files.map { ($0.0, Data($0.1.utf8)) }
        if let audio { members.append((audioHref, audio)) }
        return zip(members)
    }

    /// The book, opened.
    static func package(
        title: String = "A Test Book", chapters: [Chapter], audio: Data? = nil,
    ) throws -> EPUBPackage {
        try EPUBPackage.open(archive: EPUBArchive(data: data(title: title, chapters: chapters, audio: audio)))
    }

    // MARK: - ZIP

    private static func le16(_ value: Int) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    private static func le32(_ value: Int) -> Data {
        Data((0 ..< 4).map { UInt8((value >> ($0 * 8)) & 0xFF) })
    }

    /// A structurally valid archive of stored entries.
    private static func zip(_ entries: [(name: String, payload: Data)]) -> Data {
        var out = Data()
        var central = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let offset = out.count
            out.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])
            out.append(le16(20)) // version needed
            out.append(le16(0)) // flags
            out.append(le16(0)) // stored
            out.append(le16(0)) // time
            out.append(le16(0)) // date
            out.append(le32(0)) // crc, unread
            out.append(le32(entry.payload.count))
            out.append(le32(entry.payload.count))
            out.append(le16(name.count))
            out.append(le16(0)) // extra length
            out.append(name)
            out.append(entry.payload)

            central.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
            central.append(le16(20)) // version made by
            central.append(le16(20)) // version needed
            central.append(le16(0)) // flags
            central.append(le16(0)) // stored
            central.append(le16(0)) // time
            central.append(le16(0)) // date
            central.append(le32(0)) // crc
            central.append(le32(entry.payload.count))
            central.append(le32(entry.payload.count))
            central.append(le16(name.count))
            central.append(le16(0)) // extra length
            central.append(le16(0)) // comment length
            central.append(le16(0)) // disk start
            central.append(le16(0)) // internal attributes
            central.append(le32(0)) // external attributes
            central.append(le32(offset))
            central.append(name)
        }
        let directoryOffset = out.count
        out.append(central)
        out.append(contentsOf: [0x50, 0x4B, 0x05, 0x06]) // end of central directory
        out.append(le16(0))
        out.append(le16(0))
        out.append(le16(entries.count))
        out.append(le16(entries.count))
        out.append(le32(central.count))
        out.append(le32(directoryOffset))
        out.append(le16(0))
        return out
    }
}
