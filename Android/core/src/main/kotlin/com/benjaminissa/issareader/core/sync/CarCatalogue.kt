package com.benjaminissa.issareader.core.sync

import com.benjaminissa.issareader.core.LocalizedComparison
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.BookFormat
import com.benjaminissa.issareader.core.model.DurationText
import com.benjaminissa.issareader.core.model.swiftMax
import com.benjaminissa.issareader.core.model.swiftMin

/**
 * What a car is offered, and in what order.
 *
 * Swift's `CarPlayCatalogue`, which on Android feeds Android Auto. Kept here
 * rather than in the car service because every rule below is one that is
 * wrong in a way you would only find out about while driving: a book with no
 * audio listed as though it could play, a list longer than the head unit will
 * draw, a subtitle that says nothing useful at a glance.
 */
class CarCatalogue(
    val books: List<Book>,
    val downloadedUuids: Set<String> = emptySet(),
) {
    /**
     * The car's tabs.
     *
     * Three, deliberately. A car's lists are read at a glance at 70mph, and
     * the useful questions are "what was I in the middle of", "what else is
     * there", and "what will play without a signal".
     */
    enum class Shelf(
        val title: String,
        /**
         * The SF Symbol the Swift client draws the tab with, kept so the two
         * clients name the same icon; the Android car service maps it to its
         * own.
         */
        val symbol: String,
        /**
         * Shown when the shelf has nothing in it, because a blank list in a
         * car is indistinguishable from an app that has crashed.
         */
        val emptyMessage: String,
    ) {
        RECENT("Recent", "clock", "Nothing started yet"),
        LIBRARY("Library", "books.vertical", "No audiobooks in your library"),
        DOWNLOADED("Downloaded", "arrow.down.circle", "No downloads on this phone"),
        ;

        /** Swift's raw value: `recent`, `library`, `downloaded`. */
        val rawValue: String get() = name.lowercase()
    }

    data class Entry(
        val bookUuid: String,
        val title: String,
        /**
         * Author, and how much is left. Not a synopsis — this is read at a
         * glance, at speed.
         */
        val subtitle: String,
        val progress: Double?,
        /**
         * Whether it will play with no signal, which in a car is the
         * difference between working and not.
         */
        val isDownloaded: Boolean,
    )

    /**
     * Books the car could actually play.
     *
     * `servableFormats`, not `availableFormats`: the server creates a
     * readaloud row when alignment is merely requested, so a bare null check
     * offers books with no audio behind them. Listing a text-only book in a
     * car is offering the driver a button that does nothing.
     */
    internal val playable: List<Book>
        get() = books.filter {
            val formats = it.servableFormats
            BookFormat.AUDIOBOOK in formats || BookFormat.READALOUD in formats
        }

    /**
     * One shelf's items, in the order the car should draw them.
     *
     * @param limit the head unit's maximum, which varies by car and is
     *   enforced by the car rather than merely advised. Passing it in rather
     *   than hard-coding one keeps the truncation at the edge that knows.
     */
    fun entries(shelf: Shelf, limit: Int): List<Entry> {
        if (limit <= 0) return emptyList()
        val selected: List<Book> = when (shelf) {
            Shelf.RECENT -> LibraryDerivation(playable).continueReading
            Shelf.LIBRARY -> playable.sortedWith(LocalizedComparison.comparing { it.title })
            // Natural order is kept inside the other shelves rather than
            // floating downloads to the top of them: a driver looking for the
            // book they were in the middle of should find it where they left
            // it. This shelf is the offline answer instead.
            //
            // Every download, not `continueReading`: that filter drops any
            // book without progress, and a book downloaded for the drive and
            // never yet opened is precisely what this shelf exists to offer.
            // In-progress books come first, most recently positioned on top;
            // unstarted downloads follow in the library's own order.
            Shelf.DOWNLOADED -> playable.filter { it.uuid in downloadedUuids }
                .sortedByDescending { it.position?.timestamp ?: 0.0 }
        }
        return selected.take(limit).map(::entry)
    }

    internal fun entry(book: Book): Entry = Entry(
        bookUuid = book.uuid,
        title = book.title,
        subtitle = subtitle(book),
        progress = book.progress,
        isDownloaded = book.uuid in downloadedUuids,
    )

    /** Driving glanceability: author plus time remaining. */
    internal fun subtitle(book: Book): String {
        val parts = mutableListOf(book.byline)
        val duration = book.narrationDuration
        if (duration != null && duration > 0) {
            val remaining = duration * (1 - swiftMin(swiftMax(book.progress ?: 0.0, 0.0), 1.0))
            parts.add(durationText(remaining) + " left")
        }
        return parts.filter { it.isNotEmpty() }.joinToString(" · ")
    }

    companion object {
        fun durationText(seconds: Double): String = DurationText.text(seconds)
    }
}
