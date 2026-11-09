package com.benjaminissa.issareader.core.sync

import com.benjaminissa.issareader.core.bookJson
import com.benjaminissa.issareader.core.decodeBook
import com.benjaminissa.issareader.core.model.Book
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The fixture both rail suites build their books with. */
internal object RailBooks {
    fun book(
        title: String,
        status: String? = null,
        progress: Double? = null,
        positionTimestamp: Double? = null,
        createdAt: String? = null,
        tags: List<String> = emptyList(),
        series: List<Pair<String, Double?>> = emptyList(),
        readaloud: Boolean = false,
        audiobook: Boolean = false,
    ): Book {
        val json = bookJson(uuid = title, title = title)
        json["tags"] = tags.map { mapOf("uuid" to it, "name" to it) }
        json["series"] = series.map { (name, position) ->
            val row = mutableMapOf<String, Any?>("uuid" to name, "name" to name)
            if (position != null) row["position"] = position
            row
        }
        if (status != null) json["status"] = mapOf("uuid" to status, "name" to status)
        if (progress != null) {
            json["position"] = mapOf(
                "locator" to mapOf("href" to "a", "type" to "t", "locations" to mapOf("totalProgression" to progress)),
                "timestamp" to (positionTimestamp ?: 0.0),
            )
        }
        if (createdAt != null) json["createdAt"] = createdAt
        if (readaloud) json["readaloud"] = mapOf("uuid" to "r", "filepath" to "r.epub", "identifiers" to emptyList<Any>())
        if (audiobook) json["audiobook"] = mapOf("uuid" to "a", "filepath" to "a.m4b", "identifiers" to emptyList<Any>())
        return decodeBook(json)
    }
}

/**
 * Deriving the rails: what the Browse rails and the Reading tab show. Ported
 * from `LibraryRailsTests.swift`.
 *
 * Every rule here decides what a reader sees on a shelf, and none of the
 * views that draw the shelves are under test — so the rules live in core and
 * are pinned here.
 */
class LibraryRailsTest {
    private fun book(
        title: String,
        status: String? = null,
        progress: Double? = null,
        positionTimestamp: Double? = null,
        createdAt: String? = null,
        tags: List<String> = emptyList(),
        series: List<Pair<String, Double?>> = emptyList(),
        readaloud: Boolean = false,
        audiobook: Boolean = false,
    ): Book = RailBooks.book(title, status, progress, positionTimestamp, createdAt, tags, series, readaloud, audiobook)

    private fun day(n: Int): String = String.format("2025-01-%02dT00:00:00.000Z", n)

    // Series

    /** A standalone book never becomes a one-book series. */
    @Test
    fun singleBookSeriesIsDropped() {
        val rails = LibraryRails(
            listOf(
                book("Alone", series = listOf("Solo" to 1.0)),
                book("One", series = listOf("Pair" to 1.0)),
                book("Two", series = listOf("Pair" to 2.0)),
            ),
        )
        assertEquals(listOf("Pair"), rails.series.map { it.name })
        assertEquals(2, rails.series.first().books.size)
    }

    /** A series reads in position order, a novella between its neighbours, the unplaced last. */
    @Test
    fun seriesOrder() {
        val rails = LibraryRails(
            listOf(
                book("Unplaced", series = listOf("Saga" to null)),
                book("Second", series = listOf("Saga" to 2.0)),
                book("Between", series = listOf("Saga" to 1.5)),
                book("First", series = listOf("Saga" to 1.0)),
            ),
        )
        assertEquals(listOf("First", "Between", "Second", "Unplaced"), rails.series.first().books.map { it.title })
    }

    /** Series are listed by name, case aside. */
    @Test
    fun seriesByName() {
        val rails = LibraryRails(
            listOf(
                book("z1", series = listOf("zeta" to 1.0)), book("z2", series = listOf("zeta" to 2.0)),
                book("a1", series = listOf("Alpha" to 1.0)), book("a2", series = listOf("Alpha" to 2.0)),
                book("m1", series = listOf("mid" to 1.0)), book("m2", series = listOf("mid" to 2.0)),
            ),
        )
        assertEquals(listOf("Alpha", "mid", "zeta"), rails.series.map { it.name })
    }

