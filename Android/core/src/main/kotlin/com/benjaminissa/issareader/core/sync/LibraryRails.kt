package com.benjaminissa.issareader.core.sync

import com.benjaminissa.issareader.core.LocalizedComparison
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.orderedBy

/** A series as the library can show it: a name, and its books in reading order. */
data class SeriesGroup(
    val name: String,
    /**
     * In `position` order, fractional positions between their neighbours and
     * unpositioned books last — the order `LibraryDerivation.bySeries` builds.
     */
    val books: List<Book>,
) {
    val id: String get() = name

    /**
     * Where a book sits in *this* series. A book can belong to two, so the
     * membership is looked up by name rather than taken from `series.first`.
     */
    fun position(of: Book): Double? = of.membership(name)?.position

    /**
     * How long the series can be said to be: the number of books held, when
     * their positions are exactly 1 to that number, and null otherwise.
     *
     * The server numbers a book within its series but never says how many
     * there are, so "of N" can only be what the library holds — and the book
     * screen said it whatever the positions were: holding books 2 and 3 read
     * "Book 2 of 2" beside a "Book 3" the same library holds. With the whole
     * run from one, no book held contradicts it. A novella at 1.5, two books
     * at one place, or one with no number at all, and it is not said.
     */
    val statedCount: Int?
        get() {
            val held = books.mapNotNull { position(it) }.sorted()
            if (held.isEmpty() || held.size != books.size) return null
            if (held != (1..held.size).map { it.toDouble() }) return null
            return held.size
        }
}

/**
 * The rails the Library's Browse screen and the Reading tab show, derived from
 * the catalogue in one pass and memoised by the app model.
 *
 * Every rule that decides what is on a rail lives here rather than in a view:
 * a composition runs more than once per frame, and nothing in the app is
 * under test the way this module is. Built the way [LibraryFacets] is — one
 * value, one pass, equality, [empty] — and rebuilt only when the catalogue
 * changes.
 */
