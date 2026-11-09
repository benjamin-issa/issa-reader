package com.benjaminissa.issareader.core.sync

import com.benjaminissa.issareader.core.InMemoryKeyValueStore
import com.benjaminissa.issareader.core.IssaJson
import com.benjaminissa.issareader.core.bookJson
import com.benjaminissa.issareader.core.decodeBook
import com.benjaminissa.issareader.core.model.Book
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Arranging the library. Ported from `LibraryArrangementTests.swift`.
 *
 * The Swift suite stores arrangements in a fresh `UserDefaults` suite per
 * test; here each test gets a fresh [InMemoryKeyValueStore], the interface the
 * app backs with its own preferences.
 */
class LibraryArrangementTest {
    /**
     * Built by decoding, the same way a real book arrives: inventing an
     * initialiser purely for tests would be a second definition of a book.
     */
    fun book(
        title: String,
        author: String = "Someone",
        status: String? = null,
        progress: Double? = null,
        tags: List<String> = emptyList(),
        duration: Double? = null,
        positionTimestamp: Double? = null,
        createdAt: String? = null,
        narrator: String? = null,
        series: List<Pair<String, Double?>> = emptyList(),
    ): Book {
        val json = bookJson(uuid = title, title = title)
        json["authors"] = listOf(mapOf("uuid" to author, "name" to author, "fileAs" to author))
        json["narrators"] = narrator?.let { listOf(mapOf("uuid" to it, "name" to it, "fileAs" to it)) } ?: emptyList<Any>()
        json["series"] = series.map { (name, position) ->
            val row = mutableMapOf<String, Any?>("uuid" to name, "name" to name)
            if (position != null) row["position"] = position
            row
        }
        json["tags"] = tags.map { mapOf("uuid" to it, "name" to it) }
        if (status != null) json["status"] = mapOf("uuid" to status, "name" to status)
        if (progress != null) {
            json["position"] = mapOf(
                "locator" to mapOf("href" to "a", "type" to "t", "locations" to mapOf("totalProgression" to progress)),
                "timestamp" to (positionTimestamp ?: 0.0),
            )
        }
        if (duration != null) json["audiobook"] = mapOf("uuid" to "a", "duration" to duration, "identifiers" to emptyList<Any>())
        if (createdAt != null) json["createdAt"] = createdAt
        return decodeBook(json)
    }

    private fun decode(json: String): LibraryArrangement = IssaJson.decodeFromString(LibraryArrangement.serializer(), json)

    private fun titles(arrangement: LibraryArrangement, books: List<Book>): List<String> =
        arrangement.apply(books).map { it.title }

    /** Titles sort past their leading article, the way a librarian files them. */
    @Test
    fun titleSort() {
        val books = listOf(book("The Time Machine"), book("Alice"), book("A Study in Scarlet"))
        assertEquals(listOf("Alice", "A Study in Scarlet", "The Time Machine"), titles(LibraryArrangement(sort = LibraryArrangement.Sort.TITLE), books))
    }

    /** Unread books sort to the end of recently read. */
    @Test
    fun recentSort() {
        val books = listOf(
            book("Never opened"),
            book("Read yesterday", progress = 0.4, positionTimestamp = 1_000.0),
            book("Read today", progress = 0.2, positionTimestamp = 2_000.0),
        )
        assertEquals(listOf("Read today", "Read yesterday", "Never opened"), titles(LibraryArrangement(sort = LibraryArrangement.Sort.RECENT), books))
    }

    /**
     * Shelves match renamed statuses: status names belong to the server, so
     * the shelves match loosely rather than against a fixed vocabulary.
     */
    @Test
    fun shelves() {
        val books = listOf(
            book("One", status = "Currently Reading"),
            book("Two", status = "To Read"),
            book("Three", status = "Read"),
            book("Four"),
        )
        assertEquals(listOf("One"), titles(LibraryArrangement(shelf = LibraryArrangement.Shelf.READING), books))
        assertEquals(listOf("Three"), titles(LibraryArrangement(shelf = LibraryArrangement.Shelf.FINISHED), books))
        // A book with no status at all has not been started, so it belongs on
        // the "to read" shelf beside the ones explicitly marked.
        assertEquals(setOf("Two", "Four"), titles(LibraryArrangement(shelf = LibraryArrangement.Shelf.TO_READ), books).toSet())
    }

