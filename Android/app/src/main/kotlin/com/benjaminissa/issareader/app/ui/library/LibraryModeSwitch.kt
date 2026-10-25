package com.benjaminissa.issareader.app.ui.library

import com.benjaminissa.issareader.app.model.AppModel
import com.benjaminissa.issareader.core.sync.LibraryArrangement

/**
 * The library's Browse / All books switch, as decisions: what the segment
 * reads, what is on screen and what a pick changes, from plain values a test
 * can ask. Swift wrote it for the Mac's toolbar; the phone uses its landing
 * rules for the Reading tab's links into the library.
 */
object LibraryModeSwitch {
    /** What the switch looks at: the library's mode and shelf, and whether a search is showing results. */
    data class State(
        val mode: AppModel.LibraryMode,
        val shelf: LibraryArrangement.Shelf,
        val isSearching: Boolean,
    )

    /**
     * Whether the content shows Browse's rails rather than the grid. Rails
     * only on All books: picking a shelf means "show me that cut of the
     * library", which is the grid; and search results are an answer, shown
     * whichever mode is on.
     */
    fun showsRails(state: State): Boolean =
        state.mode == AppModel.LibraryMode.BROWSE && state.shelf == LibraryArrangement.Shelf.ALL && !state.isSearching

    /** What the segment reads: All books whenever rails are not what is on screen. */
    fun shown(state: State): AppModel.LibraryMode = if (showsRails(state)) AppModel.LibraryMode.BROWSE else AppModel.LibraryMode.ALL

    /**
     * What picking a segment leaves the library as. Browse is the rails, from
     * wherever the library is: All books, nothing searched. All books writes
     * the mode and nothing else: the grid keeps its shelf, sort and tags, and
     * a search keeps its results.
     */
    fun picking(mode: AppModel.LibraryMode, state: State): State = when (mode) {
        AppModel.LibraryMode.BROWSE -> State(AppModel.LibraryMode.BROWSE, LibraryArrangement.Shelf.ALL, isSearching = false)
        AppModel.LibraryMode.ALL -> State(AppModel.LibraryMode.ALL, state.shelf, state.isSearching)
    }

    /** Where a segment picked on a page pushed over the library lands: the library's All books, nothing searched. */
    fun fromPage(picked: AppModel.LibraryMode): State = State(picked, LibraryArrangement.Shelf.ALL, isSearching = false)

    /**
     * Where the Reading screen's links into the library land. A "See all"
     * names a shelf and means that shelf's flat grid; the empty screen's "Go
     * to Library" names none and means the library's landing: Browse's rails
     * on All books, with nothing searched.
     */
    fun fromReading(shelf: LibraryArrangement.Shelf?): State =
        if (shelf != null) {
            State(AppModel.LibraryMode.ALL, shelf, isSearching = false)
        } else {
            State(AppModel.LibraryMode.BROWSE, LibraryArrangement.Shelf.ALL, isSearching = false)
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
        showAllBooks(shelf = landing.shelf)
    } else {
        arrangement = arrangement.copy(shelf = landing.shelf)
        libraryMode = landing.mode
    }
}
