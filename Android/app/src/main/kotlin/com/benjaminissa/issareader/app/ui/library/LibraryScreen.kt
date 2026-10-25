package com.benjaminissa.issareader.app.ui.library

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import com.benjaminissa.issareader.app.model.AppModel
import com.benjaminissa.issareader.app.ui.book.BookGridItem
import com.benjaminissa.issareader.app.ui.book.BookRoutes
import com.benjaminissa.issareader.app.ui.book.CoverGrid
import com.benjaminissa.issareader.app.ui.shell.LargeTitleScreen
import com.benjaminissa.issareader.app.ui.shell.LoadingOverlay
import com.benjaminissa.issareader.app.ui.shell.LocalLibraryNavigator
import com.benjaminissa.issareader.app.ui.shell.Refreshable
import com.benjaminissa.issareader.app.ui.shell.appModel
import com.benjaminissa.issareader.core.download.BookMenu
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.sync.LibraryArrangement
import com.benjaminissa.issareader.ui.Metrics
import com.benjaminissa.issareader.ui.PalettePlaceholder
import com.benjaminissa.issareader.ui.Symbols
import kotlinx.coroutines.launch

/**
 * The Library tab: the header that owns search and the Browse / shelf chips,
 * then Browse's rails or the flat grid. Swift's `LibraryView`.
 *
 * The header is a sibling of the scrolling content, not its first item: a
 * child would scroll away, and its height never depends on anything that
 * loads. Search results are the answer to a question and are shown whichever
 * mode is on; only an idle Browse gets rails.
 */
@Composable
fun LibraryScreen() {
    val app = appModel
    var search by rememberSaveable { mutableStateOf("") }
    var results by remember { mutableStateOf<List<Book>>(emptyList()) }
    val navigator = LocalLibraryNavigator.current

    // An author page's "Show in Library" is a search: the library has no
    // author filter, and its search already looks through authors. Taken as
    // the screen appears and as it changes.
    LaunchedEffect(navigator) {
        val navigator = navigator ?: return@LaunchedEffect
        snapshotFlow { navigator.showRequests to navigator.pendingSearch }.collect {
            val pending = navigator.pendingSearch
            if (pending != null) {
                search = pending
                navigator.pendingSearch = null
            }
        }
    }
    // Full-text, from the local index: the server's book endpoint takes no
    // query parameters, so search has to happen here either way.
    LaunchedEffect(search) {
        results = if (search.isEmpty()) emptyList() else app.search(search)
    }
    // Search results are already the answer to a question; re-sorting them
    // would bury the best match. The arrangement applies to the shelf only.
    val books = if (search.isEmpty()) app.arrangedBooks else results

    BookRoutes(place = BookMenu.Place.Shelf) {
        LargeTitleScreen("Library", Modifier.testTag("screen.library")) { padding ->
            Column(Modifier.padding(padding).fillMaxSize().testTag("content.library")) {
                LibraryHeader(search = search, onSearchChange = { search = it }, displayedCount = books.size, isSearching = search.isNotEmpty())
                Refreshable(onRefresh = { app.refreshLibrary() }, modifier = Modifier.weight(1f)) {
                    if (app.libraryMode == AppModel.LibraryMode.BROWSE && search.isEmpty()) {
                        BrowseList()
                    } else {
                        Shelf(books, search)
                    }
                    LibraryStates(app)
                }
            }
        }
    }
}

/** What the screen says over an empty library: loading, a failure with its reason, or nothing yet. */
@Composable
private fun LibraryStates(app: AppModel) {
    when {
        app.books.isEmpty() && app.isLoadingLibrary -> LoadingOverlay()
        // A failed fetch is not an empty library, and "no books" for a decode
        // error sends you looking in entirely the wrong place.
        app.books.isEmpty() && app.loadError != null -> CenteredPlaceholder {
            val scope = rememberCoroutineScope()
            PalettePlaceholder(
                symbol = Symbols.exclamationmarkTriangle,
                title = "Couldn't load your library",
                message = app.loadError ?: "",
                actionTitle = "Try again",
                action = { scope.launch { app.refreshLibrary() } },
            )
        }
        app.books.isEmpty() -> CenteredPlaceholder {
            PalettePlaceholder(
                symbol = Symbols.booksVertical,
                title = "No books yet",
                message = "Add books to your Storyteller server and they'll appear here.",
            )
        }
    }
}

@Composable
internal fun CenteredPlaceholder(content: @Composable () -> Unit) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { content() }
}

/** Browse's rails, in a scroll of their own, edge to edge. */
@Composable
private fun BrowseList() {
    val app = appModel
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(vertical = Metrics.screenMargin),
        verticalArrangement = Arrangement.spacedBy(Metrics.spacing32),
    ) {
        browseRails(app)
    }
}

/**
 * The flat grid, or what an empty shelf says. A shelf is one tap away, so
 * readers land on an empty one far more often than by accident, and it
 * offers the way back out.
 */
@Composable
private fun Shelf(books: List<Book>, search: String) {
    val app = appModel
    if (books.isEmpty() && search.isEmpty() && app.arrangement.isFiltering) {
        CenteredPlaceholder {
            EmptyShelfView(shelf = app.arrangement.shelf.title) { app.showAllBooks(shelf = LibraryArrangement.Shelf.ALL) }
        }
        return
    }
    LazyVerticalGrid(
        columns = CoverGrid.cells,
        modifier = Modifier.fillMaxSize().testTag("grid.library"),
        contentPadding = PaddingValues(Metrics.screenMargin),
        horizontalArrangement = Arrangement.spacedBy(CoverGrid.columnSpacing, Alignment.Start),
        verticalArrangement = Arrangement.spacedBy(CoverGrid.rowSpacing),
    ) {
        items(books, key = { it.uuid }) { book -> BookGridItem(book) }
    }
}

/** What a shelf with nothing on it says, and the way back to every book. */
@Composable
fun EmptyShelfView(shelf: String, showAll: () -> Unit) {
    PalettePlaceholder(
        symbol = Symbols.booksVertical,
        title = "Nothing on $shelf",
        message = "No books match this shelf right now.",
        actionTitle = "Show all books",
        action = showAll,
    )
}
