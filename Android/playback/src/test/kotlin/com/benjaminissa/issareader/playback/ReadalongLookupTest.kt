package com.benjaminissa.issareader.playback

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

// Ported from `PlaybackTests.swift` (`ReadalongLookupTests`).

class ReadalongLookupTest {
    private val track1 = "OEBPS/Audio/track1.mp3"

    /** Maps a position inside a track to the right sentence. */
    @Test
    fun perFileLookup() {
        val (timeline, _) = readalongTimeline()

        // Clip times restart at zero in every track, so this lookup must be
        // scoped to the file. A book-time search here lands on the wrong
        // sentence entirely.
        val opening = checkNotNull(timeline.entryInFile(track1, 1.0))
        assertEquals("ch01-s0", opening.fragmentId)

        val second = checkNotNull(timeline.entryInFile(track1, 6.0))
        assertEquals("ch01-s1", second.fragmentId)
    }

    /** The same offset in a different track resolves to a different chapter. */
    @Test
    fun trackScoping() {
        val (timeline, _) = readalongTimeline()
        val first = checkNotNull(timeline.entryInFile("OEBPS/Audio/track1.mp3", 1.0))
        val second = checkNotNull(timeline.entryInFile("OEBPS/Audio/track2.mp3", 1.0))
        assertEquals("ch01-s0", first.fragmentId)
        assertEquals("ch02-s0", second.fragmentId)
        assertNotEquals(first.textHref, second.textHref)
    }

    /** A boundary belongs to the entry that starts there. */
    @Test
    fun boundaries() {
        val (timeline, _) = readalongTimeline()
        val atBoundary = checkNotNull(timeline.entryInFile(track1, 4.250))
        assertEquals("ch01-s1", atBoundary.fragmentId)
        val justBefore = checkNotNull(timeline.entryInFile(track1, 4.249))
        assertEquals("ch01-s0", justBefore.fragmentId)
    }

    /** A time past the last clip stays on the final sentence. */
    @Test
    fun pastEnd() {
        val (timeline, _) = readalongTimeline()
        val entry = checkNotNull(timeline.entryInFile("OEBPS/Audio/track1.mp3", 9_999.0))
        assertEquals("ch01-s5", entry.fragmentId)
    }

    /** Steps forward and back through sentences, across chapters. */
    @Test
    fun sentenceStepping() {
        val (timeline, _) = readalongTimeline()
        val last = timeline.entriesInDocument("OEBPS/ch01.xhtml").last()
        // Stepping past the end of a chapter continues into the next one.
        val next = checkNotNull(timeline.entryAfter(last))
        assertEquals("OEBPS/ch02.xhtml", next.textHref)
        val back = checkNotNull(timeline.entryBefore(next))
        assertEquals(last.fragmentId, back.fragmentId)
    }

    /** Extracts the embedded audio the aligner packs into the EPUB. */
    @Test
    fun extractsAudio() {
        val (timeline, epubPackage) = readalongTimeline()
        val directory = scratchDirectory("issa-audio-test")
        try {
            val files = AudioExtraction.extractAudio(epubPackage, timeline, "test", directory)
            // Narration lives inside the EPUB, so one download yields text and audio.
            assertEquals(2, files.size)
            for ((href, file) in files) {
                assertTrue("missing extraction for $href", file.exists())
                assertTrue(file.readBytes().isNotEmpty())
            }
        } finally {
            directory.deleteRecursively()
        }
    }
}
