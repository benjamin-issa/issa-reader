package com.benjaminissa.issareader.core.sync

import com.benjaminissa.issareader.core.bookJson
import com.benjaminissa.issareader.core.decodeBook
import com.benjaminissa.issareader.core.model.Book
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What a car is offered. Ported from `CarPlayCatalogueTests.swift`; the Swift
 * `CarPlayCatalogue` is [CarCatalogue] here, since Android Auto reads it.
 *
 * Every rule here is one that is wrong in a way you would only discover while
 * driving, which is the whole reason it lives in core rather than in the car
 * service.
 */
class CarCatalogueTest {
    fun book(
        title: String,
        author: String = "Someone",
        progress: Double? = null,
        positionTimestamp: Double? = null,
        audioDuration: Double? = null,
        narrated: Boolean = false,
        ebookOnly: Boolean = false,
        audioMissing: Boolean = false,
    ): Book {
        val json = bookJson(uuid = title, title = title)
        json["authors"] = listOf(mapOf("uuid" to author, "name" to author, "fileAs" to author))
        if (progress != null) {
            json["position"] = mapOf(
                "locator" to mapOf("href" to "a", "type" to "t", "locations" to mapOf("totalProgression" to progress)),
                "timestamp" to (positionTimestamp ?: 0.0),
            )
        }
        if (ebookOnly) {
            json["ebook"] = mapOf("uuid" to "e", "filepath" to "book.epub", "identifiers" to emptyList<Any>())
        } else if (narrated) {
            val readaloud = mutableMapOf<String, Any?>("uuid" to "r", "filepath" to "r.epub", "identifiers" to emptyList<Any>())
            if (audioDuration != null) readaloud["duration"] = audioDuration
            if (audioMissing) readaloud["missing"] = true
            json["readaloud"] = readaloud
        } else {
            val audiobook = mutableMapOf<String, Any?>("uuid" to "a", "filepath" to "a.m4b", "identifiers" to emptyList<Any>())
            if (audioDuration != null) audiobook["duration"] = audioDuration
            if (audioMissing) audiobook["missing"] = true
            json["audiobook"] = audiobook
        }
        return decodeBook(json)
    }

    companion object {
        const val PLENTY = 100
    }

    // What may be offered at all

    /** A book with no audio is never listed: offering one is offering a button that does nothing. */
    @Test
    fun textOnlyBooksAreExcluded() {
        val catalogue = CarCatalogue(books = listOf(book("Silent", ebookOnly = true), book("Spoken")))
        val titles = catalogue.entries(CarCatalogue.Shelf.LIBRARY, limit = PLENTY).map { it.title }
        assertEquals(listOf("Spoken"), titles)
    }

    /**
     * A format the server cannot actually serve is not offered either: the
     * server creates a readaloud row when alignment is merely requested.
     */
    @Test
    fun missingAudioIsExcluded() {
        val catalogue = CarCatalogue(books = listOf(book("Requested", narrated = true, audioMissing = true), book("Aligned", narrated = true)))
        val titles = catalogue.entries(CarCatalogue.Shelf.LIBRARY, limit = PLENTY).map { it.title }
        assertEquals(listOf("Aligned"), titles)
    }

    // The head unit's limits

    /** A long list is cut to what the head unit will draw. */
    @Test
    fun respectsTheLimit() {
        val books = (1..40).map { book("Book $it") }
        val catalogue = CarCatalogue(books = books)
        assertEquals(12, catalogue.entries(CarCatalogue.Shelf.LIBRARY, limit = 12).size)
        // The head unit enforces its maximum rather than advising it.
        assertEquals("Book 1", catalogue.entries(CarCatalogue.Shelf.LIBRARY, limit = 12).first().title)
    }

    /** A nonsensical limit yields nothing rather than trapping. */
    @Test
    fun nonPositiveLimit() {
        val catalogue = CarCatalogue(books = listOf(book("One")))
        assertTrue(catalogue.entries(CarCatalogue.Shelf.LIBRARY, limit = 0).isEmpty())
        assertTrue(catalogue.entries(CarCatalogue.Shelf.LIBRARY, limit = -3).isEmpty())
    }

    // Order

    /** Recent is what was most recently in progress, newest first. */
    @Test
    fun recentOrdersByPositionTimestamp() {
        val catalogue = CarCatalogue(
            books = listOf(
                book("Older", progress = 0.4, positionTimestamp = 100.0),
                book("Newest", progress = 0.2, positionTimestamp = 900.0),
                book("Untouched"),
            ),
        )
        assertEquals(listOf("Newest", "Older"), catalogue.entries(CarCatalogue.Shelf.RECENT, limit = PLENTY).map { it.title })
    }

