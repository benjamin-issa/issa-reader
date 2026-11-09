package com.benjaminissa.issareader.app.model

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.Tag
import com.benjaminissa.issareader.core.sync.LibraryArrangement
import com.benjaminissa.issareader.core.sync.LibraryRails
import java.util.UUID

/**
 * Where a book's menu sends the reader, on the screen the menu was opened on.
 *
 * One per screen. A menu item's navigation has to be imperative, and the
 * obvious imperative route — `AppModel.requestBook` — is the deep-link inbox,
 * which empties the tab's back stack before it pushes; a destination declared
 * on the screen itself pushes on top of that screen and keeps the stack, which
 * is what a reader expects of a menu. The screens own the navigation; this
 * owns what was asked for.
 */
class BookRouter {
    sealed interface Route {
        data class Details(val book: Book) : Route
        data class Series(val name: String) : Route
        data class Author(val name: String) : Route
        data class Tag(val name: String) : Route
    }

    /** The screen to push on top of this one. */
    var route: Route? by mutableStateOf(null)

    /** The full player, for "Now Playing". */
    var showsPlayer: Boolean by mutableStateOf(false)

    /** Something a menu item tried and could not do. */
    var alert: BookAlert? by mutableStateOf(null)

    companion object {
        /**
         * Whether a deep link takes down the page this router pushed: yes, so
         * the tab's own reset can push the link's book — except for a link to
         * the book whose reader is already up, which the tab discards rather
         * than resetting, and whose reader may be on a page this router pushed.
         */
        fun dropsPushedPage(pending: String?, visibleReader: String?): Boolean {
            pending ?: return false
            return pending != visibleReader
        }
    }
}

/**
 * A failure worth telling the reader about: a Listen that could not start, a
 * download the Wi-Fi rule held back. Said in an alert because the menu that
 * asked for it has already closed.
 */
data class BookAlert(val title: String, val message: String, val id: String = UUID.randomUUID().toString())

/**
 * A request to show the library's own grid, made from a page that cannot get
 * there by itself: "Show in Library" on a tag or author page. One per window,
 * owned by its root.
 */
class LibraryNavigator {
    /** Bumped by each request; the root goes to the library grid. */
    var showRequests: Int by mutableIntStateOf(0)
        private set

    /** A search for the library to run when it next appears, for an author's "Show in Library". */
    var pendingSearch: String? by mutableStateOf(null)

    fun showLibrary(search: String? = null) {
        pendingSearch = search
        showRequests += 1
    }
}

/**
 * The library's Browse / All Books switch, as decisions from plain values,
 * so a screen and a test ask the same thing. (Swift's `LibraryModeSwitch`.)
 */
object LibraryModeSwitch {
    /** What the switch looks at: the library's mode and shelf, and whether a search is showing results. */
    data class State(val mode: AppModel.LibraryMode, val shelf: LibraryArrangement.Shelf, val isSearching: Boolean)

    /** Whether the content shows Browse's rails rather than the grid: rails only on All books, with nothing searched. */
    fun showsRails(state: State): Boolean =
        state.mode == AppModel.LibraryMode.BROWSE && state.shelf == LibraryArrangement.Shelf.ALL && !state.isSearching

    /** What the segment reads: "All Books" whenever rails are not what is on screen. */
    fun shown(state: State): AppModel.LibraryMode = if (showsRails(state)) AppModel.LibraryMode.BROWSE else AppModel.LibraryMode.ALL

    /**
     * What picking a segment leaves the library as. Browse is the rails, from
     * wherever the library is; All Books writes the mode and nothing else.
     */
    fun picking(mode: AppModel.LibraryMode, state: State): State = when (mode) {
        AppModel.LibraryMode.BROWSE -> State(AppModel.LibraryMode.BROWSE, LibraryArrangement.Shelf.ALL, false)
        AppModel.LibraryMode.ALL -> State(AppModel.LibraryMode.ALL, state.shelf, state.isSearching)
    }

    /** Where a segment picked on a page pushed over the library lands: its All books, nothing searched. */
    fun fromPage(picked: AppModel.LibraryMode): State = State(picked, LibraryArrangement.Shelf.ALL, false)

    /**
     * Where the Reading screen's links into the library land. A "See all"
     * names a shelf and means that shelf's flat grid; "Go to Library" names
     * none and means the landing: Browse's rails on All books.
     */
    fun fromReading(shelf: LibraryArrangement.Shelf?): State =
        if (shelf != null) {
            State(AppModel.LibraryMode.ALL, shelf, false)
        } else {
            State(AppModel.LibraryMode.BROWSE, LibraryArrangement.Shelf.ALL, false)
        }
}

/**
 * Puts the library where [LibraryModeSwitch.fromReading] says a link from the
 * Reading screen lands. The caller shows the library from its root, so no
 * search or pushed page is left over it.
 */
fun AppModel.showLibrary(fromReading: LibraryArrangement.Shelf?) {
    val landing = LibraryModeSwitch.fromReading(fromReading)
    if (landing.mode == AppModel.LibraryMode.ALL) {
        showAllBooks(landing.shelf)
    } else {
        arrangement = arrangement.copy(shelf = landing.shelf)
        libraryMode = landing.mode
    }
}

/** What a book page's tag chips link to, decided from the catalogue. */
object BookLinks {
    /** Whether a chip links: only for a tag on two books or more, counted once each. */
    fun isLinked(name: String, booksByTag: Map<String, List<Book>>): Boolean =
        (booksByTag[name]?.size ?: 0) >= LibraryRails.minimumBooksPerTag

    /** The first linked chip, which carries the identifier a test or a screen reader finds. */
    fun firstLinkedTagId(tags: List<Tag>, booksByTag: Map<String, List<Book>>): String? =
        tags.firstOrNull { isLinked(it.name, booksByTag) }?.id
}