    /** A book in two series reports its place in the one being shown. */
    @Test
    fun positionInTheRightSeries() {
        val twice = book("X", series = listOf("Discworld" to 5.0, "Death" to 1.0))
        val rails = LibraryRails(
            listOf(twice, book("Y", series = listOf("Death" to 2.0)), book("Z", series = listOf("Discworld" to 2.0))),
        )
        val death = rails.series.firstOrNull { it.name == "Death" }
        val discworld = rails.series.firstOrNull { it.name == "Discworld" }
        assertEquals(1.0, death?.position(twice))
        assertEquals(5.0, discworld?.position(twice))
    }

    // Recently added, audio, tags

    /** Recently added is newest first and leaves undated books out. */
    @Test
    fun recentlyAdded() {
        val rails = LibraryRails(listOf(book("Undated"), book("Old", createdAt = day(1)), book("New", createdAt = day(9))))
        assertEquals(listOf("New", "Old"), rails.recentlyAdded.map { it.title })
    }

    /** A rail holds twelve, and the newest twelve at that. */
    @Test
    fun railIsCapped() {
        val books = (1..20).map { book("B$it", createdAt = day(it)) }
        val rails = LibraryRails(books)
        assertEquals(LibraryRails.railLength, rails.recentlyAdded.size)
        assertEquals("B20", rails.recentlyAdded.first().title)
    }

    /** The audio rail is exactly the audio shelf. */
    @Test
    fun audioRailAgreesWithTheShelf() {
        val books = listOf(book("Read along", readaloud = true), book("Audiobook", audiobook = true), book("Text only"))
        val rails = LibraryRails(books)
        val shelf = LibraryArrangement(sort = LibraryArrangement.Sort.TITLE, shelf = LibraryArrangement.Shelf.WITH_NARRATION).apply(books)
        assertEquals(shelf.map { it.uuid }.toSet(), rails.withAudio.map { it.uuid }.toSet())
        assertEquals(2, rails.withAudio.size)
    }

    /** The audio rail holds only audio the server can serve. */
    @Test
    fun audioRailHoldsOnlyServableAudio() {
        val rails = LibraryRails(UnservableAudio.books())
        assertEquals(listOf(UnservableAudio.playable), rails.withAudio.map { it.title })
    }

    /** Tag rails skip single-book tags and lead with the most used. */
    @Test
    fun tagRails() {
        val rails = LibraryRails(
            listOf(
                book("A", tags = listOf("Fiction", "Rare")),
                book("B", tags = listOf("Fiction", "History")),
                book("C", tags = listOf("Fiction", "History")),
                book("D", tags = listOf("Fiction")),
            ),
        )
        assertEquals(listOf("Fiction", "History"), rails.tagRails.map { it.tag })
        assertEquals(4, rails.tagRails.first().books.size)
    }

    /** No more than four tag rails, ties broken by name. */
    @Test
    fun tagRailsAreCapped() {
        val books = mutableListOf<Book>()
        for (tag in listOf("E", "D", "C", "B", "A")) {
            books.add(book("${tag}1", tags = listOf(tag)))
            books.add(book("${tag}2", tags = listOf(tag)))
        }
        val rails = LibraryRails(books)
        assertEquals(listOf("A", "B", "C", "D"), rails.tagRails.map { it.tag })
    }

