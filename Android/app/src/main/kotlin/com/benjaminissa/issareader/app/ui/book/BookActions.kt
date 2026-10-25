package com.benjaminissa.issareader.app.ui.book

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import com.benjaminissa.issareader.app.model.AppModel
import com.benjaminissa.issareader.app.model.BookAlert
import com.benjaminissa.issareader.app.model.BookRouter
import com.benjaminissa.issareader.app.model.NowPlayingController
import com.benjaminissa.issareader.app.model.PlaybackSettings
import com.benjaminissa.issareader.app.ui.shell.LocalAppEnvironment
import com.benjaminissa.issareader.core.download.BookContentService
import com.benjaminissa.issareader.core.download.BookMenu
import com.benjaminissa.issareader.core.download.DownloadManager
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.Status
import com.benjaminissa.issareader.ui.Symbols
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

/**
 * What a book's menu does, with everything it needs read from the screen it
 * was opened on: Swift's `BookActions`.
 *
 * The app model's main scope runs the work a menu item starts, as Swift's
 * unstructured `Task` does, so it outlives the menu that asked.
 */
class BookActions(
    val app: AppModel,
    private val router: BookRouter?,
    private val nowPlaying: NowPlayingController,
    private val settings: PlaybackSettings,
    private val place: BookMenu.Place,
    private val scope: CoroutineScope,
) {
    val capabilities: BookMenu.Capabilities get() = BookMenu.Capabilities.ALL

    /** "View details": a phone has a book screen for every book. */
    val detailsTitle: String get() = "View details"

    /**
     * Everything the menu depends on besides the book. The disk is asked only
     * for a book the downloads set already names.
     */
    fun inputs(book: Book, focusEdition: BookContentService.Format?): BookMenu.Inputs {
        val downloaded = if (book.uuid in app.downloadedUuids) {
            BookContentService.Format.entries.filter { app.isDownloaded(book, it) }.toSet()
        } else {
            emptySet()
        }
        val states = mutableMapOf<BookContentService.Format, DownloadManager.State>()
        app.downloads?.let { downloads ->
            for (format in BookContentService.Format.entries) {
                downloads.state(DownloadManager.Job(book.uuid, format))?.let { states[format] = it }
            }
        }
        val grouped = book.primarySeries?.let { membership ->
            if (app.rails.series.any { it.name == membership.name }) setOf(membership.name) else emptySet()
        } ?: emptySet()
        // Distinct books, not entries: a catalogue can name an author twice
        // on one book, and that is still one book.
        val byAuthor = book.authors.firstOrNull()?.let { author ->
            (app.booksByAuthor[author.name] ?: emptyList()).map { it.uuid }.toSet().size
        } ?: 0
        return BookMenu.Inputs(
            isSignedIn = app.session != null,
            statuses = app.statuses,
            rating = app.ratings[book.uuid],
            isPlaying = app.playbackBook?.uuid == book.uuid,
            downloadedFormats = downloaded,
            downloadStates = states,
            groupedSeries = grouped,
            firstAuthorBookCount = byAuthor,
            place = place,
            focusEdition = focusEdition,
            capabilities = capabilities,
        )
    }

    // Opening

    fun viewDetails(book: Book) {
        if (router != null) {
            router.route = BookRouter.Route.Details(book)
        } else {
            app.requestBook(book.uuid, AppModel.PendingBook.Destination.DETAILS)
        }
    }

    /**
     * The book's page, pushed on top of this screen, opening the reader as it
     * appears: Back from the reader lands on the book and then here. The
     * deep-link inbox would have done the same by emptying the tab.
     */
    fun read(book: Book) {
        if (router != null && app.requestReader(book)) {
            router.route = BookRouter.Route.Details(book)
        } else {
            app.requestBook(book.uuid, AppModel.PendingBook.Destination.READ)
        }
    }

    /** Starts the audio. On the phone the mini player appearing is the transport. */
    fun listen(book: Book) {
        scope.launch {
            app.startListening(book, nowPlaying, settings)
            val error = app.listeningError
            if (error != null) router?.alert = BookAlert(title = "Couldn't play ${book.title}", message = error)
        }
    }

    fun showPlayer() {
        router?.showsPlayer = true
    }

    // Status and rating

    fun setStatus(status: Status, book: Book) {
        scope.launch { app.setStatus(status, book) }
    }

    fun setRating(stars: Int?, book: Book) {
        scope.launch { app.setRating(stars?.toDouble(), book) }
    }

    // Going somewhere

    fun push(route: BookRouter.Route) {
        router?.route = route
    }

    // Editions

    fun perform(action: BookMenu.EditionAction, book: Book) {
        val job = DownloadManager.Job(book.uuid, action.format)
        when (action.kind) {
            BookMenu.EditionAction.Kind.SAVE, BookMenu.EditionAction.Kind.RETRY, BookMenu.EditionAction.Kind.RESUME -> scope.launch {
                // The menu has closed, so a refusal is said here.
                startDownload(action.kind, book, action.format, app)?.let { router?.alert = it }
            }
            BookMenu.EditionAction.Kind.PAUSE -> app.downloads?.pause(job)
            BookMenu.EditionAction.Kind.REMOVE -> remove(book, action.format)
        }
    }

    /** The removal every Downloads row makes: hidden now, deleted when the undo window closes. */
    fun remove(book: Book, format: BookContentService.Format) {
        app.removeDownload(book.uuid, format, book.title)
    }

    companion object {
        /**
         * Saves, retries or resumes an edition, and says what the reader has
         * to be told: the Wi-Fi rule's reason when it held the download back.
         * Resume included, so a held-back resume is not silently ignored.
         */
        suspend fun startDownload(
            kind: BookMenu.EditionAction.Kind,
            book: Book,
            format: BookContentService.Format,
            app: AppModel,
        ): BookAlert? {
            val job = DownloadManager.Job(book.uuid, format)
            val started = when (kind) {
                BookMenu.EditionAction.Kind.RESUME -> {
                    app.resumeDownload(job)
                    app.downloadRefusals[job] == null
                }
                BookMenu.EditionAction.Kind.SAVE, BookMenu.EditionAction.Kind.RETRY -> app.download(book, format)
                BookMenu.EditionAction.Kind.PAUSE, BookMenu.EditionAction.Kind.REMOVE -> return null
            }
            if (started) return null
            return BookAlert(title = "Not downloaded yet", message = app.downloadRefusals[job] ?: "The download could not start.")
        }

        /** The icon for an edition action's SF Symbol. */
        fun symbol(action: BookMenu.EditionAction): Int = when (action.kind) {
            BookMenu.EditionAction.Kind.SAVE -> Symbols.arrowDownCircle
            BookMenu.EditionAction.Kind.PAUSE -> Symbols.pauseCircle
            BookMenu.EditionAction.Kind.RESUME -> Symbols.playCircle
            BookMenu.EditionAction.Kind.RETRY -> Symbols.arrowClockwise
            BookMenu.EditionAction.Kind.REMOVE -> Symbols.trash
        }
    }
}

/** This screen's [BookActions]. */
@Composable
fun rememberBookActions(): BookActions {
    val environment = LocalAppEnvironment.current
    val router = LocalBookRouter.current
    val place = LocalBookPlace.current
    val scope = environment.app.scope
    return remember(environment, router, place) {
        BookActions(environment.app, router, environment.nowPlaying, environment.settings, place, scope)
    }
}
