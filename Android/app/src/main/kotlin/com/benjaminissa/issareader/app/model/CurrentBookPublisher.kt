package com.benjaminissa.issareader.app.model

import com.benjaminissa.issareader.core.CurrentBookSnapshot
import com.benjaminissa.issareader.core.CurrentBookSnapshotStore
import com.benjaminissa.issareader.core.Session
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.BookFormat
import com.benjaminissa.issareader.core.model.isLocal
import com.benjaminissa.issareader.core.sync.LibraryService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import java.time.Duration
import java.time.Instant
import kotlin.math.abs

/**
 * The one thing that writes the widget's snapshot.
 *
 * There used to be two: the reader wrote one when it saved a position, and the
 * listening loop wrote another every fifteen seconds. Two uncoordinated writers
 * of one file meant the widget flipped between the book being read and the
 * book being played every few seconds, and the widget's link opened whichever
 * wrote last.
 *
 * What state there is lives **in the snapshot on disk** ([CurrentBookSnapshotStore]),
 * not in this object. The one exception is a record of the last cover
 * *attempt*, which leaves nothing on disk when it fails.
 *
 * Never a book from the reader's own files: PRIVACY-ANDROID.md promises those are
 * sent nowhere, and the widget is outside the app.
 *
 * Main-thread only, as the Swift class is `@MainActor`.
 *
 * @param scope where cover fetches run.
 * @param reload asks the home-screen widget to redraw: `CurrentBookWidget.reload`
 *   in the app.
 * @param covers where the widget's art comes from.
 */
