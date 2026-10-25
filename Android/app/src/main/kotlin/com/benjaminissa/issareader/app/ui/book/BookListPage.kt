package com.benjaminissa.issareader.app.ui.book

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInParent
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.benjaminissa.issareader.app.ui.shell.LocalLibraryNavigator
import com.benjaminissa.issareader.app.ui.shell.LocalTabNavigator
import com.benjaminissa.issareader.app.ui.shell.PushedScreen
import com.benjaminissa.issareader.app.ui.shell.Refreshable
import com.benjaminissa.issareader.app.ui.shell.appModel
import com.benjaminissa.issareader.core.download.BookMenu
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.sync.LibraryArrangement
import com.benjaminissa.issareader.core.sync.StagedBooks
import com.benjaminissa.issareader.ui.InlineTitleBar
import com.benjaminissa.issareader.ui.Metrics
import com.benjaminissa.issareader.ui.Overline
import com.benjaminissa.issareader.ui.Palette
import com.benjaminissa.issareader.ui.PalettePlaceholder
import com.benjaminissa.issareader.ui.Symbols
import com.benjaminissa.issareader.ui.Typography

/** Every book carrying one tag, reached from a tag chip on a book's page. Swift's `TagView`. */
@Composable
fun TagScreen(name: String) {
    val app = appModel
    // The memoised grouping for which books, each resolved through the index
    // a position moves, so progress and recency stay live.
    BookListPage(BookListSubject.Tag(name), (app.booksByTag[name] ?: emptyList()).map { app.bookByUuid[it.uuid] ?: it })
}

/** "More by ‹author›": every book by one author, from a book's menu. Swift's `AuthorView`. */
@Composable
fun AuthorScreen(name: String) {
    val app = appModel
    BookListPage(BookListSubject.Author(name), (app.booksByAuthor[name] ?: emptyList()).map { app.bookByUuid[it.uuid] ?: it })
}

/** What a list page is about: a tag or an author. */
sealed interface BookListSubject {
    val name: String

    /** What a screen reader calls the subject after its name. */
    val kind: String

    val place: BookMenu.Place

    data class Tag(override val name: String) : BookListSubject {
        override val kind: String get() = "tag"
        override val place: BookMenu.Place get() = BookMenu.Place.Tag(name)
    }

    data class Author(override val name: String) : BookListSubject {
        override val kind: String get() = "author"
        override val place: BookMenu.Place get() = BookMenu.Place.Author(name)
    }
}

/** Whether the content has scrolled far enough for the header's name to be under the bar. */
fun hasScrolledPast(nameBottom: Int, offset: Int): Boolean = offset >= nameBottom

