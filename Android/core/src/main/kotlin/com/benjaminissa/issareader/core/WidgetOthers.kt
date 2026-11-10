package com.benjaminissa.issareader.core

import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.BookFormat
import com.benjaminissa.issareader.core.model.isLocal
import com.benjaminissa.issareader.core.sync.LibraryArrangement
import com.benjaminissa.issareader.core.sync.LibraryDerivation
import kotlin.math.abs

/**
 * Which other books the widget lists, and when a change in them is worth a redraw.
 */
object WidgetOthers {
    /** The most the large widget's row holds. */
    const val LIMIT = 4

    /** The smallest move in a book's progress worth redrawing for: the current book's own threshold. */
    const val PROGRESS_WORTH_DRAWING = 0.002

    /**
     * The books to list beside [currentBookId]: the library's "continue
     * reading" order (progress above zero, most recently positioned first),
     * only those at the Reading stage — so not finished and not to-read — never
     * a book from the reader's own files, never the current one, at most
     * [LIMIT].
     */
    fun select(books: List<Book>, currentBookId: String?, limit: Int = LIMIT): List<OtherBook> =
        LibraryDerivation(books).continueReading
            .asSequence()
            .filter { !it.isLocal && it.uuid != currentBookId && LibraryArrangement.stage(it) == LibraryArrangement.Stage.READING }
            .distinctBy { it.uuid }
            .take(limit)
            .map {
                OtherBook(
                    bookId = it.uuid,
                    title = it.title,
                    author = it.byline,
                    progress = it.position?.locator?.totalProgression ?: 0.0,
                    coverIsSquare = BookFormat.AUDIOBOOK in it.servableFormats,
                )
            }
            .toList()

    /**
     * Whether [new] differs from [old] enough to write and redraw: the ids or
     * their order changed, a title changed, a cover's shape changed, or a
     * progress moved by [threshold] or more. Anything less is left until it
     * adds up, because the stored value is not updated by it.
     */
    fun worthRedrawing(old: List<OtherBook>, new: List<OtherBook>, threshold: Double = PROGRESS_WORTH_DRAWING): Boolean {
        if (old.size != new.size) return true
        return old.zip(new).any { (a, b) ->
            a.bookId != b.bookId || a.title != b.title || a.coverIsSquare != b.coverIsSquare ||
                abs(a.progress - b.progress) >= threshold
        }
    }
}
