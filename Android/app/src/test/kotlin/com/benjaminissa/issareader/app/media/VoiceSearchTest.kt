package com.benjaminissa.issareader.app.media

import android.os.Bundle
import android.provider.MediaStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Which book a spoken request means. Android Auto's rules ask for voice
 * search, which CarPlay never had, so there is no Swift suite: these are the
 * requests a driver makes.
 */
@RunWith(RobolectricTestRunner::class)
class VoiceSearchTest {
    private val dracula = book("Dracula", author = "Bram Stoker", narrator = "Alan Cumming")
    private val frankenstein = book("Frankenstein", author = "Mary Shelley", narrator = "Dan Stevens")
    private val dune = book("Dune", author = "Frank Herbert", series = "Dune Chronicles", narrator = "Scott Brick")
    private val messiah = book("Dune Messiah", author = "Frank Herbert", series = "Dune Chronicles", narrator = "Scott Brick")
    private val miserables = book("Les Misérables", author = "Victor Hugo")
    private val library = listOf(dracula, frankenstein, dune, messiah, miserables)

    private fun best(query: String) = VoiceSearch.rank(library, query).firstOrNull()?.title

    @Test
    fun aTitle() {
        assertEquals("Dracula", best("Dracula"))
        assertEquals("Dracula", best("play Dracula"))
        assertEquals("Dracula", best("dracula"))
    }

    /** The words a request wraps a title in do not stop it matching. */
    @Test
    fun aTitleInASentence() {
        assertEquals("Dracula", best("Dracula by Bram Stoker"))
        assertEquals("Dracula", best("the Dracula audiobook"))
        assertEquals("Frankenstein", best("listen to Frankenstein"))
    }

    /** A title said in full beats a longer one that merely starts with it. */
    @Test
    fun theWholeTitleWins() {
        assertEquals("Dune", best("Dune"))
        assertEquals("Dune Messiah", best("Dune Messiah"))
    }

    /** An author, a narrator, a series. */
    @Test
    fun otherFields() {
        assertEquals("Frankenstein", best("Mary Shelley"))
        assertEquals("Dracula", best("Alan Cumming"))
        val herbert = VoiceSearch.rank(library, "Frank Herbert").map { it.title }
        assertEquals(setOf("Dune", "Dune Messiah"), herbert.toSet())
        assertEquals(setOf("Dune", "Dune Messiah"), VoiceSearch.rank(library, "Dune Chronicles").map { it.title }.toSet())
    }

    /** Spoken words are whole words: "Frank" is not the start of *Frankenstein*. A typed last word may be a beginning. */
    @Test
    fun wholeWords() {
        assertFalse(VoiceSearch.rank(library, "Frank Herbert").any { it.title == "Frankenstein" })
        assertEquals("Dracula", best("drac"))
        assertTrue(VoiceSearch.rank(library, "dr").isEmpty())
    }

    /** Accents are folded, as the library's own search folds them. */
    @Test
    fun accents() {
        assertEquals("Les Misérables", best("les miserables"))
    }

    /** Nothing that names nothing: the caller resumes the most recent book instead. */
    @Test
    fun anEmptyQueryNamesNothing() {
        assertTrue(VoiceSearch.rank(library, "").isEmpty())
        assertTrue(VoiceSearch.namesNothing(""))
        assertTrue(VoiceSearch.namesNothing("play an audiobook"))
        assertFalse(VoiceSearch.namesNothing("play Dracula"))
    }

    /** A query matching nothing finds nothing, rather than the first book. */
    @Test
    fun noMatch() {
        assertTrue(VoiceSearch.rank(library, "Moby Dick").isEmpty())
    }

    /** The assistant's structured hints rank as the spoken words would. */
    @Test
    fun theAssistantsHints() {
        val extras = Bundle().apply {
            putString(MediaStore.EXTRA_MEDIA_TITLE, "Frankenstein")
            putString(MediaStore.EXTRA_MEDIA_ARTIST, "Mary Shelley")
        }
        val query = VoiceSearch.query("", extras)
        assertEquals("Frankenstein", VoiceSearch.rank(library, query).first().title)
        // A hint already in the query is not repeated.
        assertEquals("Frankenstein Mary Shelley", VoiceSearch.query("Frankenstein", extras))
    }
}
