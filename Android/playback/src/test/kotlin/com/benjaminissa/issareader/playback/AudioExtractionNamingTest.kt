package com.benjaminissa.issareader.playback

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

// Ported from `PlaybackTests.swift` (`AudioExtractionNamingTests`).

/** Extracted audio keeps two same-named tracks apart. */
class AudioExtractionNamingTest {
    /**
     * A CLI-aligned readaloud lays audio out per chapter. The last path
     * component mapped every one of these onto a single `track.mp3`: the first
     * was written, the existence check skipped the rest, and each chapter was
     * then pointed at the first one's bytes — so chapter one narrated over
     * chapter twelve's text for the whole book, with no error anywhere.
     */
    @Test
    fun basenamesDoNotCollide() {
        assertNotEquals(
            AudioExtraction.filename("Audio/ch01/track.mp3"),
            AudioExtraction.filename("Audio/ch02/track.mp3"),
        )
    }

    /**
     * The href is normalised first, so two spellings of one path do not
     * produce two files that neither side can find again.
     */
    @Test
    fun spellingsAgree() {
        assertEquals(AudioExtraction.filename("./Audio/ch01/track.mp3"), AudioExtraction.filename("Audio/ch01/track.mp3"))
    }

    /** The name is a single path component. */
    @Test
    fun staysOneComponent() {
        val name = AudioExtraction.filename("Audio/ch01/track.mp3")
        assertFalse(name.contains("/"))
        assertFalse(name.contains(".."))
    }

    /** A component longer than the filesystem allows would fail the write. */
    @Test
    fun longHrefsAreHashed() {
        val long = "Audio/" + "deep/".repeat(60) + "track.mp3"
        val name = AudioExtraction.filename(long)
        assertTrue(name.toByteArray().size <= 255)
        assertTrue(name.endsWith(".mp3"))
        assertEquals("and stable, so it is found again", AudioExtraction.filename(long), name)
        // The exact name the Swift client writes. Files with these names are on
        // devices already, and a hash that moves re-extracts every narration in
        // the library while the old files sit beside the new ones for good.
        assertEquals("audio-3067f05050aa961d.mp3", name)
    }

    /**
     * The same file spelled the way a producer writes it.
     *
     * Hashing the *spelling* rather than the normalised path would give this
     * href a second file, and neither the writer nor the timeline asking for it
     * would agree on which. The flattened form is only the sanity check on
     * length; the normalised one is the identity.
     */
    @Test
    fun longHrefsAreNormalisedBeforeHashing() {
        val written = "./Audio/" + "deep/".repeat(60) + "x/../track.mp3"
        val name = AudioExtraction.filename(written)
        assertEquals("audio-3067f05050aa961d.mp3", name)
        assertEquals(AudioExtraction.filename("Audio/" + "deep/".repeat(60) + "track.mp3"), name)
    }
}
