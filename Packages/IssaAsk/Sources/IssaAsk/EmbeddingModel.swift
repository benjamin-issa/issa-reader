import Accelerate
import Foundation

/// An on-device dense text embedder behind a narrow protocol, matching
/// `AnswerModel`'s boundary so `AskIndexStore`, `SemanticRetriever` and
/// `AskEngine` stay independent of CoreML.
public protocol EmbeddingModel: Sendable {
    /// Stable identifier stored beside each vector in `embed_span.model` so
    /// switching embedding models re-embeds cleanly without mixing vector spaces.
    var modelID: String { get }

    /// Embeds a batch of strings, returning one L2-normalised vector per input.
    func embed(_ texts: [String], mode: EmbeddingMode) async throws -> [[Float]]
}

/// Asymmetric query vs. document prompt mode (matches EmbeddingGemma-2's
/// trained prefixes: retrieval quality drops if queries and passages share one).
public enum EmbeddingMode: String, Sendable, Hashable, Codable {
    case query
    case document
}

/// Vector math, compact SQLite serialisation, timing, and cross-architecture
/// IEEE-754 half-precision conversion backed by Apple Accelerate (`vDSP`/`vImage`).
public enum EmbeddingMath {
    /// L2-normalises `vector` (returns unchanged if norm is near zero).
    public static func l2Normalize(_ vector: [Float]) -> [Float] {
        guard !vector.isEmpty else { return vector }
        var sumSq: Float = 0
        vDSP_svesq(vector, 1, &sumSq, vDSP_Length(vector.count))
        let norm = sqrtf(sumSq)
        guard norm > 1e-12 else { return vector }
        var inverse = 1.0 / norm
        var out = [Float](repeating: 0, count: vector.count)
        vDSP_vsmul(vector, 1, &inverse, &out, 1, vDSP_Length(vector.count))
        return out
    }

    /// Dot product of two L2-normalised vectors (= cosine similarity).
    public static func cosine(_ first: [Float], _ second: [Float]) -> Float {
        let count = min(first.count, second.count)
        guard count > 0 else { return 0 }
        var dot: Float = 0
        first.withUnsafeBufferPointer { firstBuffer in
            second.withUnsafeBufferPointer { secondBuffer in
                guard let a = firstBuffer.baseAddress, let b = secondBuffer.baseAddress else { return }
                vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(count))
            }
        }
        return dot
    }

    /// True when `vector` is non-empty, finite, and has non-trivial norm.
    public static func isValidVector(_ vector: [Float]) -> Bool {
        guard !vector.isEmpty else { return false }
        var sumSq: Float = 0
        for value in vector {
            guard value.isFinite else { return false }
            sumSq += value * value
        }
        return sumSq > 1e-6
    }

    /// Whole milliseconds elapsed since `start` on `clock`.
    public static func milliseconds(since start: ContinuousClock.Instant, on clock: ContinuousClock) -> Int {
        let elapsed = start.duration(to: clock.now)
        return Int(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    /// Packs a `[Float]` as little-endian IEEE-754 float32 bytes for SQLite `BLOB`.
    public static func encodeFloat32(_ vector: [Float]) -> Data {
        var data = Data(capacity: vector.count * MemoryLayout<UInt32>.size)
        for value in vector {
            var littleEndian = value.bitPattern.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Unpacks little-endian float32 `BLOB` bytes back into `[Float]` safely
    /// without assuming pointer alignment on sliced `Data`.
    public static func decodeFloat32(_ data: Data) -> [Float] {
        let stride = MemoryLayout<UInt32>.size
        let count = data.count / stride
        guard count > 0 else { return [] }
        return data.withUnsafeBytes { raw in
            var out = [Float](repeating: 0, count: count)
            for index in 0..<count {
                let bits = raw.loadUnaligned(fromByteOffset: index * stride, as: UInt32.self)
                out[index] = Float(bitPattern: UInt32(littleEndian: bits))
            }
            return out
        }
    }

    /// IEEE-754 binary16 (`Float16`) conversion backed by `vImage`, compiling
    /// identically on arm64 and universal macOS x86_64 builds.
    public enum HalfFloat {
        /// IEEE-754 binary16 bit pattern for `1.0`.
        public static let oneBitPattern: UInt16 = 0x3C00

        /// Converts a contiguous buffer of IEEE-754 half-precision bit patterns
        /// into `Float` values using Accelerate `vImage`.
        public static func toFloats(_ bits: UnsafeBufferPointer<UInt16>) -> [Float] {
            guard !bits.isEmpty, let srcBase = bits.baseAddress else { return [] }
            var out = [Float](repeating: 0, count: bits.count)
            out.withUnsafeMutableBufferPointer { dst in
                var srcBuf = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: srcBase),
                    height: 1,
                    width: vImagePixelCount(bits.count),
                    rowBytes: bits.count * MemoryLayout<UInt16>.size,
                )
                var dstBuf = vImage_Buffer(
                    data: dst.baseAddress,
                    height: 1,
                    width: vImagePixelCount(bits.count),
                    rowBytes: bits.count * MemoryLayout<Float>.size,
                )
                vImageConvert_Planar16FtoPlanarF(&srcBuf, &dstBuf, 0)
            }
            return out
        }

        /// Converts a contiguous buffer of `Float` values into IEEE-754
        /// half-precision bit patterns stored at `destination`.
        public static func fromFloats(
            _ values: UnsafeBufferPointer<Float>,
            into destination: UnsafeMutablePointer<UInt16>,
        ) {
            guard !values.isEmpty, let srcBase = values.baseAddress else { return }
            var srcBuf = vImage_Buffer(
                data: UnsafeMutableRawPointer(mutating: srcBase),
                height: 1,
                width: vImagePixelCount(values.count),
                rowBytes: values.count * MemoryLayout<Float>.size,
            )
            var dstBuf = vImage_Buffer(
                data: destination,
                height: 1,
                width: vImagePixelCount(values.count),
                rowBytes: values.count * MemoryLayout<UInt16>.size,
            )
            vImageConvert_PlanarFtoPlanar16F(&srcBuf, &dstBuf, 0)
        }
    }
}
