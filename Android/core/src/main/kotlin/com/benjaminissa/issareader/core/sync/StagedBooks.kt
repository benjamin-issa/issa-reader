package com.benjaminissa.issareader.core.sync

import com.benjaminissa.issareader.core.LocalizedComparison
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.PublishedYearText
import com.benjaminissa.issareader.core.model.SeriesText
import com.benjaminissa.issareader.core.model.Status

/**
 * A cut of the library grouped by reading stage: what the tag page and the
 * "More by" page show.
 *
 * In-progress first, then unread, then finished — the order a reader decides
 * what to pick up next in, which is what a page of books sharing a tag or an
 * author is for. The stages are the library's own ([LibraryArrangement.stage]),
 * so a book is in the same section here as on the Reading, To read and
 * Finished shelves, and each section is named with the server's label for
 * its status, so a status renamed on the server reads renamed here.
 *
 * Built from whatever books it is given, live, every time: nothing here is a
 * copy that can go stale when a status or a position changes.
 */
class StagedBooks(books: List<Book>, statuses: List<Status>) {
    data class Section(
        val stage: LibraryArrangement.Stage,
        /** The server's name for the stage, as the reader sees it. */
        val title: String,
        val books: List<Book>,
    ) {
        val id: LibraryArrangement.Stage get() = stage

        /** "Reading · 3", for the overline (which uppercases it). */
        val overline: String get() = "$title · ${books.size}"

        /** "Reading, 3 books", for a screen reader. */
        val spokenOverline: String get() = "$title, ${countText(books.size)}"
    }

    /** Non-empty sections in display order. */
    val sections: List<Section>
    val count: Int

    /** Books in the Reading stage. */
    val inProgress: Int

    /** Books with audio the server can serve: read-alongs and audiobooks. */
    val withNarration: Int

    init {
        // By uuid, once each: a catalogue can list a book twice under one tag
        // or author, and a book drawn twice gives two cells one identity.
        val seen = mutableSetOf<String>()
        val unique = books.filter { seen.add(it.uuid) }

        val byStage = mutableMapOf<LibraryArrangement.Stage, MutableList<Book>>()
        for (book in unique) byStage.getOrPut(LibraryArrangement.stage(book)) { mutableListOf() }.add(book)
        sections = order.mapNotNull { stage ->
            val staged = byStage[stage]
            if (staged.isNullOrEmpty()) return@mapNotNull null
            Section(stage = stage, title = title(stage, statuses, staged), books = ordered(staged, stage))
        }
        count = unique.size
        inProgress = byStage[LibraryArrangement.Stage.READING]?.size ?: 0
        // The predicate the With narration shelf and its chip use, so the
        // header can never count audio differently from them.
        withNarration = unique.count { it.hasServableAudio }
    }

    val isEmpty: Boolean get() = count == 0

    /**
     * Section headings are drawn only when there is more than one section:
     * one heading over every book repeats the count the summary just gave.
     */
    val showsOverlines: Boolean get() = sections.size > 1

    /**
     * "Show in Library" leads to the full grid with every sort and shelf; for
     * one book that is a longer way to the same single cover.
     */
    val offersShowInLibrary: Boolean get() = count >= 2

    /**
     * "24 books · 3 in progress · 7 with narration". A clause is dropped when
     * its count is zero, and a single book is only "1 book".
     */
    val summary: String get() = clauses.joinToString(" · ")

    /** The header as one spoken element: "Gothic, tag. 24 books, 3 in progress, 7 with narration." */
    fun spokenHeader(name: String, kind: String): String = "$name, $kind. ${clauses.joinToString(", ")}."

    private val clauses: List<String>
        get() {
            val parts = mutableListOf(countText(count))
            if (count < 2) return parts
            if (inProgress > 0) parts.add("$inProgress in progress")
            if (withNarration > 0) parts.add("$withNarration with narration")
            return parts
        }

    override fun equals(other: Any?): Boolean =
        other is StagedBooks && other.sections == sections && other.count == count &&
            other.inProgress == inProgress && other.withNarration == withNarration

    override fun hashCode(): Int = ((sections.hashCode() * 31 + count) * 31 + inProgress) * 31 + withNarration

    companion object {
        /** In-progress first, then unread, then finished. */
        internal val order = listOf(
            LibraryArrangement.Stage.READING,
            LibraryArrangement.Stage.TO_READ,
            LibraryArrangement.Stage.FINISHED,
        )

        internal fun countText(n: Int): String = if (n == 1) "1 book" else "$n books"

        /**
         * The status the server calls this stage, by its built-in name first —
         * 3.x keeps those fixed and puts any rewording in the label — then any
         * status that files under the stage. Before the server's list has
         * loaded, or when it fails to, the section's own books still carry
         * their status, so theirs is the next best word; the built-in name is
         * the last.
         */
        internal fun title(stage: LibraryArrangement.Stage, statuses: List<Status>, books: List<Book> = emptyList()): String {
            val builtIn = when (stage) {
                LibraryArrangement.Stage.READING -> Status.readingName
                LibraryArrangement.Stage.TO_READ -> Status.toReadName
                LibraryArrangement.Stage.FINISHED -> Status.readName
            }
            val carried = books.mapNotNull { it.status }
            val status = statuses.firstOrNull { it.name == builtIn }
                ?: statuses.firstOrNull { LibraryArrangement.stage(statusNamed = it.name) == stage }
                ?: carried.firstOrNull { it.name == builtIn }
                ?: carried.firstOrNull { LibraryArrangement.stage(statusNamed = it.name) == stage }
            return status?.displayName ?: builtIn
        }

        /**
         * Reading by recency — the one to resume is the one last opened — and
         * the rest by title the way the library's Title sort files them,
         * leading articles ignored.
         *
         * Each title's key is worked out once, before the sort. Worked out
         * inside the comparison it was two lowercased copies per comparison —
         * thousands for a tag on a few hundred books, on every redraw of the
         * page.
         */
        internal fun ordered(books: List<Book>, stage: LibraryArrangement.Stage): List<Book> = when (stage) {
            LibraryArrangement.Stage.READING -> LibraryRails.byRecency(books)
            LibraryArrangement.Stage.TO_READ, LibraryArrangement.Stage.FINISHED -> books
                .map { LibraryArrangement.sortKey(it.title) to it }
                .sortedWith(LocalizedComparison.comparing { it.first })
                .map { it.second }
        }

        /**
         * What the "More by" page says under a cover, where the author's name
         * would repeat the page's title: the series and number, else the year.
         *
         * The series is `primarySeries`, the one with a number where there is
         * one. The year is [PublishedYearText]'s, read in UTC as the book
         * page's Published row reads it.
         */
        fun authorCaption(book: Book): String? {
            book.primarySeries?.let { series ->
                val position = series.position ?: return series.name
                return "${series.name} · ${SeriesText.ordinal(position)}"
            }
            val published = book.publicationDate?.value ?: return null
            return PublishedYearText.text(published)
        }
    }
}
