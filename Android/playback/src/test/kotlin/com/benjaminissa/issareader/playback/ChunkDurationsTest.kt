package com.benjaminissa.issareader.playback

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs

// Ported from `ChunkDurationsTests.swift`. Where the Swift suite measured
// through AVFoundation with precise timing, this measures through
// `AudioFileLength`, the frame walk Android's measurer uses for MPEG audio.

/**
 * Measured chunk lengths, and where they are kept.
 *
 * The book clock a position is written against is the sum of these, so a stale
 * one is a position that resolves to the wrong place in the book. Keeping them
 * beside the extracted audio is what makes staleness impossible: the files and
 * the numbers describing them are deleted by one call.
 */
class ChunkDurationsTest {
    /**
     * A temporary `Audio` root. Never the real one — the removal deletes a
     * directory whole. `AudioExtraction.defaultDirectory` documents the same
     * reason for taking a root at all.
     */
    private fun root(): File = scratchDirectory("issa-durations")

    /** Durations round-trip, and go when the audio they describe goes. */
    @Test
    fun durationsRoundTripBesideTheExtractedAudio() = runTest {
        val root = root()
        try {
            val measured = mapOf("OEBPS/Audio/track1.mp3" to 23.4, "OEBPS/Audio/track2.mp3" to 9.87)

            // The extraction makes the folder; the cache only ever writes into it.
            assertTrue(AudioExtraction.defaultDirectory("book", root).mkdirs())
            ChunkDurations.save(measured, "book", root)
            assertEquals(measured, ChunkDurations.load("book", root))

            // Inside the directory the extraction writes to, not merely near it.
            val cache = ChunkDurations.cacheFile("book", root)
            assertEquals(
                AudioExtraction.defaultDirectory("book", root).absoluteFile.normalize(),
                cache.parentFile.absoluteFile.normalize(),
            )

            AudioExtraction.removeExtractedAudio("book", root)
            assertFalse(cache.exists())
            assertTrue("lengths must not outlive the files they describe", ChunkDurations.load("book", root).isEmpty())
        } finally {
            root.deleteRecursively()
        }
    }

    /** Measuring skips what is already cached, and measures the rest. */
    @Test
    fun measureSkipsWhatIsCachedAndMeasuresTheFixture() = runTest {
        val (timeline, epubPackage) = readalongTimeline()
        val directory = root()
        try {
            val files = AudioExtraction.extractAudio(epubPackage, timeline, "measure", directory)

            // A deliberately wrong cached value for one of them: if it were
            // remeasured the number would change, and reopening every chunk on
            // every play is the cost this type exists to avoid.
            val merged = ChunkDurations.measure(files, mapOf("OEBPS/Audio/track1.mp3" to 1.0), AudioFileLength)

            assertEquals("a cached length is not measured again", 1.0, checkNotNull(merged["OEBPS/Audio/track1.mp3"]), 0.0)
            val second = checkNotNull(merged["OEBPS/Audio/track2.mp3"])
            assertTrue("the unmeasured one was measured: $second", second.isFinite() && second > 0)
            assertEquals(2, merged.size)
        } finally {
            directory.deleteRecursively()
        }
    }

    /**
     * The measurement is the audio's own length, not a division sum.
     *
     * Asked for a duration without being told to be precise, a player may
     * answer for an MP3 by dividing the file's size by its declared bitrate. The
     * fixture's chunks are a single MPEG frame apiece — 1152 samples at 44.1kHz,
     * 26 milliseconds — inside a 2052-byte file, and that quotient comes back
     * several times the audio that is there.
     *
     * Several times is this fixture being small, and a real chunk's error is
     * fractions of a second. The direction is what matters. Every chunk is wrong
     * the same way, the errors sum rather than cancel, and the sum is the book
     * clock a listening position is written against — so over a hundred and
     * seventy-six chunks the phone and the server come to disagree about where in
     * the book a reader is by minutes.
     */
    @Test
    fun aChunkIsMeasuredByItsFramesRatherThanItsBitrate() = runTest {
        val (timeline, epubPackage) = readalongTimeline()
        val directory = root()
        try {
            val files = AudioExtraction.extractAudio(epubPackage, timeline, "precise", directory)

            val measured = ChunkDurations.measure(files, emptyMap(), AudioFileLength)
            assertFalse(measured.isEmpty())

            // One frame, exactly. Sample-accurate, so this is an equality with
            // only enough slack for the division that turns samples into seconds.
            val oneFrame = 1152.0 / 44100.0
            for ((href, length) in measured) {
                assertTrue("$href measured ${length}s, and one frame is ${oneFrame}s", abs(length - oneFrame) < 0.001)
            }
        } finally {
            directory.deleteRecursively()
        }
    }

    // Android's own: the rest of what `AudioFileLength` reads, and refuses.

    /** A WAVE file's length is its data over its byte rate, exactly. */
    @Test
    fun aWaveIsMeasuredByItsData() {
        val file = File.createTempFile("issa-length", ".wav")
        try {
            val sampleRate = 2_000
            val seconds = 3
            val samples = sampleRate * seconds
            val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
            header.put("RIFF".toByteArray()).putInt(36 + samples).put("WAVE".toByteArray())
            header.put("fmt ".toByteArray()).putInt(16).putShort(1).putShort(1)
                .putInt(sampleRate).putInt(sampleRate).putShort(1).putShort(8)
            header.put("data".toByteArray()).putInt(samples)
            file.writeBytes(header.array() + ByteArray(samples) { 0x80.toByte() })

            assertEquals(3.0, checkNotNull(AudioFileLength.duration(file)), 1e-9)
        } finally {
            file.delete()
        }
    }

    /** Nothing it can read is no length at all, and the platform is asked instead. */
    @Test
    fun anythingElseIsNoLength() {
        val file = File.createTempFile("issa-length", ".bin")
        try {
            file.writeBytes(ByteArray(4_096))
            assertNull(AudioFileLength.duration(file))
            assertNull(AudioFileLength.duration(File(file.path + ".missing")))
        } finally {
            file.delete()
        }
    }
}
