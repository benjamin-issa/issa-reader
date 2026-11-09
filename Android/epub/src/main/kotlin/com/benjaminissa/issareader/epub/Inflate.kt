package com.benjaminissa.issareader.epub

import java.util.zip.DataFormatException
import java.util.zip.Inflater

/**
 * Raw DEFLATE decompression, which is what ZIP entries carry.
 *
 * `Inflater(nowrap = true)` is raw DEFLATE with no zlib wrapper, so it maps
 * directly onto ZIP's method 8, as Apple's `COMPRESSION_ZLIB` does for the
 * Swift side. The system codec keeps this fast and avoids vendoring a
 * decompressor. `java.util.zip.ZipFile` is not used, deliberately: it decides
 * for itself which of two central-directory records for one name wins, and
 * `EpubArchive` has to decide that the way `unzip` and epubcheck do.
 */
internal object Inflate {
    /**
     * The most any single entry may occupy in memory.
     *
     * The ratio ceiling below is not enough on its own, which is what the
     * comment there used to claim. It bounds compression *ratio*: a 4 MB
     * compressed entry declaring 4 GB uncompressed passes it comfortably
     * (4 MB × 1032 ≈ 4.1 GB), and the very next line then asked for a 4 GB
     * buffer — a kill on a device from a small download. An absolute cap is what
     * makes the promise true.
     *
     * 256 MB is far above any real EPUB resource — the largest thing in an
     * aligned readaloud is an audio track, and those are tens of megabytes —
     * and far below what the allocator will refuse. It bounds [raw], which
     * holds the whole entry in memory; [stream] writes to disk a slice at a
     * time and so answers to a ceiling of its own instead.
     */
    const val maximumEntrySize: Long = 256L * 1024 * 1024

    /** The largest array the JVM will allocate, whatever cap a caller asks for. */
    private const val largestArray = Int.MAX_VALUE - 8

    /**
     * The most `compressedSize` bytes of DEFLATE can honestly decode to, and
     * never more than `cap`.
     *
     * DEFLATE tops out at roughly 1032:1, so a declared size beyond that ratio
     * is a lie about the archive — a zip bomb, not a big book. The 64 KB floor
     * keeps a tiny member's slack generous. Saturating rather than wrapping:
     * the compressed size can come out of a zip64 field, attacker-chosen and
     * near `Long.MAX_VALUE`.
     */
    fun plausibleCeiling(compressedSize: Long, cap: Long = maximumEntrySize): Long {
        val size = maxOf(compressedSize, 0)
        val ratio = if (size > Long.MAX_VALUE / 1032) Long.MAX_VALUE else size * 1032
        return minOf(maxOf(ratio, 64L * 1024), cap)
    }

    fun raw(data: ByteArray, expectedSize: Long, maximumSize: Long = maximumEntrySize): ByteArray =
        raw(ByteRange.of(data), expectedSize, maximumSize)

    fun raw(source: ByteRange, expectedSize: Long, maximumSize: Long = maximumEntrySize): ByteArray {
        if (source.count == 0L) return ByteArray(0)
        // A valid stream can decode to nothing: Python's zipfile writes empty
        // members as the two-byte payload 03 00, and Apple's
        // `compression_decode_buffer` answers 0 for it — indistinguishable, to
        // the Swift loop, from failure. Four retries later that became "inflate
        // failed", so a book with an empty stylesheet had that entry
        // permanently unreadable and the font resolver reported no embedded
        // font for a book that embeds one.
        if (expectedSize == 0L && source.count <= 2) return ByteArray(0)

        // A declared size past what the payload could decode to is a lie, and
        // past `maximumSize` it is more than this whole-in-memory read will
        // hold: `EpubArchive.extract` streams anything bigger to disk.
        val plausibleCeiling = minOf(plausibleCeiling(source.count, maximumSize), largestArray.toLong())
        if (expectedSize > plausibleCeiling) {
            throw EpubError.MalformedArchive("implausible uncompressed size $expectedSize")
        }
        // A stored size of zero means the central directory did not know it.
        // The Swift loop guesses eight times the payload (at least 64 KB),
        // quadrupling up to three times within the ceiling, and gives up past
        // the last guess; the same guesses bound the output here, so an
        // undeclared entry decodes on Android exactly when it does on iOS.
        val limit = if (expectedSize > 0) expectedSize else undeclaredLimit(source.count, plausibleCeiling)

        val inflater = Inflater(true)
        try {
            val feeder = Feeder(source, inflater)
            feeder.feed()
            // A full buffer is not a finished entry: one more byte is asked for
            // before anything is returned, so "filled the buffer exactly" can be
            // told apart from "had more to write". The Swift loop asks for the
            // same byte: Apple's codec returns `dst_size` both when it filled the
            // buffer exactly and when it had more to write, so an entry declaring
            // 1,024 bytes that really inflated to 40 KB used to return the first
            // 1,024 as a success — a chapter came back as a fragment, or an OPF
            // was cut mid-tag and the book reported malformedPackage, blaming
            // the XML.
            var buffer = ByteArray(minOf(limit, initialCapacity(source.count, expectedSize, plausibleCeiling)).toInt())
            val probe = ByteArray(1)
            var written = 0
            while (true) {
                val produced: Int
                if (written == buffer.size) {
                    if (written < limit) {
                        buffer = buffer.copyOf(minOf(buffer.size.toLong() * 2, limit).toInt())
                        continue
                    }
                    produced = inflater.inflate(probe, 0, 1)
                    if (produced > 0) {
                        // Overflowed. With a size declared in the central
                        // directory that means the entry lied and there is no
                        // honest result to return; with none it means the last
                        // guess was too small, and Swift gives up there too.
                        throw EpubError.MalformedArchive(
                            if (expectedSize > 0) "entry inflates past its declared size of $expectedSize" else "inflate failed",
                        )
                    }
                } else {
                    produced = inflater.inflate(buffer, written, buffer.size - written)
                    written += produced
                }
                if (inflater.finished()) break
                if (produced == 0) {
                    if (inflater.needsDictionary()) throw EpubError.MalformedArchive("inflate failed")
                    if (inflater.needsInput() && !feeder.feed()) {
                        // All the input consumed and no end of stream: the
                        // payload was cut short.
                        if (expectedSize > 0) throw shortOf(written.toLong(), expectedSize)
                        throw EpubError.MalformedArchive("truncated deflate stream")
                    }
                }
            }
            // A declared size is a claim about the payload, checked in both
            // directions: the stored-entry paths already refuse a payload of any
            // other length, and a stream that ends short is a truncated entry
            // returned as if it were whole.
            if (expectedSize > 0 && written.toLong() != expectedSize) throw shortOf(written.toLong(), expectedSize)
            return if (written == buffer.size) buffer else buffer.copyOf(written)
        } catch (_: DataFormatException) {
            throw EpubError.MalformedArchive("inflate failed")
        } finally {
            inflater.end()
        }
    }

