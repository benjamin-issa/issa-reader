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
    /// and far below what the allocator will refuse. It bounds `raw`, which
    /// holds the whole entry in memory; `stream` writes to disk a slice at a
    /// time and so answers to a ceiling of its own instead.
    static let maximumEntrySize = 256 * 1024 * 1024

    /// The most `compressedSize` bytes of DEFLATE can honestly decode to, and
    /// never more than `cap`.
    ///
    /// DEFLATE tops out at roughly 1032:1, so a declared size beyond that ratio
    /// is a lie about the archive — a zip bomb, not a big book. The 64 KB floor
    /// keeps a tiny member's slack generous. Saturating rather than trapping:
    /// the compressed size can come out of a zip64 field, attacker-chosen and
    /// near `Int.max`.
    static func plausibleCeiling(compressedSize: Int, cap: Int = maximumEntrySize) -> Int {
        let (ratio, overflow) = max(compressedSize, 0).multipliedReportingOverflow(by: 1032)
        return min(max(overflow ? Int.max : ratio, 64 * 1024), cap)
    }

    static func raw(_ data: Data, expectedSize: Int, maximumSize: Int = maximumEntrySize) throws -> Data {
        guard !data.isEmpty else { return Data() }
        // A valid stream can decode to nothing: Python's zipfile writes empty
        // members as the two-byte payload 03 00, and `compression_decode_buffer`
        // answers 0 for it — indistinguishable, to the loop below, from failure.
        // Four retries later that became "inflate failed", so a book with an
        // empty stylesheet had that entry permanently unreadable and the font
        // resolver reported no embedded font for a book that embeds one.
        guard expectedSize != 0 || data.count > 2 else { return Data() }

        // A declared size past what the payload could decode to is a lie, and
        // past `maximumSize` it is more than this whole-in-memory read will
        // hold: `EPUBArchive.extract(_:to:)` streams anything bigger to disk.
        let plausibleCeiling = plausibleCeiling(compressedSize: data.count, cap: maximumSize)
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

    /// Inflates `source` a slice at a time, handing each slice to `write`, and
    /// returns how many bytes it wrote.
    ///
    /// The checks are `raw`'s, with `ceiling` in place of `maximumEntrySize`:
    /// a declared size past what the payload could decode to is refused before
    /// a byte is written, and a stream that runs past its declared size — or,
    /// declaring none, past that ceiling — is refused the moment it does. No
    /// more than `sliceSize` bytes of output are ever held in memory, so the
    /// ceiling is about disk and honesty, not about the allocator.
    static func stream(
        _ source: UnsafeRawBufferPointer, expectedSize: Int, ceiling: Int, sliceSize: Int,
        write: (UnsafeRawBufferPointer) throws -> Void,
    ) throws -> Int {
        guard !source.isEmpty else { return 0 }
        // The empty member Python's zipfile writes; see `raw`.
        guard expectedSize != 0 || source.count > 2 else { return 0 }
        let plausible = plausibleCeiling(compressedSize: source.count, cap: ceiling)
        guard expectedSize <= plausible else {
            throw EPUBError.malformedArchive("implausible uncompressed size \(expectedSize)")
        }
        let limit = expectedSize > 0 ? expectedSize : plausible
        guard let input = source.bindMemory(to: UInt8.self).baseAddress, sliceSize > 0 else { return 0 }

        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
            == COMPRESSION_STATUS_OK
        else { throw EPUBError.malformedArchive("inflate failed") }
        defer { compression_stream_destroy(stream) }

        let slice = UnsafeMutablePointer<UInt8>.allocate(capacity: sliceSize)
        defer { slice.deallocate() }
        stream.pointee.src_ptr = input
        stream.pointee.src_size = source.count

        var written = 0
        while true {
            stream.pointee.dst_ptr = slice
            stream.pointee.dst_size = sliceSize
            // The whole payload is already in `src`, so every call finalises.
            let status = compression_stream_process(
                stream, Int32(bitPattern: COMPRESSION_STREAM_FINALIZE.rawValue))
            let produced = sliceSize - stream.pointee.dst_size
            written += produced
            guard written <= limit else {
                throw EPUBError.malformedArchive(expectedSize > 0
                    ? "entry inflates past its declared size of \(expectedSize)"
                    : "implausible uncompressed size past \(limit)")
            }
            if produced > 0 { try write(UnsafeRawBufferPointer(start: slice, count: produced)) }
            switch status {
            case COMPRESSION_STATUS_END:
                return written
            case COMPRESSION_STATUS_OK where produced > 0:
                continue
            case COMPRESSION_STATUS_OK:
                // All the input consumed, nothing produced, and no end of
                // stream: the payload was cut short.
                throw EPUBError.malformedArchive("truncated deflate stream")
            default:
                throw EPUBError.malformedArchive("inflate failed")
            }
        }
    }
}
