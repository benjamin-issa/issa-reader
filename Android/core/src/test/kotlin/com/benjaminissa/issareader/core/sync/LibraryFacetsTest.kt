package com.benjaminissa.issareader.core.sync

import com.benjaminissa.issareader.core.bookJson
import com.benjaminissa.issareader.core.decodeBook
import com.benjaminissa.issareader.core.model.Book
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Counting the shelves: the numbers on the shelf chips. Ported from
 * `LibraryFacetsTests.swift`.
 *
 * A count that disagrees with the grid beneath it reads as a bug in the
 * library, not in the chip — so each of these pins a count to the same
 * predicate the filter uses.
 */
class LibraryFacetsTest {
    private fun book(
        title: String,
        status: String? = null,
        tags: List<String> = emptyList(),
        readaloud: Boolean = false,
        audiobook: Boolean = false,
    ): Book {
        val json = bookJson(uuid = title, title = title)
        json["tags"] = tags.map { mapOf("uuid" to it, "name" to it) }
        if (status != null) json["status"] = mapOf("uuid" to status, "name" to status)
        if (readaloud) json["readaloud"] = mapOf("uuid" to "r", "filepath" to "r.epub", "identifiers" to emptyList<Any>())
        if (audiobook) json["audiobook"] = mapOf("uuid" to "a", "filepath" to "a.m4b", "identifiers" to emptyList<Any>())
        return decodeBook(json)
    }

    /** The three reading stages account for every book, exactly once. */
    @Test
    fun stagesPartitionTheLibrary() {
        val books = listOf(
            book("A", status = "Reading"),
            book("B", status = "To read"),
            book("C", status = "Read"),
            book("D"), // no status at all
            book("E", status = "Abandoned"), // an admin's own
        )
        val facets = LibraryFacets(books = books, downloadedUuids = emptySet())

        assertEquals(5, facets.total)
        assertEquals(5, facets.count(LibraryArrangement.Shelf.ALL))
        assertEquals(
            5,
            facets.count(LibraryArrangement.Shelf.READING) + facets.count(LibraryArrangement.Shelf.TO_READ) +
                facets.count(LibraryArrangement.Shelf.FINISHED),
        )
    }

    /**
     * A book with no status is counted where the filter puts it: the count
     * has to agree with the filter, or the chip says 3 and the grid shows 5.
     */
    @Test
    fun unknownStatusCountsAsToRead() {
        val books = listOf(book("D"), book("E", status = "Reference"), book("A", status = "Reading"))
        val facets = LibraryFacets(books = books, downloadedUuids = emptySet())

        assertEquals(2, facets.count(LibraryArrangement.Shelf.TO_READ))
        val filtered = LibraryArrangement(shelf = LibraryArrangement.Shelf.TO_READ).apply(books)
        assertEquals(facets.count(LibraryArrangement.Shelf.TO_READ), filtered.size)
    }

    /** The audio shelf counts a readalong and an audiobook, but not a bare ebook. */
    @Test
    fun audioShelfCountsBothKinds() {
        val books = listOf(
            book("Readalong", readaloud = true),
            book("Audiobook", audiobook = true),
            book("Both", readaloud = true, audiobook = true),
            book("Plain ebook"),
        )
        val facets = LibraryFacets(books = books, downloadedUuids = emptySet())

        assertEquals(3, facets.count(LibraryArrangement.Shelf.WITH_NARRATION))
        assertEquals(
            LibraryArrangement(shelf = LibraryArrangement.Shelf.WITH_NARRATION).apply(books).size,
            facets.count(LibraryArrangement.Shelf.WITH_NARRATION),
        )
    }

    /**
     * The audio shelf counts only audio the server can serve. A row is not a
     * file: the server keeps an audiobook row with no file behind it, or
     * marks a file missing.
     */
    @Test
    fun audioShelfCountsOnlyServableAudio() {
        val books = UnservableAudio.books()
        val facets = LibraryFacets(books = books, downloadedUuids = emptySet())

        assertEquals("only the book with a file to play", 1, facets.count(LibraryArrangement.Shelf.WITH_NARRATION))
        assertEquals(
            LibraryArrangement(shelf = LibraryArrangement.Shelf.WITH_NARRATION).apply(books).size,
            facets.count(LibraryArrangement.Shelf.WITH_NARRATION),
        )
    }

