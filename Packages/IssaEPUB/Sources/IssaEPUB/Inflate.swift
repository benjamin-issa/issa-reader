import Compression
import Foundation

/// Raw DEFLATE decompression, which is what ZIP entries carry.
///
/// Apple's `COMPRESSION_ZLIB` is raw DEFLATE with no zlib wrapper, so it maps
/// directly onto ZIP's method 8. Using the system codec keeps this fast and
/// avoids vendoring a decompressor.
enum Inflate {
    /// The most any single entry may occupy in memory.
    ///
    /// The ratio ceiling below is not enough on its own, which is what the
    /// comment there used to claim. It bounds compression *ratio*: a 4 MB
    /// compressed entry declaring 4 GB uncompressed passes it comfortably
    /// (4 MB × 1032 ≈ 4.1 GB), and the very next line then asks Foundation for
    /// `Data(count: 4_000_000_000)` — a jetsam kill on a device, an uncatchable
    /// malloc abort elsewhere, from a small download. An absolute cap is what
    /// makes the promise true.
    ///
    /// 256 MB is far above any real EPUB resource — the largest thing in an
    /// aligned readaloud is an audio track, and those are tens of megabytes —
    /// and far below what the allocator will refuse.
    static let maximumEntrySize = 256 * 1024 * 1024

    static func raw(_ data: Data, expectedSize: Int) throws -> Data {
        guard !data.isEmpty else { return Data() }
        // A valid stream can decode to nothing: Python's zipfile writes empty
        // members as the two-byte payload 03 00, and `compression_decode_buffer`
        // answers 0 for it — indistinguishable, to the loop below, from failure.
        // Four retries later that became "inflate failed", so a book with an
        // empty stylesheet had that entry permanently unreadable and the font
        // resolver reported no embedded font for a book that embeds one.
        guard expectedSize != 0 || data.count > 2 else { return Data() }

        // DEFLATE tops out at roughly 1032:1, so a declared size beyond that
        // ratio is a lie about the archive — a zip bomb, not a big book.
        let plausibleCeiling = min(max(data.count * 1032, 64 * 1024), maximumEntrySize)
        guard expectedSize <= plausibleCeiling else {
            throw EPUBError.malformedArchive("implausible uncompressed size \(expectedSize)")
        }
        // A stored-size of zero means the central directory did not know it;
        // fall back to a generous guess and grow if needed.
        var capacity = expectedSize > 0 ? expectedSize : min(
            max(data.count * 8, 64 * 1024), plausibleCeiling)

        for _ in 0 ..< 4 {
            // One byte more than declared, so "filled the buffer exactly" can be
            // told apart from "had more to write". `compression_decode_buffer`
            // returns `dst_size` in *both* cases — five bytes into a three-byte
            // buffer returns 3 — so an entry declaring 1,024 bytes that really
            // inflates to 40 KB used to return the first 1,024 as a success. A
            // chapter came back as a fragment, or an OPF was cut mid-tag and the
            // book reported malformedPackage, blaming the XML.
            let room = capacity + 1
            var output = Data(count: room)
            let written: Int = output.withUnsafeMutableBytes { outBuffer in
                data.withUnsafeBytes { inBuffer -> Int in
                    guard let dst = outBuffer.bindMemory(to: UInt8.self).baseAddress,
                          let src = inBuffer.bindMemory(to: UInt8.self).baseAddress
                    else { return 0 }
                    return compression_decode_buffer(
                        dst, room, src, data.count, nil, COMPRESSION_ZLIB,
                    )
                }
            }

            if written > capacity {
                // Overflowed the buffer. With a size declared in the central
                // directory that means the entry lied and there is no honest
                // result to return; with no declared size it only means this
                // guess was too small, so grow and try again.
                guard expectedSize == 0 else {
                    throw EPUBError.malformedArchive(
                        "entry inflates past its declared size of \(expectedSize)")
                }
            } else if written > 0 {
                output.removeSubrange(written ..< output.count)
                return output
            }
            if capacity >= plausibleCeiling { break }
            capacity = min(capacity * 4, plausibleCeiling)
        }
        throw EPUBError.malformedArchive("inflate failed")
    }
}