/**
 * The page a tag and an author share: the name set large, one summary line,
 * and the books grouped by reading stage. A focused cut of the library rather
 * than a second library: no sort control, and "Show in Library" for
 * everything the full grid can do. Swift's `BookListPage`.
 *
 * The bar's title stays out of the way while the header says the same name
 * beneath it, and fades in once that has scrolled under the bar.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BookListPage(subject: BookListSubject, books: List<Book>) {
    val app = appModel
    val navigator = LocalTabNavigator.current
    val libraryNavigator = LocalLibraryNavigator.current
    // Rebuilt only when its inputs change, not on every composition.
    val staged = remember(books, app.statuses) { StagedBooks(books, app.statuses) }
    val scroll = rememberScrollState()
    var nameBottom by remember { mutableIntStateOf(Int.MAX_VALUE) }
    val nameScrolledAway by remember { derivedStateOf { hasScrolledPast(nameBottom, scroll.value) } }
    val titleAlpha by animateFloatAsState(if (staged.isEmpty || nameScrolledAway) 1f else 0f, tween(200), label = "title")

    val showInLibrary: () -> Unit = {
        when (subject) {
            is BookListSubject.Tag -> {
                app.showAllBooks(shelf = LibraryArrangement.Shelf.ALL, tags = setOf(subject.name))
                libraryNavigator?.showLibrary()
            }
            is BookListSubject.Author -> {
                app.showAllBooks(shelf = LibraryArrangement.Shelf.ALL)
                libraryNavigator?.showLibrary(search = subject.name)
            }
        }
    }

    BookRoutes(place = subject.place) {
        PushedScreen(
            subject.name,
            Modifier.testTag("screen.${subject.kind}"),
            topBar = { InlineTitleBar(subject.name, onBack = { navigator.back() }, titleAlpha = titleAlpha) },
        ) { padding ->
            Refreshable(onRefresh = { app.refreshLibrary() }, modifier = Modifier.padding(padding).fillMaxSize()) {
                if (staged.isEmpty) {
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { EmptyState(subject) }
                    return@Refreshable
                }
                Column(
                    Modifier
                        .fillMaxSize()
                        .verticalScroll(scroll)
                        .testTag("content.${subject.kind}")
                        .padding(start = Metrics.screenMargin, end = Metrics.screenMargin, bottom = Metrics.screenMargin),
                ) {
                    Header(subject, staged, showInLibrary, onNameBottom = { nameBottom = it })
                    Column(Modifier.padding(top = Metrics.spacing8), verticalArrangement = Arrangement.spacedBy(Metrics.spacing32)) {
                        for (section in staged.sections) {
                            Column(verticalArrangement = Arrangement.spacedBy(Metrics.spacing12)) {
                                if (staged.showsOverlines) {
                                    Overline(section.overline, Modifier.semantics { heading(); contentDescription = section.spokenOverline })
                                }
                                // No series: a tag is not a series, so no numerals on covers.
                                StaticBookGrid(
                                    section.books,
                                    Modifier.fillMaxWidth(),
                                    caption = if (subject is BookListSubject.Author) ({ StagedBooks.authorCaption(it) }) else null,
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

/** The page's name, set large, and the one line that says what is in it. */
@Composable
private fun Header(subject: BookListSubject, staged: StagedBooks, showInLibrary: () -> Unit, onNameBottom: (Int) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.spacing4)) {
        Text(
            subject.name,
            style = Typography.display,
            color = Palette.ink,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier
                .onGloballyPositioned { onNameBottom((it.positionInParent().y + it.size.height).toInt()) }
                .semantics {
                    heading()
                    contentDescription = staged.spokenHeader(subject.name, subject.kind)
                },
        )
        // The summary and the link share a line while they fit, and stack
        // when they do not.
        FitsOrStacks(
            modifier = Modifier.fillMaxWidth().heightIn(min = 44.dp),
            row = {
                Row(Modifier.fillMaxWidth().heightIn(min = 44.dp), verticalAlignment = Alignment.CenterVertically) {
                    Summary(staged)
                    Spacer(Modifier.widthIn(min = Metrics.spacing8).weight(1f))
                    ShowInLibraryLink(staged, subject, showInLibrary)
                }
            },
            stacked = {
                Column {
                    Summary(staged)
                    ShowInLibraryLink(staged, subject, showInLibrary)
                }
            },
        )
    }
}

@Composable
private fun Summary(staged: StagedBooks) {
    Text(staged.summary, style = Typography.footnote, color = Palette.inkTertiary)
}

@Composable
private fun ShowInLibraryLink(staged: StagedBooks, subject: BookListSubject, showInLibrary: () -> Unit) {
    if (!staged.offersShowInLibrary) return
    Text(
        "Show in Library",
        style = Typography.caption.copy(fontWeight = FontWeight.SemiBold),
        color = Palette.tangerinePressed,
        modifier = Modifier
            .heightIn(min = 44.dp)
            .clickable(
                role = Role.Button,
                onClickLabel = if (subject is BookListSubject.Tag) "Shows the whole library, filtered to this tag" else "Shows the whole library, searched for this author",
                onClick = showInLibrary,
            )
            .padding(vertical = 14.dp),
    )
}

/** The page can outlive its books: a refresh can take a tag off every book that had it. */
@Composable
private fun EmptyState(subject: BookListSubject) {
    when (subject) {
        is BookListSubject.Tag -> PalettePlaceholder(
            symbol = Symbols.tag,
            title = "No books with this tag",
            message = "Nothing in your library carries “${subject.name}” any more. It may have been removed on the server.",
        )
        is BookListSubject.Author -> PalettePlaceholder(
            symbol = Symbols.person,
            title = "No books by this author",
            message = "Nothing in your library is by ${subject.name} any more. It may have been removed on the server.",
        )
    }
}