    /** Downloaded holds only what will play with no signal. */
    @Test
    fun downloadedShelf() {
        val catalogue = CarCatalogue(
            books = listOf(
                book("OnDevice", progress = 0.5, positionTimestamp = 10.0),
                book("Streamed", progress = 0.5, positionTimestamp = 20.0),
            ),
            downloadedUuids = setOf("OnDevice"),
        )
        val entries = catalogue.entries(CarCatalogue.Shelf.DOWNLOADED, limit = PLENTY)
        assertEquals(listOf("OnDevice"), entries.map { it.title })
        assertEquals(true, entries.firstOrNull()?.isDownloaded)
    }

    /**
     * A download never opened still shows on the Downloaded shelf. The shelf
     * once used `continueReading`, which drops any book without progress.
     */
    @Test
    fun downloadedShelfIncludesUnstartedBooks() {
        val catalogue = CarCatalogue(
            books = listOf(
                book("FreshDownload"),
                book("HalfDone", progress = 0.5, positionTimestamp = 10.0),
                book("Streamed", progress = 0.5, positionTimestamp = 20.0),
            ),
            downloadedUuids = setOf("FreshDownload", "HalfDone"),
        )
        val titles = catalogue.entries(CarCatalogue.Shelf.DOWNLOADED, limit = PLENTY).map { it.title }
        // In progress first, most recent on top; unstarted downloads follow.
        assertEquals(listOf("HalfDone", "FreshDownload"), titles)
    }

    /** A download does not jump the queue on the other shelves. */
    @Test
    fun downloadsDoNotReorderRecent() {
        val catalogue = CarCatalogue(
            books = listOf(
                book("Streamed", progress = 0.5, positionTimestamp = 900.0),
                book("OnDevice", progress = 0.5, positionTimestamp = 100.0),
            ),
            downloadedUuids = setOf("OnDevice"),
        )
        assertEquals(listOf("Streamed", "OnDevice"), catalogue.entries(CarCatalogue.Shelf.RECENT, limit = PLENTY).map { it.title })
    }

    // What a row says

    /** A row says who wrote it and how much is left. */
    @Test
    fun subtitleIsGlanceable() {
        val catalogue = CarCatalogue(books = listOf(book("Novel", author = "Halloway", progress = 0.5, audioDuration = 7200.0)))
        assertEquals("Halloway · 1h 0m left", catalogue.entries(CarCatalogue.Shelf.LIBRARY, limit = PLENTY).firstOrNull()?.subtitle)
    }

    /** A book never started says its whole length. */
    @Test
    fun subtitleWithoutProgress() {
        val catalogue = CarCatalogue(books = listOf(book("Novel", author = "Halloway", audioDuration = 5400.0)))
        assertEquals("Halloway · 1h 30m left", catalogue.entries(CarCatalogue.Shelf.LIBRARY, limit = PLENTY).firstOrNull()?.subtitle)
    }

    /** A book with no known duration still says who wrote it. */
    @Test
    fun subtitleWithoutDuration() {
        val catalogue = CarCatalogue(books = listOf(book("Novel", author = "Halloway")))
        assertEquals("Halloway", catalogue.entries(CarCatalogue.Shelf.LIBRARY, limit = PLENTY).firstOrNull()?.subtitle)
    }

    /** A finished book does not report a negative remainder. */
    @Test
    fun finishedBookRemainder() {
        val catalogue = CarCatalogue(books = listOf(book("Done", author = "A", progress = 1.0, positionTimestamp = 1.0, audioDuration = 3600.0)))
        assertEquals("A · 0m left", catalogue.entries(CarCatalogue.Shelf.RECENT, limit = PLENTY).firstOrNull()?.subtitle)
    }

    /** Durations read the way a driver would say them. */
    @Test
    fun durationText() {
        val cases = listOf(0.0 to "0m", 59.0 to "0m", 90.0 to "1m", 3600.0 to "1h 0m", 5430.0 to "1h 30m", 98_100.0 to "27h 15m")
        for ((seconds, expected) in cases) {
            assertEquals("$seconds", expected, CarCatalogue.durationText(seconds))
        }
    }

    /** A nonsense duration does not become a nonsense label. */
    @Test
    fun durationTextGuards() {
        assertEquals("0m", CarCatalogue.durationText(Double.NaN))
        assertEquals("0m", CarCatalogue.durationText(-100.0))
        assertEquals("0m", CarCatalogue.durationText(Double.POSITIVE_INFINITY))
    }

    // Empty

    /** Every shelf has something to say when it is empty: a blank list in a car looks like a crash. */
    @Test
    fun emptyMessages() {
        for (shelf in CarCatalogue.Shelf.entries) {
            assertFalse("$shelf", shelf.emptyMessage.isEmpty())
            assertFalse("$shelf", shelf.title.isEmpty())
            assertTrue("$shelf", CarCatalogue(books = emptyList()).entries(shelf, limit = PLENTY).isEmpty())
        }
    }
}
