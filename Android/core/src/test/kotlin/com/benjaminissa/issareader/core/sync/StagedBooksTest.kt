package com.benjaminissa.issareader.core.sync

import com.benjaminissa.issareader.core.bookJson
import com.benjaminissa.issareader.core.decodeBook
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.Status
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A page of books grouped by reading stage: what the tag page and the "More
 * by" page say and in what order. Ported from `StagedBooksTests.swift`.
 */
class StagedBooksTest {
    private fun book(
        title: String,
        status: String? = null,
        progress: Double? = null,
        timestamp: Double = 0.0,
        readaloud: Boolean = false,
        audiobook: Boolean = false,
        series: Pair<String, Double?>? = null,
        published: String? = null,
    ): Book {
        val json = bookJson(uuid = title, title = title)
        json["series"] = series?.let { (name, position) ->
            val row = mutableMapOf<String, Any?>("uuid" to name, "name" to name)
            if (position != null) row["position"] = position
            listOf(row)
        } ?: emptyList<Any>()
        json["ebook"] = mapOf("uuid" to "e", "identifiers" to emptyList<Any>())
        if (status != null) json["status"] = mapOf("uuid" to status, "name" to status)
        if (progress != null) {
            json["position"] = mapOf(
                "locator" to mapOf("href" to "a", "type" to "t", "locations" to mapOf("totalProgression" to progress)),
                "timestamp" to timestamp,
            )
        }
        if (readaloud) json["readaloud"] = mapOf("uuid" to "r", "filepath" to "r.epub", "identifiers" to emptyList<Any>())
        if (audiobook) json["audiobook"] = mapOf("uuid" to "a", "filepath" to "a.m4b", "identifiers" to emptyList<Any>())
        if (published != null) json["publicationDate"] = published
        return decodeBook(json)
    }

    /** Sections run Reading, To read, Read — in progress first — whatever order the books came in. */
    @Test
    fun sectionOrder() {
        val staged = StagedBooks(
            books = listOf(book("Done", status = "Read"), book("Queued", status = "To read"), book("Open", status = "Reading", progress = 0.2)),
            statuses = emptyList(),
        )
        assertEquals(
            listOf(LibraryArrangement.Stage.READING, LibraryArrangement.Stage.TO_READ, LibraryArrangement.Stage.FINISHED),
            staged.sections.map { it.stage },
        )
        assertEquals(listOf("Reading", "To read", "Read"), staged.sections.map { it.title })
    }

    /** A section is named with the server's label, so a renamed status reads renamed. */
    @Test
    fun renamedStatus() {
        val statuses = listOf(
            Status(uuid = "1", name = "To read"),
            Status(uuid = "2", name = "Reading"),
            Status(uuid = "3", name = "Read", label = "Finished"),
        )
        val staged = StagedBooks(books = listOf(book("Done", status = "Read"), book("Queued", status = "To read")), statuses = statuses)
        assertEquals(listOf("To read", "Finished"), staged.sections.map { it.title })
        assertEquals("Finished · 1", staged.sections.last().overline)
        assertEquals("Finished, 1 book", staged.sections.last().spokenOverline)
    }

    /** Before the server's statuses load, a section takes its name from its books' own status. */
    @Test
    fun titleFromTheBooks() {
        val staged = StagedBooks(books = listOf(book("Done", status = "Finished"), book("Open", progress = 0.2)), statuses = emptyList())
        // "Finished" is the books' word for the stage; the book with no status
        // carries none, so its section falls back to the built-in name.
        assertEquals(listOf("Reading", "Finished"), staged.sections.map { it.title })
    }

    /** Reading is most recently opened first; the rest are A–Z without their articles. */
    @Test
    fun orderWithinSections() {
        val staged = StagedBooks(
            books = listOf(
                book("Older", status = "Reading", progress = 0.5, timestamp = 1.0),
                book("Never opened", status = "Reading"),
                book("Newer", status = "Reading", progress = 0.1, timestamp = 9.0),
                book("The Woman in White", status = "To read"),
                book("Carmilla", status = "To read"),
                book("A Beetle", status = "To read"),
            ),
            statuses = emptyList(),
        )
        assertEquals(listOf("Newer", "Older", "Never opened"), staged.sections[0].books.map { it.title })
        assertEquals(listOf("A Beetle", "Carmilla", "The Woman in White"), staged.sections[1].books.map { it.title })
    }

