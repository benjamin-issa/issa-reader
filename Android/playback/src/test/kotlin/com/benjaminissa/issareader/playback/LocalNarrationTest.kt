package com.benjaminissa.issareader.playback

import com.benjaminissa.issareader.epub.EpubInspection
import com.benjaminissa.issareader.epub.EpubPackage
import com.benjaminissa.issareader.epub.SmilParser
import com.benjaminissa.issareader.testing.Fixtures
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

// Ported from `LocalNarrationTests.swift`.
//
// Where the Swift suite asked AVFoundation, this asks a `MediaSupport` that
// answers as AVFoundation does — MP3 and AAC yes, Opus no — so the rules on top
// of the platform's answer are what is under test. What Android's codec list
// actually answers is `playback-android`'s `AndroidMediaSupportTest`, and it is
// not the same answer: Android plays Opus.

/**
 * Narration in a book from the reader's own files: whether this device can
 * play it, decided before the book is added, and where it is extracted to and
 * removed from.
 */
class LocalNarrationTest {
    /** The platform as iOS answers it. */
    private val avFoundation = object : MediaSupport {
        override fun isPlayable(mimeType: String): Boolean = mimeType in setOf("audio/mpeg", "audio/mp4")

        override fun mimeType(extension: String): String? = mapOf("mp3" to "audio/mpeg", "m4a" to "audio/mp4", "opus" to "audio/opus")[extension]
    }

    private val asked = ArrayList<String>()
    private val recording = object : MediaSupport {
        override fun isPlayable(mimeType: String): Boolean {
            asked.add(mimeType)
            return avFoundation.isPlayable(mimeType)
        }

        override fun mimeType(extension: String): String? = avFoundation.mimeType(extension)
    }

    /** IssaPlayback's own fixtures hold the two read-alongs; the generated local-import books live with IssaEPUB's. */
    private fun book(name: String): File =
        if (name.startsWith("readalong") && name != "readalong-opus") Fixtures.playback("$name.epub") else Fixtures.epub("$name.epub")

    /** The platform's answer decides, by media type and then by extension. */
    @Test
    fun playability() {
        assertTrue(AudioPlayability.isPlayable("audio/mpeg", "a.mp3", recording))
        assertTrue(AudioPlayability.isPlayable("audio/mp4", "a.m4a", recording))
        assertFalse(AudioPlayability.isPlayable("audio/opus", "a.opus", recording))
        // No media type: the extension stands in for one.
        assertTrue(AudioPlayability.isPlayable(null, "OEBPS/Audio/a.mp3", recording))
        assertFalse(AudioPlayability.isPlayable("", "OEBPS/Audio/a", recording))
        assertEquals("the declared type is what is asked about", listOf("audio/mpeg", "audio/mp4", "audio/opus", "audio/mpeg"), asked)
    }

    /** A read-along with MP3 narration can be narrated. */
    @Test
    fun mp3Narrates() {
        assertTrue(AudioPlayability.canNarrate(EpubInspection.inspect(book("readalong")), avFoundation))
    }

    /** A read-along with Opus narration cannot, and is added as text. */
    @Test
    fun opusDoesNot() {
        val inspection = EpubInspection.inspect(book("readalong-opus"))
        assertTrue("the narration is there; only the format is wrong", inspection.hasCompleteNarration)
        assertFalse(AudioPlayability.canNarrate(inspection, avFoundation))
    }

    /** A book with no narration has none to play. */
    @Test
    fun noNarration() {
        assertFalse(AudioPlayability.canNarrate(EpubInspection.inspect(book("epub2-meta-cover")), avFoundation))
    }

    /**
     * The book's own folder, under the lock an extraction into it holds:
     * removing the book while its narration is still being written must not
     * leave a torn folder, nor be undone by the extraction finishing.
     */
    @Test
    fun removesFromTheBooksFolder() {
        val epubPackage = EpubPackage.open(book("readalong"))
        val timeline = SmilParser.timeline(epubPackage)
        val parent = scratchDirectory("issa-local-narration")
        val folder = File(parent, "Audio")
        try {
            val files = AudioExtraction.extractAudio(epubPackage, timeline, "ignored-for-an-explicit-folder", folder)
            assertTrue(files.values.all { it.path.startsWith(folder.path) })
            assertEquals(2, files.size)

            AudioExtraction.removeExtractedAudio(folder)
            assertFalse(folder.exists())
        } finally {
            parent.deleteRecursively()
        }
    }
}
