import Compression
import Foundation

/// Raw DEFLATE decompression, which is what ZIP entries carry.
///
/// Apple's `COMPRESSION_ZLIB` is raw DEFLATE with no zlib wrapper, so it maps
/// directly onto ZIP's method 8. Using the system codec keeps this fast and
/// avoids vendoring a decompressor.
enum Inflate {
    static func raw(_ data: Data, expectedSize: Int) throws -> Data {
        guard !data.isEmpty else { return Data() }
        // DEFLATE tops out at roughly 1032:1, so a declared size beyond that
        // ratio is a lie about the archive — a zip bomb, not a big book.
        // Refusing it here turns what would be an arbitrarily large
        // `Data(count:)` (an uncatchable abort inside Foundation, reachable
        // from a ~140-byte file) into a thrown parse error. The floor keeps
        // tiny entries room to grow when no size was recorded at all.
        let plausibleCeiling = max(data.count * 1032, 64 * 1024)
        guard expectedSize <= plausibleCeiling else {
            throw EPUBError.malformedArchive("implausible uncompressed size \(expectedSize)")
        }
        // A stored-size of zero means the central directory did not know it;
        // fall back to a generous guess and grow if needed.
        var capacity = expectedSize > 0 ? expectedSize : max(data.count * 8, 64 * 1024)

        for _ in 0 ..< 4 {
            var output = Data(count: capacity)
            let written: Int = output.withUnsafeMutableBytes { outBuffer in
                data.withUnsafeBytes { inBuffer -> Int in
                    guard let dst = outBuffer.bindMemory(to: UInt8.self).baseAddress,
                          let src = inBuffer.bindMemory(to: UInt8.self).baseAddress
                    else { return 0 }
                    return compression_decode_buffer(
                        dst, capacity, src, data.count, nil, COMPRESSION_ZLIB,
                    )
                }
            }
            if written > 0, written < capacity || written == expectedSize {
                output.removeSubrange(written ..< output.count)
                return output
            }
            if written == capacity, expectedSize > 0 {
                // Filled exactly the expected size — that is success, not overflow.
                return output
            }
            // Growth stays under the same ceiling: DEFLATE cannot produce
            // more, so a corrupt stream fails after bounded retries instead of
            // quadrupling a declared-huge buffer toward an allocation abort.
            capacity = min(capacity * 4, plausibleCeiling)
        }
        throw EPUBError.malformedArchive("inflate failed")
    }
}