    /** The rails carry every tag's books, as the derivation groups them. */
    @Test
    fun everyTagIsKept() {
        val books = listOf(book("A", tags = listOf("Fiction", "Rare", "Fiction")), book("B", tags = listOf("Fiction", "History")))
        val rails = LibraryRails(books)
        assertEquals(
            LibraryDerivation(books).byTag.mapValues { (_, list) -> list.map { it.uuid } },
            rails.byTag.mapValues { (_, list) -> list.map { it.uuid } },
        )
        assertEquals(listOf("A"), rails.byTag["Rare"]?.map { it.uuid })
        assertEquals(listOf("A", "B"), rails.byTag["Fiction"]?.map { it.uuid })
        assertTrue(LibraryRails.empty.byTag.isEmpty())
    }

    // Reading and to-read

    /** In-progress books are ordered by recency, never-opened ones last. */
    @Test
    fun readingOrder() {
        val rails = LibraryRails(
            listOf(
                book("Marked only", status = "Reading"),
                book("Yesterday", status = "Reading", progress = 0.4, positionTimestamp = 1_000.0),
                book("Today", status = "Reading", progress = 0.1, positionTimestamp = 2_000.0),
                book("Done", status = "Read", progress = 1.0, positionTimestamp = 3_000.0),
            ),
        )
        assertEquals(listOf("Today", "Yesterday", "Marked only"), rails.reading.map { it.title })
    }

    /** To-read includes a book with no status at all, newest first. */
    @Test
    fun toReadIncludesUnstatused() {
        val rails = LibraryRails(
            listOf(
                book("No status", createdAt = day(2)),
                book("Queued", status = "To read", createdAt = day(5)),
                book("Reading", status = "Reading"),
            ),
        )
        assertEquals(listOf("Queued", "No status"), rails.toRead.map { it.title })
    }

    /** An empty library derives empty rails. */
    @Test
    fun emptyLibrary() {
        assertEquals(LibraryRails.empty, LibraryRails(emptyList()))
        assertTrue(ReadingHome.empty.isEmpty)
    }
}

/**
 * Each book once in each group. Ported from `RepeatedNamesTests` in
 * `LibraryRailsTests.swift`.
 *
 * A catalogue row can name the same creator, series or tag twice — an EPUB
 * whose metadata repeats a `dc:creator` is enough — and every grouping put the
 * book in once per mention.
 */
class RepeatedNamesTest {
    private fun book(
        title: String,
        authors: List<String> = emptyList(),
        narrators: List<String> = emptyList(),
        series: List<Pair<String, Double?>> = emptyList(),
        tags: List<String> = emptyList(),
    ): Book {
        fun creators(names: List<String>) = names.mapIndexed { offset, name -> mapOf("uuid" to "$title-$offset", "name" to name) }
        val json = bookJson(uuid = title, title = title)
        json["authors"] = creators(authors)
        json["narrators"] = creators(narrators)
        json["tags"] = tags.mapIndexed { offset, name -> mapOf("uuid" to "$title-tag-$offset", "name" to name) }
        json["series"] = series.mapIndexed { offset, (name, position) ->
            val row = mutableMapOf<String, Any?>("uuid" to "$title-series-$offset", "name" to name)
            if (position != null) row["position"] = position
            row
        }
        return decodeBook(json)
    }

    /** A repeated author or narrator lists the book once. */
    @Test
    fun creators() {
        val twice = book("Twice", authors = listOf("Jane Austen", "Jane Austen"), narrators = listOf("Reader", "Reader"))
        val other = book("Other", authors = listOf("Jane Austen"), narrators = listOf("Reader"))
        val derivation = LibraryDerivation(listOf(twice, other))

        assertEquals(listOf("Twice", "Other"), derivation.byAuthor["Jane Austen"]?.map { it.title })
        assertEquals(listOf("Twice", "Other"), derivation.byNarrator["Reader"]?.map { it.title })
    }

