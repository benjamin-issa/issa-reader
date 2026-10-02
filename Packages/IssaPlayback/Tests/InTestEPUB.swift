import Compression
import Foundation

/// A minimal read-along EPUB built in the test, byte by byte.
///
/// For the shapes no fixture book has: an audio member far larger than any
/// file worth checking in. Text members are stored; the audio member is
/// deflated by streaming, so a member that inflates to hundreds of megabytes
/// costs a few hundred kilobytes here.
enum InTestEPUB {
    struct Member {
        let name: String
        let payload: Data
        let method: UInt16
        let uncompressedSize: Int
    }

    static func stored(_ name: String, _ text: String) -> Member {
        let data = Data(text.utf8)
        return Member(name: name, payload: data, method: 0, uncompressedSize: data.count)
    }

    /// `count` zero bytes, deflated a megabyte at a time.
    static func deflatedZeros(_ name: String, count: Int) throws -> Member {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB)
            == COMPRESSION_STATUS_OK else { throw CocoaError(.featureUnsupported) }
        defer { compression_stream_destroy(stream) }
        let chunk = 1 << 20
        let zeros = [UInt8](repeating: 0, count: chunk)
        var output = [UInt8](repeating: 0, count: chunk)
        var compressed = Data()
        var remaining = count
        try zeros.withUnsafeBufferPointer { input in
            try output.withUnsafeMutableBufferPointer { out in
                var finished = false
                while !finished {
                    let take = min(remaining, chunk)
                    stream.pointee.src_ptr = input.baseAddress!
                    stream.pointee.src_size = take
                    remaining -= take
                    let flags = remaining == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                    repeat {
                        stream.pointee.dst_ptr = out.baseAddress!
                        stream.pointee.dst_size = chunk
                        let status = compression_stream_process(stream, flags)
                        guard status != COMPRESSION_STATUS_ERROR else { throw CocoaError(.featureUnsupported) }
                        compressed.append(out.baseAddress!, count: chunk - stream.pointee.dst_size)
                        if status == COMPRESSION_STATUS_END { finished = true; break }
                    } while stream.pointee.src_size > 0 || stream.pointee.dst_size == 0
                }
            }
        }
        return Member(name: name, payload: compressed, method: 8, uncompressedSize: count)
    }

    /// A package with one chapter whose overlay names `audio`, and `audio`
    /// itself, in a structurally valid archive.
    static func readalong(audio: Member) -> Data {
        archive([
            stored("mimetype", "application/epub+zip"),
            stored("META-INF/container.xml", """
                <?xml version="1.0"?>
                <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
                  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
                </container>
                """),
            stored("OEBPS/content.opf", """
                <?xml version="1.0"?>
                <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
                  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                    <dc:identifier id="id">in-test</dc:identifier><dc:title>In Test</dc:title>
                  </metadata>
                  <manifest>
                    <item id="ch01" href="ch01.xhtml" media-type="application/xhtml+xml"/>
                    <item id="audio" href="Audio/big.mp3" media-type="audio/mpeg"/>
                  </manifest>
                  <spine><itemref idref="ch01"/></spine>
                </package>
                """),
            stored("OEBPS/ch01.xhtml", "<html><body><p id=\"s0\">One.</p></body></html>"),
            audio,
        ])
    }

    static func archive(_ members: [Member]) -> Data {
        func le16(_ value: UInt16) -> Data { Data([UInt8(value & 0xFF), UInt8(value >> 8)]) }
        func le32(_ value: UInt32) -> Data { Data((0 ..< 4).map { UInt8((value >> ($0 * 8)) & 0xFF) }) }
        var out = Data()
        var central = Data()
        for member in members {
            let name = Data(member.name.utf8)
            let offset = UInt32(out.count)
            out.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])
            out.append(le16(20)); out.append(le16(0)); out.append(le16(member.method))
            out.append(le16(0)); out.append(le16(0)); out.append(le32(0))
            out.append(le32(UInt32(member.payload.count))); out.append(le32(UInt32(member.uncompressedSize)))
            out.append(le16(UInt16(name.count))); out.append(le16(0))
            out.append(name); out.append(member.payload)

            central.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
            central.append(le16(20)); central.append(le16(20)); central.append(le16(0))
            central.append(le16(member.method)); central.append(le16(0)); central.append(le16(0))
            central.append(le32(0))
            central.append(le32(UInt32(member.payload.count))); central.append(le32(UInt32(member.uncompressedSize)))
            central.append(le16(UInt16(name.count))); central.append(le16(0)); central.append(le16(0))
            central.append(le16(0)); central.append(le16(0)); central.append(le32(0))
            central.append(le32(offset)); central.append(name)
        }
        let directoryOffset = UInt32(out.count)
        out.append(central)
        out.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
        out.append(le16(0)); out.append(le16(0))
        out.append(le16(UInt16(members.count))); out.append(le16(UInt16(members.count)))
        out.append(le32(UInt32(central.count))); out.append(le32(directoryOffset)); out.append(le16(0))
        return out
    }
}