    /**
     * Inflates `source` a slice at a time, handing each slice to `write`, and
     * returns how many bytes it wrote.
     *
     * The checks are [raw]'s, with `ceiling` in place of [maximumEntrySize]: a
     * declared size past what the payload could decode to is refused before a
     * byte is written, and a stream that runs past its declared size — or,
     * declaring none, past that ceiling — is refused the moment it does. No more
     * than `sliceSize` bytes of output are ever held in memory, so the ceiling
     * is about disk and honesty, not about the allocator.
     */
    fun stream(
        source: ByteRange,
        expectedSize: Long,
        ceiling: Long,
        sliceSize: Int,
        write: (ByteArray, Int) -> Unit,
    ): Long {
        if (source.count == 0L) return 0
        // The empty member Python's zipfile writes; see `raw`.
        if (expectedSize == 0L && source.count <= 2) return 0
        val plausible = plausibleCeiling(source.count, ceiling)
        if (expectedSize > plausible) throw EpubError.MalformedArchive("implausible uncompressed size $expectedSize")
        val limit = if (expectedSize > 0) expectedSize else plausible
        if (sliceSize <= 0) return 0

        val inflater = Inflater(true)
        try {
            val feeder = Feeder(source, inflater)
            feeder.feed()
            val slice = ByteArray(sliceSize)
            var written = 0L
            while (true) {
                val produced = inflater.inflate(slice, 0, sliceSize)
                written += produced
                if (written > limit) {
                    throw EpubError.MalformedArchive(
                        if (expectedSize > 0) {
                            "entry inflates past its declared size of $expectedSize"
                        } else {
                            "implausible uncompressed size past $limit"
                        },
                    )
                }
                if (produced > 0) write(slice, produced)
                if (inflater.finished()) {
                    if (expectedSize != 0L && written != expectedSize) throw shortOf(written, expectedSize)
                    return written
                }
                if (produced == 0) {
                    if (inflater.needsDictionary()) throw EpubError.MalformedArchive("inflate failed")
                    // All the input consumed, nothing produced, and no end of
                    // stream: the payload was cut short.
                    if (inflater.needsInput() && !feeder.feed()) {
                        throw EpubError.MalformedArchive("truncated deflate stream")
                    }
                }
            }
        } catch (_: DataFormatException) {
            throw EpubError.MalformedArchive("inflate failed")
        } finally {
            inflater.end()
        }
    }

    private fun shortOf(written: Long, expectedSize: Long) =
        EpubError.MalformedArchive("entry inflates to $written bytes, short of its declared size of $expectedSize")

    /** The first guess Swift's loop makes: the declared size, or eight times the payload, at least 64 KB. */
    private fun initialCapacity(compressedSize: Long, expectedSize: Long, ceiling: Long): Long =
        if (expectedSize > 0) {
            expectedSize
        } else {
            minOf(maxOf(saturatingTimes(compressedSize, 8), 64L * 1024), ceiling)
        }

    /** The last of Swift's four guesses for an undeclared size: the first, quadrupled while under the ceiling. */
    private fun undeclaredLimit(compressedSize: Long, ceiling: Long): Long {
        var capacity = initialCapacity(compressedSize, 0, ceiling)
        repeat(3) {
            if (capacity >= ceiling) return capacity
            capacity = minOf(saturatingTimes(capacity, 4), ceiling)
        }
        return capacity
    }

    private fun saturatingTimes(value: Long, factor: Long): Long =
        if (value > Long.MAX_VALUE / factor) Long.MAX_VALUE else value * factor

    /**
     * Hands the payload to the inflater a chunk at a time, out of the mapped
     * archive, and then one dummy zero byte: zlib's raw mode may need a byte
     * past the end to report the end of the stream, and `java.util.zip`'s own
     * readers supply it. A zero byte cannot complete a block, so it never turns
     * a truncated stream into a whole one.
     */
    private class Feeder(private val source: ByteRange, private val inflater: Inflater) {
        private val chunk = ByteArray(minOf(source.count, 64L * 1024).toInt().coerceAtLeast(1))
        private var offset = 0L
        private var suppliedDummy = false

        fun feed(): Boolean {
            if (offset < source.count) {
                val count = minOf(chunk.size.toLong(), source.count - offset).toInt()
                source.bytes.read(source.start + offset, chunk, 0, count)
                offset += count
                inflater.setInput(chunk, 0, count)
                return true
            }
            if (!suppliedDummy) {
                suppliedDummy = true
                chunk[0] = 0
                inflater.setInput(chunk, 0, 1)
                return true
            }
            return false
        }
    }
}
