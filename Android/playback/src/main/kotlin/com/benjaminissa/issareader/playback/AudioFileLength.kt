package com.benjaminissa.issareader.playback

import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.StandardOpenOption

/**
 * Measures one audio file's true length. Blocking: [ChunkDurations.measure]
 * calls it off the main thread, a few files at a time.
 *
 * An interface because the answer is the platform's to give for most formats.
 * On iOS it is `AVURLAsset` with precise timing; on Android it is
 * [AudioFileLength] for the formats it reads exactly and the platform's
 * extractor for the rest (`playback-android`'s `AndroidDurationMeasurer`).
 */
fun interface DurationMeasurer {
    /** Seconds, or null when the file cannot be measured. */
    fun duration(file: File): Double?
}

/**
 * The exact length of an MPEG audio or RIFF WAVE file, read from its own
 * structure.
 *
 * A measurement, not a division sum. Asked for a duration without being told
 * to be precise, a player answers for a constant-bitrate MP3 with no length in
 * its header by dividing the file's size by its bitrate. The error is small
 * per file and always in the same direction, so across a hundred and
 * seventy-six chunks it sums into a book clock that disagrees with the audio by
 * a visible amount — which is the one thing [ChunkDurations] exists to prevent,
 * and the estimate it was written to replace. iOS asks AVFoundation for precise
 * timing (`AVURLAssetPreferPreciseDurationAndTimingKey`), which walks the
 * file's frames; Android's extractors offer no such switch, so the walk is done
 * here, the same way: every MPEG frame header is read and its samples counted.
 * A WAVE file's length is its data chunk over its byte rate, which is exact by
 * construction.
 *
 * A metadata frame (Xing, Info or VBRI) carries no audio and is not counted.
 * Anything this cannot read is null, and the caller asks the platform instead.
 */
object AudioFileLength : DurationMeasurer {
    override fun duration(file: File): Double? = try {
        FileChannel.open(file.toPath(), StandardOpenOption.READ).use { channel ->
            val input = Window(channel)
            if (input.length < 12) return@use null
            val seconds = if (input.ascii(0, 4) == "RIFF" && input.ascii(8, 4) == "WAVE") wave(input) else mpeg(input)
            seconds?.takeIf { it.isFinite() && it > 0 }
        }
    } catch (_: IOException) {
        null
    }

    // MPEG audio

    private val bitratesV1 = arrayOf(
        intArrayOf(0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448),
        intArrayOf(0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384),
        intArrayOf(0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320),
    )
    private val bitratesV2 = arrayOf(
        intArrayOf(0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256),
        intArrayOf(0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160),
        intArrayOf(0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160),
    )
    private val sampleRatesV1 = intArrayOf(44_100, 48_000, 32_000)

    /** One MPEG audio frame header, decoded. */
    private class Frame(val length: Int, val samples: Int, val sampleRate: Int, val sideInfo: Int)

    private fun frame(header: Int): Frame? {
        if ((header ushr 21) and 0x7FF != 0x7FF) return null
        val version = (header ushr 19) and 3 // 3: MPEG-1, 2: MPEG-2, 0: MPEG-2.5
        val layer = (header ushr 17) and 3 // 3: Layer I, 2: Layer II, 1: Layer III
        val bitrateIndex = (header ushr 12) and 0xF
        val rateIndex = (header ushr 10) and 3
        if (version == 1 || layer == 0 || bitrateIndex == 0 || bitrateIndex == 15 || rateIndex == 3) return null
        val padding = (header ushr 9) and 1
        val mono = (header ushr 6) and 3 == 3
        val mpeg1 = version == 3
        val sampleRate = sampleRatesV1[rateIndex] / (if (mpeg1) 1 else if (version == 2) 2 else 4)
        val layerIndex = 3 - layer // 0: I, 1: II, 2: III
        val bitrate = 1000 * (if (mpeg1) bitratesV1 else bitratesV2)[layerIndex][bitrateIndex]
        val samples = when {
            layerIndex == 0 -> 384
            layerIndex == 1 || mpeg1 -> 1152
            else -> 576
        }
        val length = when (layerIndex) {
            0 -> (12 * bitrate / sampleRate + padding) * 4
            else -> samples / 8 * bitrate / sampleRate + padding
        }
        val sideInfo = when {
            mpeg1 -> if (mono) 17 else 32
            else -> if (mono) 9 else 17
        }
        return Frame(length, samples, sampleRate, sideInfo)
    }