class CurrentBookPublisher(
    private val scope: CoroutineScope,
    private val reload: () -> Unit = {},
    private val covers: () -> CoverCache = { CoverCache.shared },
) {
    /** Which surface the snapshot currently belongs to. */
    sealed interface Owner {
        data class Reading(val bookUuid: String) : Owner
        data class Listening(val bookUuid: String) : Owner
    }

    /** Readable for the tests that ask whether anything was published. */
    var owner: Owner? = null
        private set

    /**
     * Set by [clear] and lifted by [resume]. Between a sign-out and the next
     * session nothing may write: the closing reader's flush and its debounced
     * save both outlive the account, and used to put its book back on the home
     * screen — deep link and all — after the snapshot was cleared.
     */
    private var suspended = false

    /**
     * When the owner last said it was playing. Ownership lapses rather than
     * latching: a stream that stalls stops publishing entirely, and without a
     * lapse the reader would be locked out of the widget for the process.
     */
    private var playingSince: Instant? = null

    /** Rejects a cover fetch that was overtaken while it was in flight. */
    private var coverGeneration = 0

    /**
     * The last book a cover was asked for, and when: an attempt rather than a
     * result. A cover that could not be fetched leaves nothing on disk to say
     * it was tried, and without this every publish asked again — and rewrote
     * the snapshot and reloaded the widget to make room for the answer.
     */
    private var coverAttempt: CoverAttempt? = null

    data class CoverAttempt(val bookId: String, val at: Instant)

    /** What one publish should do. */
    data class Plan(
        /** Write the snapshot and reload the widget. */
        val write: Boolean,
        /** Ask for the cover. */
        val fetchCover: Boolean,
    )

    /** Whether [clear]'s suspension is still in force. */
    val isSuspended: Boolean get() = suspended

    /**
     * Whether [candidate] may take the snapshot from whoever holds it. Audio
     * that is still playing outranks a book you are merely looking at;
     * anything else is last-touch-wins.
     */
    private fun mayPublish(candidate: Owner): Boolean {
        val owner = owner ?: return true
        if (owner == candidate) return true
        if (owner !is Owner.Listening || candidate !is Owner.Reading) return true
        val since = playingSince ?: return true
        return Duration.between(since, Instant.now()).toMillis() / 1000.0 > OWNERSHIP_LAPSE
    }

    fun publish(
        book: Book,
        session: Session?,
        progress: Double,
        chapter: String?,
        remaining: Double?,
        isPlaying: Boolean,
        candidate: Owner,
    ) {
        // The second lock, for any caller that forgets: `ReaderModel` does not
        // publish a local book either.
        if (book.isLocal) return
        if (suspended || !progress.isFinite() || !mayPublish(candidate)) return
        owner = candidate
        playingSince = if (isPlaying) Instant.now() else null

        val existing = CurrentBookSnapshotStore.read()
        val coverMatches = existing?.coverBookId == book.uuid
        val usableChapter = usableChapter(chapter, book.title)
        val plan = plan(existing, book.uuid, usableChapter, progress, isPlaying, coverAttempt, Instant.now())

        if (plan.write) {
            CurrentBookSnapshotStore.write(
                CurrentBookSnapshot(
                    bookId = book.uuid,
                    title = book.title,
                    author = book.byline,
                    chapter = usableChapter,
                    progress = progress,
                    remaining = remaining?.takeIf { it.isFinite() },
                    isPlaying = isPlaying,
                    coverBookId = if (coverMatches) book.uuid else null,
                    coverIsSquare = if (coverMatches) existing?.coverIsSquare ?: false else false,
                ),
            )
            reload()
        }

        if (plan.fetchCover) {
            // Recorded before the answer, so a publish made while the fetch is
            // in flight does not start a second one. A book with no session —
            // nothing to ask — counts as tried, for the same reason.
            coverAttempt = CoverAttempt(book.uuid, Instant.now())
            fetchCover(book, session)
        }
    }

    private fun fetchCover(book: Book, session: Session?) {
        session ?: return
        coverGeneration += 1
        val generation = coverGeneration
        val square = prefersSquareCover(book)
        scope.launch {
            val fetched = covers().widgetCover(
                book, session,
                if (square) LibraryService.CoverShape.SQUARE else LibraryService.CoverShape.PORTRAIT,
            )
            if (generation != coverGeneration || fetched == null) return@launch
            CurrentBookSnapshotStore.writeCoverOffMain(fetched.data)
            // Stamped onto whatever snapshot is current, and only if it is
            // still this book's.
            val snapshot = CurrentBookSnapshotStore.read() ?: return@launch
            if (snapshot.bookId != book.uuid) return@launch
            CurrentBookSnapshotStore.write(snapshot.copy(coverBookId = book.uuid, coverIsSquare = fetched.isSquare))
            // The snapshot was published before the art existed.
            reload()
        }
    }

    /** Forgets everything. Called on sign-out, where the snapshot, the cover and any fetch in flight go together. */
    fun clear() {
        owner = null
        playingSince = null
        coverGeneration += 1
        coverAttempt = null
        suspended = true
        CurrentBookSnapshotStore.clear()
        reload()
    }

    /** Lifts the suspension [clear] imposed: a session exists again. */
    fun resume() {
        suspended = false
    }

    companion object {
        /** How long a silent owner keeps its claim, in seconds. */
        private const val OWNERSHIP_LAPSE = 90.0

        /** The smallest move in whole-book progress worth a snapshot write. */
        private const val PROGRESS_WORTH_WRITING = 0.002

        /**
         * How long a cover that could not be fetched is left before it is
         * asked for again, in seconds: a request every few minutes for a
         * reader narrating offline rather than every page.
         */
        const val COVER_RETRY: Double = 10.0 * 60

        /**
         * The publish decision, apart from the files it reads and writes.
         * Written, and the widget reloaded, only when something it draws has
         * moved; the cover is asked for only when it has not landed and was not
         * tried recently. Keyed on the book alone, not the shape: when square
         * art does not exist the fetch falls back to portrait, and keying on
         * the shape never converged.
         */
        fun plan(
            existing: CurrentBookSnapshot?,
            bookId: String,
            chapter: String?,
            progress: Double,
            isPlaying: Boolean,
            lastAttempt: CoverAttempt?,
            now: Instant,
        ): Plan {
            val unchanged = existing?.let {
                it.bookId == bookId && it.chapter == chapter && it.isPlaying == isPlaying &&
                    abs(it.progress - progress) < PROGRESS_WORTH_WRITING
            } ?: false
            val coverMatches = existing?.coverBookId == bookId
            val triedRecently = lastAttempt?.let {
                it.bookId == bookId && Duration.between(it.at, now).toMillis() / 1000.0 < COVER_RETRY
            } ?: false
            return Plan(write = !unchanged, fetchCover = !coverMatches && !triedRecently)
        }

        /** A chapter that is only the book's title again, or blank, is not a chapter. */
        fun usableChapter(chapter: String?, title: String): String? {
            val trimmed = chapter?.trim() ?: return null
            if (trimmed.isEmpty() || trimmed == title) return null
            return trimmed
        }

        /**
         * Which art an audio surface should show. `servableFormats` rather
         * than a bare `!= null`: the server creates a read-along row when
         * alignment is merely requested, and asking for square art for a book
         * that has none is a 404.
         */
        fun prefersSquareCover(book: Book): Boolean = BookFormat.AUDIOBOOK in book.servableFormats
    }
}
