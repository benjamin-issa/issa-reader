package com.benjaminissa.issareader.core.sync

import com.benjaminissa.issareader.core.bookJson
import com.benjaminissa.issareader.core.decodeBook
import com.benjaminissa.issareader.core.fixtureBooks
import com.benjaminissa.issareader.core.model.Book
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Shelving a book with no status. Ported from `NullStatusStageTests.swift`.
 *
 * 2.x never sent one: it gives every book a status row for every reader. 3.x
 * sends them and never moves them, so a book read to the end elsewhere would
 * sit on "To read" for good. The shelf files it where the server's own rule
 * would once a position exists, by the server's own thresholds.
 */
class NullStatusStageTest {
    private fun book(title: String, status: String? = null, label: String? = null, progress: Double? = null): Book {
        val json = bookJson(uuid = title, title = title)
        json["status"] = status?.let {
            val row = mutableMapOf<String, Any?>("uuid" to it, "name" to it)
            if (label != null) row["label"] = label
            row
        }
        if (progress != null) {
            json["position"] = mapOf(
                "locator" to mapOf("href" to "a", "type" to "t", "locations" to mapOf("totalProgression" to progress)),
                "timestamp" to 0,
            )
        }
        return decodeBook(json)
    }

    private fun stage(book: Book) = LibraryArrangement.stage(book)

    /**
     * No status and no position is unstarted; a position at zero is not. The
     * server's rule moves a book off "To read" on any position write, 0%
     * included, and so does the write `StatusAdvance` makes here.
     */
    @Test
    fun noProgress() {
        assertEquals(LibraryArrangement.Stage.TO_READ, stage(book("Unopened")))
        assertEquals(LibraryArrangement.Stage.READING, stage(book("At zero", progress = 0.0)))
    }

    /** No status with some progress is being read. */
    @Test
    fun someProgress() {
        assertEquals(LibraryArrangement.Stage.READING, stage(book("Begun", progress = 0.001)))
        assertEquals(LibraryArrangement.Stage.READING, stage(book("Midway", progress = 0.3)))
        assertEquals(LibraryArrangement.Stage.READING, stage(book("Nearly", progress = 0.979)))
    }

    /** No status at 98% or more is finished. */
    @Test
    fun finished() {
        assertEquals(LibraryArrangement.Stage.FINISHED, stage(book("Threshold", progress = 0.98)))
        assertEquals(LibraryArrangement.Stage.FINISHED, stage(book("Done", progress = 1.0)))
    }

    /**
     * A named status is unaffected by progress: a shelf that overrode it
     * would move a book the reader put back on "To read".
     */
    @Test
    fun namedStatusWins() {
        assertEquals(LibraryArrangement.Stage.TO_READ, stage(book("Reread", status = "To read", progress = 0.99)))
        assertEquals(LibraryArrangement.Stage.READING, stage(book("Started", status = "Reading", progress = 0.0)))
        assertEquals(LibraryArrangement.Stage.FINISHED, stage(book("Early", status = "Read", progress = 0.1)))
        assertEquals(LibraryArrangement.Stage.TO_READ, stage(book("Gave up", status = "Abandoned", progress = 0.99)))
    }

    /** A relabelled status is shelved by its name, not its label. */
    @Test
    fun labelIsNotTheKey() {
        val relabelled = book("Relabelled", status = "Read", label = "Shelved for good", progress = 0.1)
        assertEquals(LibraryArrangement.Stage.FINISHED, stage(relabelled))
    }

    /** The captured 3.x books with no status land where 2.x would have filed them. */
    @Test
    fun capturedLibrary() {
        val books = fixtureBooks("v3/books")
        val timeMachine = books.first { it.title == "The Time Machine" }
        val emma = books.first { it.title == "Emma" }
        assertEquals(LibraryArrangement.Stage.READING, stage(timeMachine))
        assertEquals(LibraryArrangement.Stage.TO_READ, stage(emma))

        // The filter, the chips and the rails all read `stage(book)`, so they
        // agree about it too.
        val reading = LibraryArrangement(shelf = LibraryArrangement.Shelf.READING).apply(books)
        assertTrue(reading.any { it.uuid == timeMachine.uuid })
        val facets = LibraryFacets(books = books, downloadedUuids = emptySet())
        assertEquals(reading.size, facets.count(LibraryArrangement.Shelf.READING))
    }
}