    private fun mpeg(input: Window): Double? {
        val length = input.length
        var position = id3v2Length(input)
        var seconds = 0.0
        var counted = 0
        // Whether the walk is in step: at the start of the audio, or straight
        // after a frame it accepted. A header found by scanning past bytes that
        // are not one has to be confirmed by the frame after it, or a stray
        // `0xFFE` in a tag would count as audio.
        var inStep = true
        while (position + 4 <= length) {
            val found = frame(input.int(position))
            if (found == null || found.length < 4 || position + found.length > length) {
                inStep = false
                position += 1
                continue
            }
            if (!inStep && !confirmed(input, position + found.length)) {
                position += 1
                continue
            }
            val isMetadata = counted == 0 && isMetadataFrame(input, position, found)
            if (!isMetadata) seconds += found.samples.toDouble() / found.sampleRate
            counted += 1
            position += found.length
            inStep = true
        }
        return if (seconds > 0) seconds else null
    }

    /** Whether a frame header starts at [position], or the file ends exactly there. */
    private fun confirmed(input: Window, position: Long): Boolean {
        if (position == input.length) return true
        if (position + 4 > input.length) return false
        return frame(input.int(position)) != null
    }

    /** The first frame of a VBR or LAME-tagged file holds the tag, not audio. */
    private fun isMetadataFrame(input: Window, position: Long, frame: Frame): Boolean {
        val xing = 4 + frame.sideInfo
        if (xing + 4 <= frame.length) {
            val tag = input.ascii(position + xing, 4)
            if (tag == "Xing" || tag == "Info") return true
        }
        return 36 + 4 <= frame.length && input.ascii(position + 36, 4) == "VBRI"
    }

    /** How many bytes of ID3v2 tag the file opens with. */
    private fun id3v2Length(input: Window): Long {
        if (input.ascii(0, 3) != "ID3") return 0
        val size = ((input.byte(6) and 0x7F) shl 21) or ((input.byte(7) and 0x7F) shl 14) or
            ((input.byte(8) and 0x7F) shl 7) or (input.byte(9) and 0x7F)
        val footer = if (input.byte(5) and 0x10 != 0) 10 else 0
        return 10L + size + footer
    }

    // RIFF WAVE

    private fun wave(input: Window): Double? {
        val length = input.length
        var position = 12L
        var byteRate = 0L
        while (position + 8 <= length) {
            val id = input.ascii(position, 4)
            val size = input.uint32LittleEndian(position + 4)
            when (id) {
                "fmt " -> if (position + 16 + 4 <= length) byteRate = input.uint32LittleEndian(position + 16)
                "data" -> {
                    if (byteRate <= 0) return null
                    // A streaming writer leaves the size unset; the data then
                    // runs to the end of the file.
                    val available = length - (position + 8)
                    val bytes = if (size == 0xFFFF_FFFFL || size > available) available else size
                    return bytes.toDouble() / byteRate
                }
            }
            position += 8 + size + (size and 1)
        }
        return null
    }

    /**
     * Random access through a window of the file, refilled as the walk moves,
     * so a long file costs neither a read per frame nor its size in memory.
     */
    private class Window(private val channel: FileChannel) {
        val length: Long = channel.size()
        private val buffer: ByteBuffer = ByteBuffer.allocate(64 * 1024)
        private var start = -1L
        private var count = 0

        fun byte(position: Long): Int {
            if (position < start || position >= start + count) fill(position)
            return buffer.get((position - start).toInt()).toInt() and 0xFF
        }

        private fun fill(position: Long) {
            buffer.clear()
            start = position
            count = 0
            while (buffer.hasRemaining()) {
                val read = channel.read(buffer, position + count)
                if (read <= 0) break
                count += read
            }
            if (count == 0) throw IOException("read past the end of the file")
        }

        /** Big-endian, as an MPEG header is. */
        fun int(position: Long): Int =
            (byte(position) shl 24) or (byte(position + 1) shl 16) or (byte(position + 2) shl 8) or byte(position + 3)

        fun uint32LittleEndian(position: Long): Long =
            (byte(position).toLong()) or (byte(position + 1).toLong() shl 8) or
                (byte(position + 2).toLong() shl 16) or (byte(position + 3).toLong() shl 24)

        fun ascii(position: Long, count: Int): String {
            if (position + count > length) return ""
            val characters = CharArray(count) { byte(position + it).toChar() }
            return String(characters)
        }
    }
}