    /** The downloaded count comes from the injected set, and touches no disk. */
    @Test
    fun downloadedComesFromTheInjectedSet() {
        val books = listOf(book("One"), book("Two"), book("Three"))
        val facets = LibraryFacets(books = books, downloadedUuids = setOf("One", "Three"))
        assertEquals(2, facets.count(LibraryArrangement.Shelf.DOWNLOADED))
    }

    /** Tags are ordered by how many books carry them, then by name. */
    @Test
    fun tagsSortByCountThenName() {
        val books = listOf(
            book("A", tags = listOf("Fiction", "Zebra")),
            book("B", tags = listOf("Fiction", "Apple")),
            book("C", tags = listOf("Fiction")),
        )
        val facets = LibraryFacets(books = books, downloadedUuids = emptySet())

        assertEquals(listOf("Fiction", "Apple", "Zebra"), facets.tagCounts.map { it.name })
        assertEquals(3, facets.tagCounts.first().count)
    }

    /** An empty library counts zero rather than being absent. */
    @Test
    fun emptyLibraryIsAllZeroes() {
        assertEquals(0, LibraryFacets.empty.total)
        for (shelf in LibraryArrangement.Shelf.entries) {
            assertEquals(0, LibraryFacets.empty.count(shelf))
        }
    }
}

/**
 * Series in reading order: the sub-series rail on the book screen promises
 * reading order, which has to mean order within *that* series. Ported from
 * `SeriesDerivationTests` in `LibraryFacetsTests.swift`.
 */
class SeriesDerivationTest {
    private fun book(title: String, series: List<Pair<String, Double>>): Book {
        val json = bookJson(uuid = title, title = title)
        json["series"] = series.map { (name, position) -> mapOf("uuid" to name, "name" to name, "position" to position) }
        return decodeBook(json)
    }

    /**
     * A book in two series is ordered by its place in the one being shown.
     * The comparator once read the first series' position, so a book in two
     * series was ordered inside every group by whichever happened to be first.
     */
    @Test
    fun multiSeriesBookUsesTheRightOrdinal() {
        val x = book("X", series = listOf("Discworld" to 5.0, "Death" to 1.0))
        val y = book("Y", series = listOf("Death" to 2.0))
        val z = book("Z", series = listOf("Discworld" to 2.0))
        val derivation = LibraryDerivation(books = listOf(y, x, z))

        assertEquals(listOf("X", "Y"), derivation.bySeries["Death"]?.map { it.title })
        assertEquals(listOf("Z", "X"), derivation.bySeries["Discworld"]?.map { it.title })
    }
}

/**
 * Books whose audio row has nothing the server can serve, beside one that
 * has. Shared by the facet, rail and shelf tests, which have to agree.
 */
object UnservableAudio {
    /** The one book of these that belongs on "With audio". */
    const val playable = "Playable"

    fun books(): List<Book> {
        val rows: List<Pair<String, Map<String, Any?>>> = listOf(
            playable to mapOf("audiobook" to mapOf("uuid" to "a1", "filepath" to "a.m4b", "missing" to false, "identifiers" to emptyList<Any>())),
            // A row the server made with no file behind it.
            "No file" to mapOf("audiobook" to mapOf("uuid" to "a2", "filepath" to null, "identifiers" to emptyList<Any>())),
            // A file the server has lost.
            "Lost audiobook" to mapOf("audiobook" to mapOf("uuid" to "a3", "filepath" to "a.m4b", "missing" to true, "identifiers" to emptyList<Any>())),
            "Lost read-along" to mapOf("readaloud" to mapOf("uuid" to "r4", "filepath" to "r.epub", "missing" to true, "identifiers" to emptyList<Any>())),
            "Text only" to mapOf("ebook" to mapOf("uuid" to "e5", "filepath" to "e.epub", "identifiers" to emptyList<Any>())),
        )
        return rows.map { (title, extra) ->
            val json = bookJson(uuid = title, title = title)
            json.putAll(extra)
            decodeBook(json)
        }
    }
}
