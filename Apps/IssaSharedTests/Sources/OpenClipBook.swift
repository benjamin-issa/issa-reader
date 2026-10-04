import Foundation

/// A read-along whose overlay gives clips a `clipBegin` and no `clipEnd`,
/// built in the test: the shape another toolchain's EPUB has, which no
/// Storyteller book does. One audio file per chapter, each a real WAV of
/// silence of the length the test names, so its true length is something
/// AVFoundation can measure.
///
/// `TestEPUB` has one audio file and states every end; the app bundle's
/// resources are listed in `project.yml`, which no stream edits, so the book is
/// written out here — stored, uncompressed, with no checksums, which
/// `EPUBArchive` reads.
enum OpenClipBook {
    struct Chapter {
        let id: String
        let title: String
        /// Seconds of audio in this chapter's file.
        let seconds: Int
        /// Where each sentence's clip begins in that file. None states an end,
        /// so the last runs to the end of the file.
        let clipBegins: [Double]
    }

    static func audioHref(of chapter: Chapter) -> String { "OEBPS/Audio/\(chapter.id).wav" }
    static func href(of chapter: Chapter) -> String { "OEBPS/\(chapter.id).xhtml" }

    static func data(chapters: [Chapter]) -> Data {
        var members: [(String, Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """.utf8)),
        ]
        var manifest = "<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>"
        for chapter in chapters {
            manifest += """
            <item id="\(chapter.id)" href="\(chapter.id).xhtml" media-type="application/xhtml+xml" \
            media-overlay="\(chapter.id)_overlay"/>
            <item id="\(chapter.id)_overlay" href="\(chapter.id).smil" media-type="application/smil+xml"/>
            <item id="\(chapter.id)_audio" href="Audio/\(chapter.id).wav" media-type="audio/wav"/>
            """
        }
        let spine = chapters.map { "<itemref idref=\"\($0.id)\"/>" }.joined()
        members.append(("OEBPS/content.opf", Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="uid">urn:uuid:issa-open-clip-book</dc:identifier>
        <dc:title>The Open Clips</dc:title><dc:language>en</dc:language>
        </metadata>
        <manifest>\(manifest)</manifest>
        <spine>\(spine)</spine>
        </package>
        """.utf8)))
        let entries = chapters.map { "<li><a href=\"\($0.id).xhtml\">\($0.title)</a></li>" }.joined()
        members.append(("OEBPS/nav.xhtml", Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>Contents</title></head>
        <body><nav epub:type="toc"><ol>\(entries)</ol></nav></body>
        </html>
        """.utf8)))
        for chapter in chapters {
            let sentences = chapter.clipBegins.indices.map { index in
                "<p><span id=\"\(chapter.id)-s\(index)\">Sentence \(index) of \(chapter.title), "
                    + "spoken for as long as its clip runs on.</span></p>"
            }.joined()
            members.append((href(of: chapter), Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml">
            <head><title>\(chapter.title)</title></head>
            <body><h1>\(chapter.title)</h1>\(sentences)</body>
            </html>
            """.utf8)))
            let pars = chapter.clipBegins.enumerated().map { index, begin in
                """
                <par id="\(chapter.id)-par\(index)"><text src="\(chapter.id).xhtml#\(chapter.id)-s\(index)"/>\
                <audio src="Audio/\(chapter.id).wav" clipBegin="\(begin)s"/></par>
                """
            }.joined(separator: "\n")
            members.append(("OEBPS/\(chapter.id).smil", Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <smil xmlns="http://www.w3.org/ns/SMIL" xmlns:epub="http://www.idpf.org/2007/ops" version="3.0">
            <body><seq epub:textref="\(chapter.id).xhtml">
            \(pars)
            </seq></body>
            </smil>
            """.utf8)))
            members.append((audioHref(of: chapter), SilentAudio.wav(seconds: chapter.seconds)))
        }
        return zip(members)
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
            out.append(le16(20) + le16(0) + le16(0) + le16(0) + le16(0))
            out.append(le32(0) + le32(entry.payload.count) + le32(entry.payload.count))
            out.append(le16(name.count) + le16(0))
            out.append(name)
            out.append(entry.payload)

            central.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
            central.append(le16(20) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0))
            central.append(le32(0) + le32(entry.payload.count) + le32(entry.payload.count))
            central.append(le16(name.count) + le16(0) + le16(0) + le16(0) + le16(0))
            central.append(le32(0) + le32(offset))
            central.append(name)
        }
        let directoryOffset = out.count
        out.append(central)
        out.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
        out.append(le16(0) + le16(0) + le16(entries.count) + le16(entries.count))
        out.append(le32(central.count) + le32(directoryOffset) + le16(0))
        return out
    }
}