    /** A repeated series lists the book once, and does not make a series of one. */
    @Test
    fun series() {
        val twice = book("Twice", series = listOf("Saga" to 1.0, "Saga" to 1.0))
        val other = book("Other", series = listOf("Saga" to 2.0))
        val alone = book("Alone", series = listOf("Solo" to 1.0, "Solo" to 1.0))
        val rails = LibraryRails(listOf(twice, other, alone))

        assertEquals(listOf("Twice", "Other"), LibraryDerivation(listOf(twice, other)).bySeries["Saga"]?.map { it.title })
        assertEquals("one book named twice is not a series", listOf("Saga"), rails.series.map { it.name })
        assertEquals(listOf("Twice", "Other"), rails.series.first().books.map { it.title })
    }

    /** A repeated tag lists the book once, and does not make a rail of one. */
    @Test
    fun tags() {
        val twice = book("Twice", tags = listOf("Gothic", "Gothic"))
        val other = book("Other", tags = listOf("Gothic"))
        val alone = book("Alone", tags = listOf("Rare", "Rare"))
        val rails = LibraryRails(listOf(twice, other, alone))

        assertEquals("a tag on one book is a label, not a rail", listOf("Gothic"), rails.tagRails.map { it.tag })
        assertEquals(listOf("Twice", "Other"), rails.tagRails.first().books.map { it.title })
        assertEquals(listOf("Twice", "Other"), LibraryDerivation(listOf(twice, other, alone)).byTag["Gothic"]?.map { it.title })
    }

    /** A repeated tag counts its book once on the chip, as the filter it applies does. */
    @Test
    fun tagCounts() {
        val books = listOf(book("Twice", tags = listOf("Gothic", "Gothic")), book("Other", tags = listOf("Gothic")))
        val facets = LibraryFacets(books = books, downloadedUuids = emptySet())

        assertEquals(listOf(LibraryFacets.TagCount(name = "Gothic", count = 2)), facets.tagCounts)
        assertEquals(2, LibraryArrangement(tags = setOf("Gothic")).apply(books).size)
        // And as the tag's own page lists them: one grouping behind the chip
        // and the page.
        assertEquals(2, LibraryDerivation(books).byTag["Gothic"]?.size)
    }
}

/** The Reading tab's home. Ported from `ReadingHomeTests` in `LibraryRailsTests.swift`. */
class ReadingHomeTest {
    private fun home(books: List<Book>): ReadingHome = ReadingHome(books = books, rails = LibraryRails(books))

    /** The last-positioned book leads, whatever its status says. */
    @Test
    fun heroIsTheLastPositioned() {
        val books = listOf(
            RailBooks.book("Marked reading", status = "Reading"),
            RailBooks.book("Opened yesterday", status = "To read", progress = 0.2, positionTimestamp = 1_000.0),
            RailBooks.book("Opened today", status = "Reading", progress = 0.3, positionTimestamp = 2_000.0),
        )
        val home = home(books)
        assertEquals("Opened today", home.hero?.title)
        // The hero is not repeated below itself; the never-opened book is still listed.
        assertEquals(listOf("Marked reading"), home.alsoReading.map { it.title })
    }

    /** A book merely marked as being read leads when nothing has a position. */
    @Test
    fun markedBookLeadsWithoutPositions() {
        val home = home(listOf(RailBooks.book("Queued", status = "To read"), RailBooks.book("Marked", status = "Reading")))
        assertEquals("Marked", home.hero?.title)
        assertTrue(home.alsoReading.isEmpty())
        assertEquals(listOf("Queued"), home.upNext.map { it.title })
        assertFalse(home.isEmpty)
    }

    /** A library of finished books has nothing to continue and nothing next. */
    @Test
    fun finishedLibraryIsEmpty() {
        val home = home(listOf(RailBooks.book("Done", status = "Read"), RailBooks.book("Also done", status = "Finished")))
        assertNull(home.hero)
        assertTrue(home.isEmpty)
    }

    /** A queue alone is not an empty tab. */
    @Test
    fun queueAloneIsNotEmpty() {
        val home = home(listOf(RailBooks.book("Queued", status = "To read")))
        assertNull(home.hero)
        assertFalse(home.isEmpty)
    }
}