    /**
     * A custom status is not mistaken for one of the three: "Abandoned"
     * contains "done", so a substring test filed it under Finished.
     */
    @Test
    fun customStatusIsNotMisfiled() {
        val books = listOf(book("Gave up", status = "Abandoned"), book("Looked up", status = "Reference"))
        assertTrue(LibraryArrangement(shelf = LibraryArrangement.Shelf.FINISHED).apply(books).isEmpty())
        assertEquals(2, LibraryArrangement(shelf = LibraryArrangement.Shelf.TO_READ).apply(books).size)
    }

    /** Tags narrow rather than widen: a reader who chose two means both. */
    @Test
    fun tagFilter() {
        val books = listOf(
            book("Both", tags = listOf("Fiction", "Fantasy")),
            book("One", tags = listOf("Fiction")),
            book("Neither", tags = listOf("History")),
        )
        val arrangement = LibraryArrangement(tags = setOf("Fiction", "Fantasy"))
        assertEquals(listOf("Both"), titles(arrangement, books))
        assertTrue(arrangement.isFiltering)
        assertFalse(LibraryArrangement().isFiltering)
    }

    /** The audio shelf holds only audio the server can serve. */
    @Test
    fun audioShelfHoldsOnlyServableAudio() {
        val books = UnservableAudio.books()
        val shelf = titles(LibraryArrangement(sort = LibraryArrangement.Sort.TITLE, shelf = LibraryArrangement.Shelf.WITH_NARRATION), books)
        assertEquals(listOf(UnservableAudio.playable), shelf)
    }

    /** The downloaded shelf asks the app, which is the only thing that knows. */
    @Test
    fun downloadedShelf() {
        val books = listOf(book("On disk"), book("Not on disk"))
        val shelf = LibraryArrangement(shelf = LibraryArrangement.Shelf.DOWNLOADED)
        val result = shelf.apply(books) { it.title == "On disk" }
        assertEquals(listOf("On disk"), result.map { it.title })
    }

    /** An unknown sort costs the sort, not the whole arrangement. */
    @Test
    fun unknownSortKeepsEverythingElse() {
        val restored = decode("""{"sort":"chronological","ascending":true,"shelf":"reading","tags":["Fiction"]}""")

        assertEquals(LibraryArrangement.Sort.ADDED, restored.sort) // fell back
        assertEquals(LibraryArrangement.Shelf.READING, restored.shelf) // survived
        assertEquals(setOf("Fiction"), restored.tags) // survived
        assertEquals(true, restored.ascending) // survived
    }

    /** An unknown shelf costs the shelf, not the sort. */
    @Test
    fun unknownShelfKeepsEverythingElse() {
        val restored = decode("""{"sort":"title","shelf":"borrowed","tags":[]}""")

        assertEquals(LibraryArrangement.Shelf.ALL, restored.shelf) // fell back
        assertEquals(LibraryArrangement.Sort.TITLE, restored.sort) // survived
    }

    /** A field an older blob never had takes its default, alone. */
    @Test
    fun missingFieldTakesItsDefault() {
        val restored = decode("""{"shelf":"finished"}""")

        assertEquals(LibraryArrangement.Shelf.FINISHED, restored.shelf)
        assertEquals(LibraryArrangement().sort, restored.sort)
        assertTrue(restored.tags.isEmpty())
    }

    /**
     * A stored recently-read sort becomes recently-added, once. The default
     * was "Recently read" for every build before the Reading tab existed, so a
     * stored one is almost always the old default rather than a choice.
     */
    @Test
    fun recentIsMigratedOnce() {
        val suite = InMemoryKeyValueStore()
        LibraryArrangement(sort = LibraryArrangement.Sort.RECENT, shelf = LibraryArrangement.Shelf.READING, tags = setOf("Fantasy")).store(suite)

        val migrated = LibraryArrangement.restored(suite)
        assertEquals(LibraryArrangement.Sort.ADDED, migrated.sort)
        assertEquals(LibraryArrangement.Shelf.READING, migrated.shelf) // only the sort moved
        assertEquals(setOf("Fantasy"), migrated.tags)

        // Now a deliberate choice, made after the migration ran.
        LibraryArrangement(sort = LibraryArrangement.Sort.RECENT).store(suite)
        assertEquals(LibraryArrangement.Sort.RECENT, LibraryArrangement.restored(suite).sort)
    }