data class LibraryRails(
    /**
     * Newest arrivals first, by the server's `createdAt`. Undated books are
     * left out: they cannot be "recent" in any order.
     */
    val recentlyAdded: List<Book>,
    /**
     * Every series with more than one book, by name. A standalone book is not
     * a one-book series, whatever the metadata says.
     */
    val series: List<SeriesGroup>,
    /**
     * The `WITH_NARRATION` shelf's own predicate, so the rail and the shelf
     * its "See all" opens can never disagree about a book.
     */
    val withAudio: List<Book>,
    /**
     * The most-used tags, each with the books that carry it. Tags on a single
     * book are skipped — a rail of one is a label, not a place to look around
     * ([minimumBooksPerTag], the floor a book page's tag chip links by too).
     */
    val tagRails: List<TagRail>,
    /** Books not yet started, newest arrivals first — the Reading tab's "Up next". */
    val toRead: List<Book>,
    /**
     * Books in progress by status, most recently positioned first and the
     * ones never opened last. Uncapped: the Reading tab lists them all.
     */
    val reading: List<Book>,
    /**
     * Every tag, with each book that carries it once, in catalogue order —
     * `LibraryDerivation.byTag`, which the tag rails above are cut from. Kept
     * so the app model memoises its tag index from this pass rather than
     * grouping the whole library a second time.
     */
    val byTag: Map<String, List<Book>>,
) {
    data class TagRail(val tag: String, val books: List<Book>) {
        val id: String get() = tag
    }

    companion object {
        /** How many covers a rail holds. The "See all" route shows the rest. */
        const val railLength = 12

        /** How many tag rails Browse shows; the tag menu caps itself the same way. */
        const val tagRailCount = 4

        /**
         * How many books a tag needs before it is a place to go.
         *
         * A tag on one book is a label, not a shelf: its page would hold the
         * book the reader came from and nothing else. The same floor decides
         * which tags get a Browse rail and which chips on a book's page link
         * to the tag's page, so the two can never disagree about a tag.
         * (Declared in `StagedBooks.swift`'s extension.)
         */
        const val minimumBooksPerTag = 2

        val empty: LibraryRails by lazy { LibraryRails(emptyList()) }

        /** The rails of [books], in one pass. */
        operator fun invoke(books: List<Book>): LibraryRails {
            val recentlyAdded = byArrival(books.filter { it.createdAt?.value != null }).take(railLength)

            // Each book once per series and per tag, so "more than one book"
            // below counts books, not mentions. See `LibraryDerivation.grouped`.
            val derivation = LibraryDerivation(books)
            val series = derivation.bySeries
                .filter { it.value.size > 1 }
                .map { SeriesGroup(it.key, it.value) }
                .sortedWith(LocalizedComparison.comparing { it.name })

            val withAudio = books.filter { it.hasServableAudio }.take(railLength)

            val byTag = derivation.byTag
            val tagRails = byTag.entries
                .filter { it.value.size >= minimumBooksPerTag }
                .sortedWith(compareByDescending<Map.Entry<String, List<Book>>> { it.value.size }.thenBy { it.key })
                .take(tagRailCount)
                .map { TagRail(it.key, it.value.take(railLength)) }

            val toRead = mutableListOf<Book>()
            val reading = mutableListOf<Book>()
            for (book in books) {
                when (LibraryArrangement.stage(book)) {
                    LibraryArrangement.Stage.TO_READ -> toRead.add(book)
                    LibraryArrangement.Stage.READING -> reading.add(book)
                    LibraryArrangement.Stage.FINISHED -> Unit
                }
            }
            return LibraryRails(
                recentlyAdded = recentlyAdded,
                series = series,
                withAudio = withAudio,
                tagRails = tagRails,
                toRead = byArrival(toRead).take(railLength),
                reading = byRecency(reading),
                byTag = byTag,
            )
        }

        /** Newest first; undated books keep their catalogue order at the end. */
        fun byArrival(books: List<Book>): List<Book> = books.sortedWith(
            orderedBy { left, right ->
                val l = left.createdAt?.value
                val r = right.createdAt?.value
                when {
                    l != null && r != null -> l > r
                    l == null && r != null -> false
                    l != null && r == null -> true
                    else -> false
                }
            },
        )

        /** Most recently positioned first; never-opened books at the end. */
        fun byRecency(books: List<Book>): List<Book> = books.sortedWith(
            orderedBy { left, right ->
                val l = left.position?.timestamp
                val r = right.position?.timestamp
                when {
                    l != null && r != null -> l > r
                    l == null && r != null -> false
                    l != null && r == null -> true
                    else -> false
                }
            },
        )
    }
}

/**
 * What the Reading tab shows: the book to continue, the others in progress,
 * and what comes next.
 */
data class ReadingHome(
    /**
     * The Continue card. The book with the most recent position, whatever its
     * status — the promise is "where you left off", and it is the same book
     * the widget shows. Only when nothing has a position does a book merely
     * *marked* as being read lead, and then without a progress line.
     */
    val hero: Book?,
    /**
     * Every other book in progress by status, most recent first. Empty when
     * the hero is the only one.
     */
    val alsoReading: List<Book>,
    /** The To-read queue, newest arrivals first. */
    val upNext: List<Book>,
) {
    /** Nothing to continue and nothing queued: the tab shows its prompt. */
    val isEmpty: Boolean get() = hero == null && upNext.isEmpty()

    companion object {
        val empty: ReadingHome by lazy { ReadingHome(emptyList(), LibraryRails.empty) }

        operator fun invoke(books: List<Book>, rails: LibraryRails): ReadingHome {
            val hero = LibraryDerivation(books).continueReading.firstOrNull() ?: rails.reading.firstOrNull()
            return ReadingHome(
                hero = hero,
                alsoReading = rails.reading.filter { it.uuid != hero?.uuid },
                upNext = rails.toRead,
            )
        }
    }
}
