package com.benjaminissa.issareader.epub

import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.StandardCopyOption

/**
 * Reads an EPUB's OCF container without unpacking it to disk.
 *
 * EPUBs are ZIP archives. This reads the central directory and inflates
 * individual entries on demand, so opening a 25 MB book costs a directory scan
 * rather than a full extraction — which is most of the difference between a
 * book opening instantly and opening after a visible pause.
 *
 * Immutable, and safe to read from several threads at once.
 */
class EpubArchive private constructor(private val data: ArchiveBytes) {
    internal class Entry(
        val path: String,
        val compressionMethod: Int,
        val compressedSize: Long,
        /**
         * What the central directory declares, checked against the payload
         * whenever the entry is read.
         */
        val uncompressedSize: Long,
        /** The declared size where it is one the entry could have; `null` where it is not. See [plausibleSize]. */
        val knownSize: Long?,
        val localHeaderOffset: Long,
    )

    private val entries: Map<String, Entry> = readCentralDirectory(data)

    constructor(data: ByteArray) : this(ArchiveBytes.of(ByteBuffer.wrap(data)))

    /**
     * The bytes from `data`'s position to its limit — a view that need not
     * start at zero, which is what Swift's `init(data:)` accepts as a `Data`
     * slice. Every read is rebased on that start.
     */
    constructor(data: ByteBuffer) : this(ArchiveBytes.of(data))

    /**
     * Mapped rather than read: the OS pages in only the bytes actually
     * touched, which matters for a large book on a memory-tight device.
     */
    constructor(file: File) : this(ArchiveBytes.map(file))

    /** Every entry's path, as the central directory names it after [normalize]. */
    val paths: List<String> get() = entries.keys.toList()

    operator fun contains(path: String): Boolean = entries.containsKey(normalize(path))

    /**
     * An entry's uncompressed size, from the central directory — no inflate.
     *
     * Used to weight a spine item's share of the book. Counting spine items
     * equally made a two-page front-matter wrapper worth as much as a
     * forty-page chapter, which is fine for a hidden Handoff payload and not
     * good enough for a percentage on screen.
     *
     * `null` for an entry whose declared size it could not have — see
     * [plausibleSize] — as well as for one that is not there.
     */
    fun sizeOf(path: String): Long? = entries[normalize(path)]?.knownSize

    /**
     * What [extract] would write for an entry, from the central directory — no
     * inflate.
     *
     * [sizeOf] answers for [read], whose whole entry is held in memory and so
     * is capped at [Inflate.maximumEntrySize]; a narration track past that is
     * streamed to disk on first open instead, up to [maximumExtractedSize], and
     * the room it takes is this. `null` for an entry that could not have its
     * declared size, or is not there.
     */
    fun extractedSizeOf(path: String): Long? {
        val entry = entries[normalize(path)] ?: return null
        return plausibleSize(
            declared = entry.uncompressedSize, compressed = entry.compressedSize,
            method = entry.compressionMethod, archiveLength = data.size, cap = maximumExtractedSize,
        )
    }

    /**
     * Inflates one entry. Throws rather than returning null so a corrupt book
     * reports where it failed.
     *
     * The whole entry is held in memory, so it is capped at
     * [Inflate.maximumEntrySize], stored or deflated; [extract] streams
     * anything bigger.
     */
    fun read(path: String): ByteArray = read(path, Inflate.maximumEntrySize)

    /** [read], with the in-memory cap injectable so a test can reach it. */
    internal fun read(path: String, maximumSize: Long): ByteArray {
        val entry = entries[normalize(path)] ?: throw EpubError.MissingResource(path)
        return extract(entry, maximumSize)
    }