    /** A book with no status is filed where the shelves file it. */
    @Test
    fun nullStatus() {
        val staged = StagedBooks(books = listOf(book("Started", progress = 0.3), book("Untouched")), statuses = emptyList())
        assertEquals(listOf(LibraryArrangement.Stage.READING, LibraryArrangement.Stage.TO_READ), staged.sections.map { it.stage })
    }

    /** The summary drops a clause with nothing to count. */
    @Test
    fun summary() {
        val many = StagedBooks(
            books = listOf(
                book("A", status = "Reading", progress = 0.1, readaloud = true),
                book("B", status = "To read", audiobook = true),
                book("C", status = "Read"),
            ),
            statuses = emptyList(),
        )
        assertEquals("3 books · 1 in progress · 2 with narration", many.summary)
        assertEquals("Gothic, tag. 3 books, 1 in progress, 2 with narration.", many.spokenHeader(name = "Gothic", kind = "tag"))

        val quiet = StagedBooks(books = listOf(book("A", status = "Read"), book("B", status = "Read")), statuses = emptyList())
        assertEquals("2 books", quiet.summary)
    }

    /**
     * R-79. The header counts narration, and files books, exactly as the
     * library's shelves do: the library's own predicate and stages, not copies.
     */
    @Test
    fun sameRulesAsTheShelves() {
        val books = listOf(
            book("A", status = "Reading", progress = 0.1, readaloud = true),
            book("B", status = "To read", audiobook = true),
            book("C", progress = 0.99),
            book("D"),
        )
        val staged = StagedBooks(books = books, statuses = emptyList())
        val facets = LibraryFacets(books = books, downloadedUuids = emptySet())

        assertEquals(facets.count(LibraryArrangement.Shelf.WITH_NARRATION), staged.withNarration)
        for (section in staged.sections) {
            for (book in section.books) {
                assertEquals(book.title, section.stage, LibraryArrangement.stage(book))
            }
        }
    }

    /** One book is only "1 book", with no overline and no Show in Library. */
    @Test
    fun oneBook() {
        val one = StagedBooks(books = listOf(book("A", status = "Reading", progress = 0.4, readaloud = true)), statuses = emptyList())
        assertEquals("1 book", one.summary)
        assertFalse(one.showsOverlines)
        assertFalse(one.offersShowInLibrary)
    }

    /** Every book in one stage draws no overline; two stages draw both. */
    @Test
    fun overlines() {
        assertFalse(StagedBooks(books = listOf(book("A", status = "Read"), book("B", status = "Read")), statuses = emptyList()).showsOverlines)
        assertTrue(StagedBooks(books = listOf(book("A", status = "Read"), book("B", status = "To read")), statuses = emptyList()).showsOverlines)
    }

    /** A book handed over twice is counted and drawn once. */
    @Test
    fun deduplicated() {
        val twice = book("A", status = "Read")
        val staged = StagedBooks(books = listOf(twice, twice, book("B", status = "Read")), statuses = emptyList())
        assertEquals(2, staged.count)
        assertEquals(2, staged.sections.first().books.size)
    }

    /** An empty page is empty. */
    @Test
    fun empty() {
        val staged = StagedBooks(books = emptyList(), statuses = emptyList())
        assertTrue(staged.isEmpty)
        assertTrue(staged.sections.isEmpty())
    }

    /** The author page's caption is the series and its number, else the series, else the year. */
    @Test
    fun authorCaption() {
        assertEquals("In a Glass Darkly · 5", StagedBooks.authorCaption(book("A", series = "In a Glass Darkly" to 5.0)))
        assertEquals("Shelf", StagedBooks.authorCaption(book("A", series = "Shelf" to null)))
        assertEquals("1864", StagedBooks.authorCaption(book("A", published = "1864-01-01T00:00:00.000Z")))
        assertNull(StagedBooks.authorCaption(book("A")))
    }

    /** A tag needs two books to be a place to go. */
    @Test
    fun minimumBooksPerTag() {
        assertEquals(2, LibraryRails.minimumBooksPerTag)
    }
}
