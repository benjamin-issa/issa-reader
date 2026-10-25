package com.benjaminissa.issareader.app.model

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.benjaminissa.issareader.core.model.Book
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