    /**
     * Writes one entry to `to`, a slice at a time.
     *
     * For the members too big to hold in memory — narration audio above all,
     * which [read]'s 256 MB cap would otherwise refuse, losing the book its
     * narration. Stored members are copied straight out of the mapped file in
     * slices of about a megabyte; deflated ones are inflated through a stream
     * into a buffer of the same size, under the same declared-size and ratio
     * checks as [read] but with [maximumExtractedSize] for a ceiling.
     *
     * Written to `<destination>.partial` and renamed into place only once
     * whole, so a failure — a lying entry, a full disk — never leaves a
     * truncated file where a caller would take it for the real one. A file
     * already at the destination is replaced.
     *
     * @throws EpubError for an entry that is missing or lies about itself.
     * @throws IOException when the file cannot be written.
     */
    fun extract(path: String, to: File) {
        extract(path, to, ceiling = maximumExtractedSize, sliceSize = 1 shl 20)
    }

    /** [extract], with the ceiling and slice size injectable for tests. */
    internal fun extract(path: String, to: File, ceiling: Long, sliceSize: Int) {
        val entry = entries[normalize(path)] ?: throw EpubError.MissingResource(path)
        val payload = payloadRange(entry)
        val destination = to.absoluteFile
        val partial = File(destination.parentFile, destination.name + ".partial")
        partial.delete()
        try {
            FileOutputStream(partial).use { output ->
                write(entry, payload, output.channel, ceiling, sliceSize)
            }
            // rename(2), which replaces an existing destination atomically.
            Files.move(partial.toPath(), destination.toPath(), StandardCopyOption.ATOMIC_MOVE)
        } catch (failure: Throwable) {
            partial.delete()
            throw failure
        }
    }

    private fun write(entry: Entry, payload: ByteRange, channel: FileChannel, ceiling: Long, sliceSize: Int) {
        when (entry.compressionMethod) {
            0 -> {
                // The same rule as `extract(entry, maximumSize)`: a stored
                // entry is its own size.
                if (entry.uncompressedSize != payload.count) {
                    throw EpubError.MalformedArchive(
                        "stored entry declares ${entry.uncompressedSize} bytes but holds ${payload.count}",
                    )
                }
                if (payload.count > ceiling) {
                    throw EpubError.MalformedArchive("entry of ${payload.count} bytes is past the ceiling")
                }
                // Slices of the mapped file, not copies of it.
                data.forEachSlice(payload.start, payload.count, maxOf(sliceSize, 1)) { slice ->
                    while (slice.hasRemaining()) channel.write(slice)
                }
            }
            8 -> Inflate.stream(payload, entry.uncompressedSize, ceiling, sliceSize) { bytes, count ->
                val slice = ByteBuffer.wrap(bytes, 0, count)
                while (slice.hasRemaining()) channel.write(slice)
            }
            else -> throw EpubError.MalformedArchive("unsupported compression ${entry.compressionMethod}")
        }
    }

    // ZIP

    /** Where an entry's payload sits, as offsets from the start of the archive. */
    private fun payloadRange(entry: Entry): ByteRange {
        // The local header's name and extra-field lengths can differ from the
        // central directory's, so the payload offset must be read from it.
        //
        // Bounds are checked subtraction-side throughout: the offset and size
        // come out of the file, and adding 30 to an attacker-chosen value near
        // `Long.MAX_VALUE` wraps instead of failing.
        val base = entry.localHeaderOffset
        if (base < 0 || base > data.size - 30) throw EpubError.MalformedArchive("truncated local header")
        if (data.u32(base) != 0x0403_4B50L) throw EpubError.MalformedArchive("bad local signature")
        val nameLength = data.u16(base + 26)
        val extraLength = data.u16(base + 28)
        val start = base + 30 + nameLength + extraLength
        if (entry.compressedSize < 0 || entry.compressedSize > data.size - start) {
            throw EpubError.MalformedArchive("truncated entry ${entry.path}")
        }
        return ByteRange(data, start, entry.compressedSize)
    }