    /** A choice made on a fresh install is not mistaken for the old default. */
    @Test
    fun freshInstallKeepsALaterChoice() {
        val suite = InMemoryKeyValueStore()

        assertEquals(LibraryArrangement.Sort.ADDED, LibraryArrangement.restored(suite).sort)
        LibraryArrangement(sort = LibraryArrangement.Sort.RECENT).store(suite)
        assertEquals(LibraryArrangement.Sort.RECENT, LibraryArrangement.restored(suite).sort)
    }

    /** A sort other than recently-read is left alone by the migration. */
    @Test
    fun migrationLeavesOtherSortsAlone() {
        val suite = InMemoryKeyValueStore()
        LibraryArrangement(sort = LibraryArrangement.Sort.TITLE).store(suite)
        assertEquals(LibraryArrangement.Sort.TITLE, LibraryArrangement.restored(suite).sort)
    }

    /** Recently added keeps undated books at the end, reversed or not. */
    @Test
    fun addedSortKeepsUndatedLast() {
        val books = listOf(
            book("Undated"),
            book("Old", createdAt = "2024-01-01T00:00:00.000Z"),
            book("New", createdAt = "2025-01-01T00:00:00.000Z"),
        )
        assertEquals(listOf("New", "Old", "Undated"), titles(LibraryArrangement(sort = LibraryArrangement.Sort.ADDED), books))
        assertEquals(listOf("Old", "New", "Undated"), titles(LibraryArrangement(sort = LibraryArrangement.Sort.ADDED, ascending = true), books))
    }

    /** What a reader chose survives a round trip through the preferences. */
    @Test
    fun roundTripsThroughDefaults() {
        val suite = InMemoryKeyValueStore()
        val arrangement = LibraryArrangement(
            sort = LibraryArrangement.Sort.NARRATOR, ascending = true,
            shelf = LibraryArrangement.Shelf.WITH_NARRATION, tags = setOf("Fantasy"),
        )

        arrangement.store(suite)
        assertEquals(arrangement, LibraryArrangement.restored(suite))
    }

    /** Narrator sort orders by narrator, and books without one go last. */
    @Test
    fun narratorSort() {
        val books = listOf(book("No narrator"), book("Zeta", narrator = "Zeta"), book("Alpha", narrator = "Alpha"))
        assertEquals(listOf("Alpha", "Zeta", "No narrator"), titles(LibraryArrangement(sort = LibraryArrangement.Sort.NARRATOR), books))
    }

    /**
     * Reversed recently-read still keeps unread books at the end: reversing
     * the whole array buried the book actually being read under every book
     * never opened.
     */
    @Test
    fun recentSortReversed() {
        val books = listOf(
            book("Never opened"),
            book("Read yesterday", progress = 0.4, positionTimestamp = 1_000.0),
            book("Read today", progress = 0.2, positionTimestamp = 2_000.0),
        )
        assertEquals(
            listOf("Read yesterday", "Read today", "Never opened"),
            titles(LibraryArrangement(sort = LibraryArrangement.Sort.RECENT, ascending = true), books),
        )
    }

    /** Reversed narrator order still keeps unnarrated books at the end. */
    @Test
    fun narratorSortReversed() {
        val books = listOf(book("No narrator"), book("Zeta", narrator = "Zeta"), book("Alpha", narrator = "Alpha"))
        assertEquals(
            listOf("Zeta", "Alpha", "No narrator"),
            titles(LibraryArrangement(sort = LibraryArrangement.Sort.NARRATOR, ascending = true), books),
        )
    }

