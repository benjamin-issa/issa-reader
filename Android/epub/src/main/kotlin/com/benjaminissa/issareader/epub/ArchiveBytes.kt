package com.benjaminissa.issareader.epub

import java.io.File
import java.io.RandomAccessFile
import java.nio.Buffer
import java.nio.ByteBuffer
import java.nio.channels.FileChannel

/**
 * An archive's bytes, addressed by 64-bit offset, without copying them.
 *
 * Swift's `Data(contentsOf:options: .mappedIfSafe)` maps a file whole; a JVM
 * mapping is capped at 2³¹ bytes, and a book from the reader's own files can be
 * 4 GB. So a file is mapped in segments of a gibibyte, each a read-only
 * [ByteBuffer], and an offset picks its segment. The OS pages in only the bytes
 * actually touched, which matters for a large book on a memory-tight device.
 *
 * Every read is absolute (`get(index)`) or through a `duplicate()`, so one
 * instance is safe to read from several threads, as Swift's immutable `Data`
 * is.
 */
internal class ArchiveBytes private constructor(private val segments: Array<ByteBuffer>, val size: Long) {
    fun byteAt(offset: Long): Int =
        segments[(offset ushr SEGMENT_SHIFT).toInt()].get((offset and SEGMENT_MASK).toInt()).toInt() and 0xFF

    /**
     * Little-endian words, and 0 for a word that would run past the end — the
     * same as the Swift helpers, which answer 0 rather than trap so that a
     * truncated file fails a signature check instead.
     */
    fun u16(offset: Long): Long {
        if (offset < 0 || offset > size - 2) return 0
        return byteAt(offset).toLong() or (byteAt(offset + 1).toLong() shl 8)
    }

    fun u32(offset: Long): Long {
        if (offset < 0 || offset > size - 4) return 0
        var value = 0L
        for (i in 0 until 4) value = value or (byteAt(offset + i).toLong() shl (8 * i))
        return value
    }

    /**
     * The raw 64 bits. A negative result is a value above `Long.MAX_VALUE`,
     * which every caller refuses — Swift's `Int(exactly:)` on the same field.
     */
    fun u64(offset: Long): Long {
        if (offset < 0 || offset > size - 8) return 0
        var value = 0L
        for (i in 0 until 8) value = value or (byteAt(offset + i).toLong() shl (8 * i))
        return value
    }

    /** Copies `length` bytes from `offset` into `destination`, across segments. */
    fun read(offset: Long, destination: ByteArray, at: Int, length: Int) {
        var position = offset
        var written = 0
        while (written < length) {
            val segment = segments[(position ushr SEGMENT_SHIFT).toInt()].duplicate()
            val within = (position and SEGMENT_MASK).toInt()
            val count = minOf(length - written, segment.limit() - within)
            segment.window(within, segment.limit())
            segment.get(destination, at + written, count)
            written += count
            position += count
        }
    }

    fun copy(offset: Long, length: Int): ByteArray = ByteArray(length).also { read(offset, it, 0, length) }

    /**
     * Views of `length` bytes from `offset`, at most `sliceSize` each and never
     * across a segment: slices of the mapping, not copies of it.
     */
    fun forEachSlice(offset: Long, length: Long, sliceSize: Int, action: (ByteBuffer) -> Unit) {
        var position = offset
        val end = offset + length
        while (position < end) {
            val segment = segments[(position ushr SEGMENT_SHIFT).toInt()].duplicate()
            val within = (position and SEGMENT_MASK).toInt()
            val count = minOf(end - position, sliceSize.toLong(), (segment.limit() - within).toLong()).toInt()
            action(segment.window(within, within + count))
            position += count
        }
    }

    companion object {
        private const val SEGMENT_SHIFT = 30
        private const val SEGMENT_SIZE = 1L shl SEGMENT_SHIFT
        private const val SEGMENT_MASK = SEGMENT_SIZE - 1

        /** The bytes from `buffer`'s position to its limit, which need not start at zero. */
        fun of(buffer: ByteBuffer): ArchiveBytes {
            val view = buffer.slice()
            val size = view.remaining().toLong()
            val count = ((size + SEGMENT_SIZE - 1) / SEGMENT_SIZE).toInt()
            val segments = Array(count) { index ->
                val start = (index * SEGMENT_SIZE).toInt()
                val end = minOf(size, (index + 1) * SEGMENT_SIZE).toInt()
                view.duplicate().window(start, end).slice()
            }
            return ArchiveBytes(segments, size)
        }

        /**
         * Mapped rather than read: only the pages touched are ever loaded. The
         * mapping outlives the channel, which is closed at once.
         */
        fun map(file: File): ArchiveBytes = RandomAccessFile(file, "r").use { handle ->
            val channel = handle.channel
            val size = channel.size()
            val count = ((size + SEGMENT_SIZE - 1) / SEGMENT_SIZE).toInt()
            val segments = Array<ByteBuffer>(count) { index ->
                val start = index * SEGMENT_SIZE
                channel.map(FileChannel.MapMode.READ_ONLY, start, minOf(SEGMENT_SIZE, size - start))
            }
            ArchiveBytes(segments, size)
        }
    }
}

/**
 * Sets position and limit through [Buffer], whose methods every Android
 * release has: JDK 9's covariant `ByteBuffer.position(int)` is not one Android
 * is obliged to resolve, and calling it compiles to that descriptor.
 */
internal fun ByteBuffer.window(position: Int, limit: Int): ByteBuffer {
    val buffer: Buffer = this
    buffer.position(0)
    buffer.limit(limit)
    buffer.position(position)
    return this
}

/** A run of an archive's bytes: one entry's payload, or a whole buffer handed to [Inflate]. */
internal class ByteRange(val bytes: ArchiveBytes, val start: Long, val count: Long) {
    companion object {
        fun of(data: ByteArray): ByteRange = ByteRange(ArchiveBytes.of(ByteBuffer.wrap(data)), 0, data.size.toLong())
    }
}
