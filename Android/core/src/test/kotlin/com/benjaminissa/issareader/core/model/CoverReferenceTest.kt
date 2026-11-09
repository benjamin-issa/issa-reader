package com.benjaminissa.issareader.core.model

import com.benjaminissa.issareader.core.bookJson
import com.benjaminissa.issareader.core.decodeBook
import com.benjaminissa.issareader.core.sync.LibraryService
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Choosing a book's cover reference. Ported from `CoverReferenceTests.swift`.
 *
 * `Book.coverReference(shape, fallback)` is the one place the choice is made:
 * the fetch goes by it and the cache names its file by it. A mistake here is
 * silent — the right-looking slot holds the wrong art — so the whole matrix
 * is pinned rather than the cases the route tests happen to reach.
 */
class CoverReferenceTest {
    companion object {
        val ebookArt = "a".repeat(64)
        val readaloudArt = "b".repeat(64)
        val audiobookArt = "c".repeat(64)

        /** Named, and not a hash the client will ever put in a URL. */
        const val UNUSABLE = "NOT-A-SHA"

        /**
         * Every edition present, each naming the art given and the rest `null`,
         * as a 3.x catalogue sends them.
         */
        fun book(ebook: String? = null, readaloud: String? = null, audiobook: String? = null): Book {
            fun format(name: String, cover: String?): Map<String, Any?> = mapOf(
                "uuid" to name, "filepath" to "$name.epub", "identifiers" to emptyList<Any>(),
                "cover" to cover?.let { mapOf("sha256" to it) },
            )
            val json = bookJson(uuid = "0f0e0d0c-0b0a-4908-8706-050403020100", title = "A Book")
            json["ebook"] = format("ebook", ebook)
            json["audiobook"] = format("audiobook", audiobook)
            json["readaloud"] = format("readaloud", readaloud)
            return decodeBook(json)
        }
    }

    /** The hash chosen, for readable failures. */
    private fun chosen(book: Book, shape: LibraryService.CoverShape, fallback: Boolean = false): String? =
        book.coverReference(shape, fallback)?.sha256

    /** Portrait is the ebook's art, else the read-along's; square is the audiobook's. */
    @Test
    fun eachShapeHasItsOwnOrder() {
        val every = book(ebook = ebookArt, readaloud = readaloudArt, audiobook = audiobookArt)
        assertEquals(ebookArt, chosen(every, LibraryService.CoverShape.PORTRAIT))
        assertEquals(audiobookArt, chosen(every, LibraryService.CoverShape.SQUARE))

        val readalong = book(readaloud = readaloudArt, audiobook = audiobookArt)
        assertEquals(readaloudArt, chosen(readalong, LibraryService.CoverShape.PORTRAIT))
    }

    /**
     * A portrait falls back to the square art only when asked, and only when
     * it has none. The uuid route's 404 fallback, decided from the book.
     */
    @Test
    fun portraitFallsBackOnlyWhenAsked() {
        val squareOnly = book(audiobook = audiobookArt)
        assertNull(chosen(squareOnly, LibraryService.CoverShape.PORTRAIT))
        assertEquals(audiobookArt, chosen(squareOnly, LibraryService.CoverShape.PORTRAIT, fallback = true))

        val every = book(ebook = ebookArt, readaloud = readaloudArt, audiobook = audiobookArt)
        assertEquals(ebookArt, chosen(every, LibraryService.CoverShape.PORTRAIT, fallback = true))
        val readalong = book(readaloud = readaloudArt, audiobook = audiobookArt)
        assertEquals(readaloudArt, chosen(readalong, LibraryService.CoverShape.PORTRAIT, fallback = true))
    }

    /** A square never falls back to portrait art: the uuid route never answers a square request with it. */
    @Test
    fun squareNeverFallsBack() {
        val portraitOnly = book(ebook = ebookArt, readaloud = readaloudArt)
        assertNull(chosen(portraitOnly, LibraryService.CoverShape.SQUARE))
        assertNull(chosen(portraitOnly, LibraryService.CoverShape.SQUARE, fallback = true))
    }

    /**
     * An unusable reference is skipped, never chosen: passed over, not taken
     * as the end of the search, so the next candidate still gets its turn.
     */
    @Test
    fun unusableIsSkipped() {
        val badEbook = book(ebook = UNUSABLE, readaloud = readaloudArt)
        assertEquals(readaloudArt, chosen(badEbook, LibraryService.CoverShape.PORTRAIT))

        val badPortrait = book(ebook = UNUSABLE, readaloud = UNUSABLE, audiobook = audiobookArt)
        assertNull(chosen(badPortrait, LibraryService.CoverShape.PORTRAIT))
        assertEquals(audiobookArt, chosen(badPortrait, LibraryService.CoverShape.PORTRAIT, fallback = true))

        val badSquare = book(ebook = ebookArt, audiobook = UNUSABLE)
        assertNull(chosen(badSquare, LibraryService.CoverShape.SQUARE))
        assertEquals(ebookArt, chosen(badSquare, LibraryService.CoverShape.PORTRAIT, fallback = true))

        val allBad = book(ebook = UNUSABLE, readaloud = UNUSABLE, audiobook = UNUSABLE)
        for (shape in LibraryService.CoverShape.entries) {
            for (fallback in listOf(false, true)) {
                assertNull("$shape, fallback $fallback", chosen(allBad, shape, fallback))
            }
        }
    }

    /** A book that names no art has no reference for either shape. */
    @Test
    fun noArtNoReference() {
        val none = book()
        for (shape in LibraryService.CoverShape.entries) {
            for (fallback in listOf(false, true)) {
                assertNull("$shape, fallback $fallback", chosen(none, shape, fallback))
            }
        }
    }

    /**
     * A book names a cover when any edition names usable art: what decides
     * between "no such art" and asking the uuid route.
     */
    @Test
    fun namesAnyCover() {
        assertFalse(book().namesAnyCover)
        assertTrue(book(ebook = ebookArt).namesAnyCover)
        assertTrue(book(readaloud = readaloudArt).namesAnyCover)
        assertTrue(book(audiobook = audiobookArt).namesAnyCover)
        assertTrue(book(ebook = ebookArt, readaloud = readaloudArt, audiobook = audiobookArt).namesAnyCover)
    }

    /**
     * Unusable art names no cover: an unusable hash is never fetched, so it is
     * no sign the server has spoken about the book's art.
     */
    @Test
    fun unusableNamesNoCover() {
        assertFalse(book(ebook = UNUSABLE).namesAnyCover)
        assertFalse(book(ebook = UNUSABLE, readaloud = UNUSABLE, audiobook = UNUSABLE).namesAnyCover)
        assertTrue(book(ebook = UNUSABLE, audiobook = audiobookArt).namesAnyCover)
    }
}
