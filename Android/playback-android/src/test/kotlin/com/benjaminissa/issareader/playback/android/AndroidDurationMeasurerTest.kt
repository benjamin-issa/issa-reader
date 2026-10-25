package com.benjaminissa.issareader.playback.android

import com.benjaminissa.issareader.epub.EpubPackage
import com.benjaminissa.issareader.epub.SmilParser
import com.benjaminissa.issareader.playback.AudioExtraction
import com.benjaminissa.issareader.playback.ChunkDurations
import com.benjaminissa.issareader.testing.Fixtures
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.File
import java.nio.file.Files

// The Android half of `ChunkDurationsTests.swift`'s measurement: what the
// measurer the app hands `ChunkDurations.measure` answers for the files a
// read-along extracts, and for the ones it cannot read.

@RunWith(RobolectricTestRunner::class)
class AndroidDurationMeasurerTest {
    private lateinit var directory: File
    private val measurer = AndroidDurationMeasurer()

    @Before
    fun setUp() {
        directory = Files.createTempDirectory("issa-measure").toFile()
    }

    @After
    fun tearDown() {
        directory.deleteRecursively()
    }

    /**
     * The fixture's chunks, measured by their frames: one frame each, exactly,
     * where the platform's extractor would have divided size by bitrate.
     */
    @Test
    fun theFixturesChunksAreOneFrameEach() = runBlocking {
        val epubPackage = EpubPackage.open(Fixtures.playback("readalong.epub"))
        val timeline = SmilParser.timeline(epubPackage)
        val files = AudioExtraction.extractAudio(epubPackage, timeline, "android-measure", directory)

        val measured = ChunkDurations.measure(files, emptyMap(), measurer)
        assertFalse(measured.isEmpty())
        assertEquals(files.keys, measured.keys)
        for ((href, length) in measured) assertEquals(href, 1152.0 / 44_100.0, length, 1e-9)
    }

    /** A longer MP3, still to the sample. */
    @Test
    fun anMp3IsCountedToTheFrame() {
        val file = silentMp3(File(directory, "chunk.mp3"), frames = 383)
        assertEquals(mp3Seconds(383), checkNotNull(measurer.duration(file)), 1e-9)
    }

    /** A WAVE file is its data over its byte rate. */
    @Test
    fun aWaveIsItsData() {
        val file = wav(File(directory, "chunk.wav"), seconds = 2.5)
        assertEquals(2.5, checkNotNull(measurer.duration(file)), 1e-9)
    }

    /** Nothing anyone can read is no length, not zero: the clock estimates instead. */
    @Test
    fun anUnreadableFileHasNoLength() {
        val file = File(directory, "noise.m4a").apply { writeBytes(ByteArray(4_096) { (it * 31).toByte() }) }
        assertNull(measurer.duration(file))
        assertNull(measurer.duration(File(directory, "missing.mp3")))
    }
}