    private fun extract(entry: Entry, maximumSize: Long): ByteArray {
        // A range over the mapped file, not a copy of it: nothing is copied into
        // the heap until the cap below has been applied. A book from the
        // reader's own files can be 4 GB, and copying a multi-gigabyte member
        // out before asking how big it was got the app killed while it was
        // still checking the book.
        val payload = payloadRange(entry)
        return when (entry.compressionMethod) {
            0 -> {
                // A stored entry is its own uncompressed size by definition, so
                // a declared size that disagrees means the archive is lying.
                // Refused here so the read cannot return what the directory did
                // not describe; `sizeOf` is kept from reporting the lie by
                // `plausibleSize`, when the directory is first read, which is
                // the guard that protects `spineWeights`.
                if (entry.uncompressedSize != payload.count) {
                    throw EpubError.MalformedArchive(
                        "stored entry declares ${entry.uncompressedSize} bytes but holds ${payload.count}",
                    )
                }
                // The same in-memory cap a deflated entry answers to: stored or
                // not, the whole of it would be held at once. And never past the
                // largest array the JVM allocates, whatever cap is asked for.
                if (payload.count > maximumSize || payload.count > Int.MAX_VALUE - 8) {
                    throw EpubError.MalformedArchive("entry of ${payload.count} bytes is past read's cap")
                }
                // Copied out here, bounded, so the caller gets bytes indexed
                // from zero that do not pin the mapping.
                data.copy(payload.start, payload.count.toInt())
            }
            8 -> Inflate.raw(payload, expectedSize = entry.uncompressedSize, maximumSize = maximumSize)
            else -> throw EpubError.MalformedArchive("unsupported compression ${entry.compressionMethod}")
        }
    }

