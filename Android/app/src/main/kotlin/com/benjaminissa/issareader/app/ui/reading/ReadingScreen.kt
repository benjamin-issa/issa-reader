package com.benjaminissa.issareader.app.ui.reading

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.benjaminissa.issareader.app.model.AppModel
import com.benjaminissa.issareader.app.ui.book.BookCover
import com.benjaminissa.issareader.app.ui.book.BookMenuBox
import com.benjaminissa.issareader.app.ui.book.BookRail
import com.benjaminissa.issareader.app.ui.book.BookRoutes
import com.benjaminissa.issareader.app.ui.downloads.DownloadsPlacement
import com.benjaminissa.issareader.app.ui.downloads.downloadsSection
import com.benjaminissa.issareader.app.ui.downloads.rememberDownloadsSectionState
import com.benjaminissa.issareader.app.ui.shell.BookDetailRoute
import com.benjaminissa.issareader.app.ui.shell.LargeTitleScreen
import com.benjaminissa.issareader.app.ui.shell.LoadingOverlay
import com.benjaminissa.issareader.app.ui.shell.LocalShellActions
import com.benjaminissa.issareader.app.ui.shell.LocalTabNavigator
import com.benjaminissa.issareader.app.ui.shell.Refreshable
import com.benjaminissa.issareader.app.ui.shell.appModel
import com.benjaminissa.issareader.app.ui.shell.bleed
import com.benjaminissa.issareader.core.download.BookMenu
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.ReadingProgress
import com.benjaminissa.issareader.core.sync.LibraryArrangement
import com.benjaminissa.issareader.ui.ContinueCard
import com.benjaminissa.issareader.ui.Metrics
import com.benjaminissa.issareader.ui.Overline
import com.benjaminissa.issareader.ui.PalettePlaceholder
import com.benjaminissa.issareader.ui.ResumeRow
import com.benjaminissa.issareader.ui.Symbols

/**
 * The Reading tab: everything you are actually reading, in one place. The
 * Continue card leads, the other books in progress stack beneath it, the
 * To-read queue is a rail, and what is on this device closes the screen.
 * Every list is `ReadingHome`, derived in the model — nothing here decides
 * what is shown. Swift's `ReadingView`.
 *
 * Switching tabs is not this screen's to do: a "See all" asks the shell for
 * the library's flat grid on that shelf, "Go to Library" for its landing.
 */
@Composable
fun ReadingScreen() {
    val app = appModel
    val shell = LocalShellActions.current
    val home = app.readingHome
    val downloads = rememberDownloadsSectionState(DownloadsPlacement.READING)
    BookRoutes(place = BookMenu.Place.Shelf) {
        LargeTitleScreen("Reading", Modifier.testTag("screen.reading")) { padding ->
            Refreshable(onRefresh = { app.refreshLibrary() }, modifier = Modifier.padding(padding).fillMaxSize()) {
                // The screen's margin is the list's; a rail bleeds back out to
                // the edges, and each block keeps its own gap above it, so the
                // Downloaded section's rows can sit closer together.
                LazyColumn(
                    modifier = Modifier.fillMaxSize().testTag("content.reading"),
                    contentPadding = PaddingValues(Metrics.screenMargin),
                ) {
                    // A first item that is always there: the list keeps its place by
                    // the first visible item, and the blocks above the downloads
                    // arrive after them, as the library loads.
                    item(key = "top") {}
                    var gap = 0.dp
                    home.hero?.let { hero ->
                        item(key = "continue") { ContinueCardLink(hero) }
                        gap = Metrics.spacing24
                    }
                    if (home.alsoReading.isNotEmpty()) {
                        val top = gap
                        item(key = "also") { AlsoReading(home.alsoReading, Modifier.padding(top = top)) }
                        gap = Metrics.spacing24
                    }
                    if (home.upNext.isNotEmpty()) {
                        val top = gap
                        item(key = "upNext") {
                            // Smaller covers than a Browse rail's, so the tab
                            // stays about the book being read.
                            BookRail("Up next · To read", home.upNext, Modifier.padding(top = top).bleed(), coverWidth = 64.dp) {
                                shell.showLibrary(fromReading = LibraryArrangement.Shelf.TO_READ)
                            }
                        }
                        gap = Metrics.spacing24
                    }
                    // What is on this device, under the queue. "Show all" goes
                    // to the Downloaded shelf the library already has.
                    val downloadsGap = gap
                    item(key = "downloads.gap") { Spacer(Modifier.height(downloadsGap)) }
                    downloadsSection(downloads, DownloadsPlacement.READING) {
                        shell.showLibrary(fromReading = LibraryArrangement.Shelf.DOWNLOADED)
                    }
                }
                ReadingStates(app, home.isEmpty) { shell.showLibrary(fromReading = null) }
            }
        }
    }
}

@Composable
private fun ReadingStates(app: AppModel, isEmpty: Boolean, goToLibrary: () -> Unit) {
    if (app.books.isEmpty() && app.isLoadingLibrary) {
        LoadingOverlay()
    } else if (isEmpty) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            PalettePlaceholder(
                symbol = Symbols.bookmark,
                title = "Nothing in progress",
                message = "Pick something from your Library and it will be waiting here.",
                actionTitle = "Go to Library",
                action = goToLibrary,
            )
        }
    }
}

/**
 * The lead card: the body resumes reading the way the widget does —
 * `requestBook(.read)` leaves the book in the pending inbox and the shell
 * presents the reader at the saved position — while the chevron opens the
 * book's page. Signed out, it is a plain visual.
 */
@Composable
fun ContinueCardLink(book: Book, modifier: Modifier = Modifier) {
    val app = appModel
    val navigator = LocalTabNavigator.current
    if (app.session == null) {
        ContinueCard({ BookCover(book) }, book.title, book.byline, book.progress, onResume = null, onDetails = null, modifier = modifier)
        return
    }
    // Exists only once the library has arrived and something is in progress,
    // which is what a test of this screen waits on.
    BookMenuBox(book, modifier.testTag("card.continue")) { openMenu ->
        ContinueCard(
            cover = { BookCover(book) },
            title = book.title,
            byline = book.byline,
            progress = book.progress,
            onResume = { app.requestBook(book.uuid, AppModel.PendingBook.Destination.READ) },
            onDetails = { navigator.push(BookDetailRoute(book.uuid)) },
            onLongClick = openMenu,
        )
    }
}

/** Every other book in progress, compact, one tap to resume. Left out when the Continue book is the only one. */
@Composable
private fun AlsoReading(books: List<Book>, modifier: Modifier = Modifier) {
    val app = appModel
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(Metrics.spacing8)) {
        Overline("Also reading")
        for (book in books) {
            BookMenuBox(book) { openMenu ->
                ResumeRow(
                    cover = { BookCover(book, Modifier.width(38.dp)) },
                    title = book.title,
                    progress = book.progress,
                    onClick = { if (app.session != null) app.requestBook(book.uuid, AppModel.PendingBook.Destination.READ) },
                    onLongClick = openMenu,
                    modifier = Modifier.semantics { contentDescription = resumeLabel(book) },
                )
            }
        }
    }
}

/** What a screen reader says for a row that resumes a book. */
fun resumeLabel(book: Book): String {
    val progress = book.progress
    if (progress == null || progress <= 0) return "Resume ${book.title}"
    return "Resume ${book.title}, ${ReadingProgress.percent(progress)}% complete"
}
