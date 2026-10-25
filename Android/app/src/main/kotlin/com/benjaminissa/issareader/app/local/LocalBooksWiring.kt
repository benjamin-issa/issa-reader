package com.benjaminissa.issareader.app.local

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.benjaminissa.issareader.app.model.AppModel
import com.benjaminissa.issareader.app.model.BookIndexes
import com.benjaminissa.issareader.app.model.PlaybackSettings
import com.benjaminissa.issareader.core.KeyValueStore
import com.benjaminissa.issareader.core.model.Book
import androidx.compose.runtime.snapshotFlow
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.launch

/**
 * Hands the local library to the objects that keep state per book.
 *
 * An account's exit keeps these books' state (`AppModel.localBookUuids`), a
 * book leaving the list lets its reader go at once, and one that is gone for
 * good takes its question index, reader style and level with it.
 */
object LocalBooksWiring {
    /**
     * @param ask the question machinery, when it has been handed over (the
     *   Ask port's); null until then.
     * @param afterLoad run once the library has loaded.
     */
    fun connect(
        app: AppModel,
        local: LocalLibrary,
        settings: PlaybackSettings,
        ask: BookIndexes?,
        scope: CoroutineScope = app.scope,
        afterLoad: (LocalLibrary) -> Unit = {},
    ) {
        app.localBookUuids = { local.uuids }
        local.onRemove = { uuid -> app.releaseLocalBook(uuid) }
        local.onForget = { uuid ->
            (ask ?: app.ask)?.remove(uuid)
            settings.forgetBook(uuid)
        }
        val loading = scope.launch { local.load() }
        // And the exit waits for it before it reads them: a book whose folder
        // a backup did not bring back is known only to the store.
        app.localBooksLoaded = { loading.join() }
        scope.launch {
            loading.join()
            afterLoad(local)
        }
    }
}

/**
 * Where one window is in the local books' flow: which book's reader is
 * presented over it, and whether the list stands in for the sign-in form
 * while no server is connected — remembered, so a reader with no server
 * lands on their books on every launch.
 */
class LocalBooksRoute(private val defaults: KeyValueStore) {
    /** The book whose reader is presented over this window, if any, by uuid. */
    var openBook: String? by mutableStateOf(null)

    private var showsListState by mutableStateOf(defaults.getBoolean(SHOWS_LIST_KEY))

    var showsListSignedOut: Boolean
        get() = showsListState
        set(value) {
            showsListState = value
            defaults.putBoolean(SHOWS_LIST_KEY, value)
        }

    fun open(uuid: String) {
        openBook = uuid
    }

    /**
     * Takes the app's pending book — a deep link, a launcher shortcut, the
     * widget — for this window's library to push, by the root's rules. A link
     * to the book whose reader is already up is dropped rather than consumed:
     * consuming arms the one-shot reader request, and one armed for a book
     * already on screen re-presented the reader the next time its page
     * appeared. And a book from the reader's files open over this window
     * closes, so the server book is not pushed underneath it where nothing
     * can be seen.
     *
     * @return the book and where it goes, or null when there is nothing to push.
     */
    fun takePendingBook(app: AppModel): Pair<Book, AppModel.PendingBook.Destination>? {
        val pending = app.pendingBook ?: return null
        if (app.visibleReaderUuid == pending.uuid) {
            app.discardPendingBook()
            return null
        }
        val taken = app.consumePendingBook() ?: return null
        if (openBook != null) openBook = null
        return taken
    }

    /**
     * The library has loaded, at launch: a launch that finds the list empty
     * opens on sign-in, whatever was remembered.
     */
    fun libraryLoaded(hasBooks: Boolean) {
        if (!hasBooks) showsListSignedOut = false
    }

    /**
     * The app's phase moved. Signed in, the list is a row in Settings; signed
     * out, the books are where the app opens if there are any.
     */
    fun phaseChanged(old: AppModel.Phase, new: AppModel.Phase, hasBooks: Boolean) {
        when {
            new == AppModel.Phase.READY -> showsListSignedOut = false
            new == AppModel.Phase.CHOOSE_SERVER && old == AppModel.Phase.READY -> showsListSignedOut = hasBooks
        }
    }

    /**
     * What the root view does with this route, without the view: the list is
     * the root by [libraryLoaded]'s and [phaseChanged]'s rules, and a book
     * removed while its reader is open takes the reader with it — as soon as
     * it leaves the list, not when its undo runs out.
     *
     * @return the job to cancel when the window goes.
     */
    fun observe(app: AppModel, local: LocalLibrary, scope: CoroutineScope): Job = scope.launch {
        launch {
            snapshotFlow { local.isLoaded }.filter { it }.collect { libraryLoaded(local.hasAnything) }
        }
        launch {
            var old = app.phase
            snapshotFlow { app.phase }.collect { new ->
                if (new != old) phaseChanged(old, new, local.hasAnything)
                old = new
            }
        }
        launch {
            snapshotFlow { openBook?.let { uuid -> local.book(uuid) == null } ?: false }
                .collect { gone -> if (gone) openBook = null }
        }
    }

    companion object {
        const val SHOWS_LIST_KEY = "issa.local.showsListSignedOut"
    }
}