    /** Series sort reads each series in order, standalone books last. */
    @Test
    fun seriesSort() {
        val books = listOf(
            book("Alone"),
            book("Second", series = listOf("Gothic Horror" to 2.0)),
            book("Interlude", series = listOf("Gothic Horror" to 1.5)),
            book("First", series = listOf("Gothic Horror" to 1.0)),
            book("Another shelf", series = listOf("Aviation" to 1.0)),
            book("A standalone"),
        )
        assertEquals(
            listOf("Another shelf", "First", "Interlude", "Second", "Alone", "A standalone"),
            titles(LibraryArrangement(sort = LibraryArrangement.Sort.SERIES), books),
        )
    }

    /** Reversed series order still keeps standalone books at the end. */
    @Test
    fun seriesSortReversed() {
        val books = listOf(
            book("Alone"),
            book("Second", series = listOf("Gothic Horror" to 2.0)),
            book("First", series = listOf("Gothic Horror" to 1.0)),
            book("Another shelf", series = listOf("Aviation" to 1.0)),
        )
        assertEquals(
            listOf("Second", "First", "Another shelf", "Alone"),
            titles(LibraryArrangement(sort = LibraryArrangement.Sort.SERIES, ascending = true), books),
        )
    }

    /** An unnumbered book sorts after its numbered siblings. */
    @Test
    fun seriesSortPutsUnnumberedLast() {
        val books = listOf(
            book("Companion", series = listOf("Gothic Horror" to null)),
            book("Second", series = listOf("Gothic Horror" to 2.0)),
            book("First", series = listOf("Gothic Horror" to 1.0)),
        )
        assertEquals(listOf("First", "Second", "Companion"), titles(LibraryArrangement(sort = LibraryArrangement.Sort.SERIES), books))
        assertEquals(
            listOf("Second", "First", "Companion"),
            titles(LibraryArrangement(sort = LibraryArrangement.Sort.SERIES, ascending = true), books),
        )
    }

    /** A book in two series files under the one it is numbered in. */
    @Test
    fun seriesSortFollowsThePrimarySeries() {
        val books = listOf(
            book("Omnibus", series = listOf("Publisher's Library" to null, "Gothic Horror" to 2.0)),
            book("First", series = listOf("Gothic Horror" to 1.0)),
        )
        assertEquals(listOf("First", "Omnibus"), titles(LibraryArrangement(sort = LibraryArrangement.Sort.SERIES), books))
    }

    /** An older stored arrangement is untouched by the new sort. */
    @Test
    fun seriesSortIsANewRawValue() {
        val restored = decode("""{"sort":"narrator","ascending":true,"shelf":"reading","tags":[]}""")
        assertEquals(LibraryArrangement.Sort.NARRATOR, restored.sort)
        assertTrue(LibraryArrangement.Sort.entries.contains(LibraryArrangement.Sort.SERIES))
        assertEquals("Series", LibraryArrangement.Sort.SERIES.title)
    }

    /** An unknown sort costs the sort and nothing else. */
    @Test
    fun anUnknownSortDoesNotResetEverything() {
        val restored = decode("""{"sort":"chronological","ascending":true,"shelf":"reading","tags":["Gothic"]}""")
        assertEquals(LibraryArrangement().sort, restored.sort)
        assertEquals(LibraryArrangement.Shelf.READING, restored.shelf)
        assertEquals(setOf("Gothic"), restored.tags)
        assertTrue(restored.ascending)
    }

    /** Reverse order reverses a title sort end to end. */
    @Test
    fun titleSortReversed() {
        val books = listOf(book("The Time Machine"), book("Alice"), book("A Study in Scarlet"))
        assertEquals(
            listOf("The Time Machine", "A Study in Scarlet", "Alice"),
            titles(LibraryArrangement(sort = LibraryArrangement.Sort.TITLE, ascending = true), books),
        )
    }

    /** An accented title files under its letter, not after Z. */
    @Test
    fun accentedTitleSort() {
        val books = listOf(book("Zorro"), book("Émile"), book("Alice"))
        assertEquals(listOf("Alice", "Émile", "Zorro"), titles(LibraryArrangement(sort = LibraryArrangement.Sort.TITLE), books))
    }
}