    companion object {
        /**
         * The most [extract] will write for one entry: 4 GiB, the most a ZIP
         * entry without zip64 sizes can declare.
         */
        const val maximumExtractedSize: Long = 4L * 1024 * 1024 * 1024

        /**
         * Public because callers outside this module have to agree with it
         * about what a path *is* — the audio extraction names an extracted file
         * from an archive href, and a name derived from a different spelling of
         * the same path is a file neither side can find again.
         */
        fun normalize(path: String): String {
            val trimmed = if (path.startsWith("/")) path.substring(1) else path
            // Resolve any ".." / "." segments so a manifest href and a ZIP entry
            // name for the same file always agree.
            val stack = ArrayList<String>()
            for (component in trimmed.swiftSplit('/')) {
                when (component) {
                    "." -> continue
                    ".." -> if (stack.isNotEmpty()) stack.removeAt(stack.size - 1)
                    else -> stack.add(component)
                }
            }
            return stack.joinToString("/")
        }

        /**
         * The declared uncompressed size, if the entry could have it.
         *
         * [sizeOf] feeds `spineWeights`, the denominator of every progress
         * figure, straight from the central directory — before and regardless
         * of any read. A directory claiming 0xFFFFFFFE for a ten-byte member
         * made every real chapter's share round to zero and pinned the book at
         * 0% throughout, and the check that read made came too late to help.
         * So the claim is bounded here, when it is first seen: a stored entry
         * is its own size; a deflated one cannot exceed what its payload could
         * decode to ([Inflate.plausibleCeiling]), nor what [read] would ever
         * return. Past either, the size is unknown — and an entry that lies
         * about it fails its read anyway, so weighing it as nothing costs
         * nothing real.
         *
         * And never more than the archive could hold: the payload is inside the
         * file or it is nowhere. A zip64 extra field can declare any size up to
         * `Long.MAX_VALUE` for a stored member, and that claim, reported as the
         * member's size, overflowed the import's arithmetic — a trap while the
         * book was being checked, where a damaged-book message belonged.
         *
         * @param cap the most the caller would ever hold or write: [read]'s
         *   in-memory cap by default, [maximumExtractedSize] for [extract].
         */
        internal fun plausibleSize(
            declared: Long,
            compressed: Long,
            method: Int,
            archiveLength: Long,
            cap: Long = Inflate.maximumEntrySize,
        ): Long? {
            if (declared < 0 || compressed < 0 || compressed > archiveLength) return null
            if (method == 0) return if (declared == compressed && declared <= cap) declared else null
            return if (declared <= Inflate.plausibleCeiling(compressed, cap)) declared else null
        }

        private fun readCentralDirectory(data: ArchiveBytes): Map<String, Entry> {
            val eocd = findEndOfCentralDirectory(data)
                ?: throw EpubError.MalformedArchive("no end-of-central-directory record")
            var count = data.u16(eocd + 10)
            var offset = data.u32(eocd + 16)

            // Zip64: the 32-bit fields saturate, and the real values live in the
            // Zip64 EOCD record. Rare for EPUBs but cheap to support.
            if (count == 0xFFFFL || offset == 0xFFFF_FFFFL) {
                val locator = findZip64Locator(data, eocd)
                    ?: throw EpubError.MalformedArchive("zip64 locator missing")
                // A negative value is one above `Long.MAX_VALUE` — Swift's
                // `Int(exactly:)` refusing it: these eight-byte fields come
                // straight out of the file. The record guard subtracts rather
                // than adds for the same reason — `zip64 + 56` wraps on a value
                // near `Long.MAX_VALUE`.
                //
                // `PK\x06\x06`, the zip64 end-of-central-directory signature
                // from APPNOTE 4.3.14 — not `PK\x05\x06`, which is the *regular*
                // EOCD's and is what the Swift line once held. The consequence
                // ran both ways: a genuine zip64 EPUB threw "bad zip64 record"
                // and was permanently unopenable, since the download is cached;
                // and the guard could reject nothing, since pointing the locator
                // at the regular EOCD's own offset satisfied it.
                val zip64 = data.u64(locator + 8)
                val valid = zip64 >= 0 && zip64 <= data.size - 56 && data.u32(zip64) == 0x0606_4B50L
                val zip64Count = if (valid) data.u64(zip64 + 32) else -1
                val zip64Offset = if (valid) data.u64(zip64 + 48) else -1
                if (!valid || zip64Count < 0 || zip64Offset < 0) {
                    throw EpubError.MalformedArchive("bad zip64 record")
                }
                count = zip64Count
                offset = zip64Offset
            }

            // Each central-directory entry takes at least 46 bytes, so a count or
            // offset the file cannot possibly hold is malformed, not merely large
            // — and bounding them here keeps the map's sizing and the cursor
            // arithmetic below out of reach of a hostile zip64 record.
            if (offset < 0 || offset > data.size || count < 0 || count > data.size / 46) {
                throw EpubError.MalformedArchive("central directory out of bounds")
            }

            val result = LinkedHashMap<String, Entry>(count.toInt().coerceAtMost(1 shl 16))
            var cursor = offset

            repeat(count.toInt()) {
                if (cursor + 46 > data.size || data.u32(cursor) != 0x0201_4B50L) {
                    throw EpubError.MalformedArchive("bad central directory entry")
                }
                val method = data.u16(cursor + 10).toInt()
                var compressed = data.u32(cursor + 20)
                var uncompressed = data.u32(cursor + 24)
                val nameLength = data.u16(cursor + 28)
                val extraLength = data.u16(cursor + 30)
                val commentLength = data.u16(cursor + 32)
                var localOffset = data.u32(cursor + 42)

                val nameStart = cursor + 46
                if (nameStart + nameLength > data.size) throw EpubError.MalformedArchive("truncated entry name")
                val name = String(data.copy(nameStart, nameLength.toInt()), Charsets.UTF_8)

                if (compressed == 0xFFFF_FFFFL || uncompressed == 0xFFFF_FFFFL || localOffset == 0xFFFF_FFFFL) {
                    val extra = readZip64Extra(
                        data, start = nameStart + nameLength, length = extraLength,
                        uncompressed = uncompressed, compressed = compressed, localOffset = localOffset,
                    )
                    uncompressed = extra[0]
                    compressed = extra[1]
                    localOffset = extra[2]
                }

                // First record wins, not the last.
                //
                // `normalize` resolves `.` and `..` and strips a leading slash,
                // so `META-INF/container.xml`, `./META-INF/container.xml` and
                // `x/../META-INF/container.xml` are one key — and plain
                // assignment let the *last* central-directory record replace
                // every earlier one. `unzip`, epubcheck and any server-side
                // scanner take the first, so an archive whose first
                // container.xml is benign and whose trailing duplicate points at
                // a different OPF looked clean to every one of them and loaded
                // the second here. The same trick shadowed any spine document or
                // encryption.xml.
                //
                // The cursor advances on *both* paths. The first Swift version of
                // this guard was a bare `continue` above the advance at the
                // bottom of the loop, so the one archive it was written for — a
                // duplicate record — stalled the cursor on that record, re-read
                // the same 46 bytes for every remaining iteration, and returned
                // a directory missing everything after the duplicate. The book
                // became permanently unopenable, and the download is cached.
                cursor = nameStart + nameLength + extraLength + commentLength
                val key = normalize(name)
                if (!result.containsKey(key)) {
                    result[key] = Entry(
                        path = name,
                        compressionMethod = method,
                        compressedSize = compressed,
                        uncompressedSize = uncompressed,
                        knownSize = plausibleSize(
                            declared = uncompressed, compressed = compressed, method = method,
                            archiveLength = data.size,
                        ),
                        localHeaderOffset = localOffset,
                    )
                }
            }
            return result
        }

        /** The three values, with any the zip64 extra field carries in place of a saturated one. */
        private fun readZip64Extra(
            data: ArchiveBytes,
            start: Long,
            length: Long,
            uncompressed: Long,
            compressed: Long,
            localOffset: Long,
        ): LongArray {
            val values = longArrayOf(uncompressed, compressed, localOffset)
            var cursor = start
            // Bounded by the extra field's own declared end as well as the file:
            // bounding by the file alone let a 0x0001 field shorter than the
            // values it claims read on into the next central-directory record
            // and adopt its bytes as an entry's size or offset.
            val end = minOf(start + length, data.size)
            while (cursor + 4 <= end) {
                val headerId = data.u16(cursor)
                val size = data.u16(cursor + 2)
                var field = cursor + 4
                if (headerId == 0x0001L) {
                    val fieldEnd = minOf(field + size, end)
                    // Refused when negative, matching the zip64 EOCD fields: a
                    // value above `Long.MAX_VALUE` is no size or offset.
                    fun read64(at: Long): Long {
                        val value = data.u64(at)
                        if (at + 8 > fieldEnd || value < 0) {
                            throw EpubError.MalformedArchive("zip64 extra field out of range")
                        }
                        return value
                    }
                    if (values[0] == 0xFFFF_FFFFL) {
                        values[0] = read64(field)
                        field += 8
                    }
                    if (values[1] == 0xFFFF_FFFFL) {
                        values[1] = read64(field)
                        field += 8
                    }
                    if (values[2] == 0xFFFF_FFFFL) values[2] = read64(field)
                    return values
                }
                cursor += 4 + size
            }
            return values
        }

        private fun findEndOfCentralDirectory(data: ArchiveBytes): Long? {
            // Scan backwards over the maximum comment length rather than the whole file.
            val minimum = maxOf(0, data.size - 0xFFFF - 22)
            var i = data.size - 22
            while (i >= minimum) {
                if (data.u32(i) == 0x0605_4B50L) return i
                i -= 1
            }
            return null
        }

        private fun findZip64Locator(data: ArchiveBytes, eocd: Long): Long? {
            val candidate = eocd - 20
            if (candidate < 0 || data.u32(candidate) != 0x0706_4B50L) return null
            return candidate
        }
    }
}

/**
 * Why an archive or package could not be read: Swift's `EPUBError`.
 *
 * Equal by case and message, as the Swift enum is, so a test can say which
 * error it expects.
 */
sealed class EpubError(message: String) : Exception(message) {
    data class MalformedArchive(val reason: String) : EpubError(reason)
    data class MissingResource(val path: String) : EpubError("missing resource $path")
    data class MalformedPackage(val reason: String) : EpubError(reason)
    data class Unsupported(val reason: String) : EpubError(reason)
}
