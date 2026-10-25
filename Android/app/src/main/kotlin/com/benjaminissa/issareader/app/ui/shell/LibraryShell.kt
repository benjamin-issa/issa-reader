package com.benjaminissa.issareader.app.ui.shell

import androidx.compose.animation.AnimatedContentTransitionScope
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHostState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.navigation.NavBackStackEntry
import androidx.navigation.NavDestination
import androidx.navigation.NavDestination.Companion.hasRoute
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.navigation
import androidx.navigation.compose.rememberNavController
import androidx.navigation.toRoute
import com.benjaminissa.issareader.app.model.LibraryNavigator
import com.benjaminissa.issareader.app.ui.book.AuthorScreen
import com.benjaminissa.issareader.app.ui.book.BookCover
import com.benjaminissa.issareader.app.ui.book.BookDetailScreen
import com.benjaminissa.issareader.app.ui.book.SeriesScreen
import com.benjaminissa.issareader.app.ui.book.TagScreen
import com.benjaminissa.issareader.app.ui.downloads.DownloadRemovalSnackbarHost
import com.benjaminissa.issareader.app.ui.downloads.DownloadRemovalToast
import com.benjaminissa.issareader.app.ui.library.LibraryScreen
import com.benjaminissa.issareader.app.ui.library.SeriesListScreen
import com.benjaminissa.issareader.app.ui.local.LocalBooksScreen
import com.benjaminissa.issareader.app.ui.player.PlayerSheet
import com.benjaminissa.issareader.app.ui.reading.ReadingScreen
import com.benjaminissa.issareader.app.ui.settings.DownloadsScreen
import com.benjaminissa.issareader.app.ui.settings.SettingsScreen
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.isLocal
import com.benjaminissa.issareader.core.sync.LibraryService
import com.benjaminissa.issareader.playback.Observed
import com.benjaminissa.issareader.playback.PlaybackAction
import com.benjaminissa.issareader.playback.PlaybackDriving
import com.benjaminissa.issareader.playback.PlaybackProgress
import com.benjaminissa.issareader.ui.IssaNavigationBar
import com.benjaminissa.issareader.ui.MiniPlayerBar
import com.benjaminissa.issareader.ui.Palette
import com.benjaminissa.issareader.ui.ReservedPlayerBand
import com.benjaminissa.issareader.ui.Symbols
import com.benjaminissa.issareader.ui.TabItem
import kotlinx.coroutines.launch

/**
 * Library, Reading and Settings: Swift's `LibraryTabs`.
 *
 * Two homes with two jobs — the Library for looking around, the Reading tab
 * for getting back to your book — and Settings. It opens on Reading: a launch
 * is almost always to carry on. Each tab keeps its own stack, saved as the
 * reader moves between them; tapping the tab already showing goes back to
 * its first screen.
 *
 * Above the bar, the mini player while something plays, and while nothing
 * does the band it will take, so starting a book does not shove every
 * screen's bottom edge up. The undo for a removed download is the shell's,
 * wherever the reader is.
 */
@Composable
fun LibraryShell(state: RootState) {
    val environment = LocalAppEnvironment.current
    val app = environment.app
    val nav = rememberNavController()
    val libraryNavigator = remember { LibraryNavigator() }
    val switching = remember { TabSwitch() }
    val backStack by nav.currentBackStack.collectAsState()
    val selected = backStack.asReversed().firstNotNullOfOrNull { tabOf(it.destination) } ?: Tab.READING

    fun select(tab: Tab) {
        if (tab == selected) {
            nav.popBackStack(tab.home, inclusive = false)
            return
        }
        switching.active = true
        nav.navigate(tab.graph) {
            popUpTo(nav.graph.findStartDestination().id) { saveState = true }
            launchSingleTop = true
            restoreState = true
        }
    }

    /** The Library tab with nothing pushed on it. */
    fun showLibraryRoot() {
        if (selected == Tab.LIBRARY) {
            nav.popBackStack(LibraryHome, inclusive = false)
        } else {
            switching.active = true
            nav.navigate(LibraryTab) {
                popUpTo(nav.graph.findStartDestination().id) { saveState = true }
                launchSingleTop = true
            }
        }
    }

    /**
     * A link's book, once the library can answer: pushed on whichever book
     * stack is showing — Library when Settings is up — from that tab's root,
     * so Back from it lands on the tab. The book's own screen opens the
     * reader when the link meant "carry on".
     */
    fun openPendingBook() {
        val pending = app.pendingBook
        // The reader for this very book is already up: drop the request
        // rather than consume it, which would re-arm the reader.
        if (pending != null && app.visibleReaderUuid == pending.uuid) {
            app.discardPendingBook()
            return
        }
        val (book, _) = app.consumePendingBook() ?: return
        // The full player sat over the navigation the request spent itself in.
        state.showsPlayer = false
        val tab = if (selected == Tab.SETTINGS) Tab.LIBRARY else selected
        if (tab != selected) select(tab)
        nav.popBackStack(tab.home, inclusive = false)
        nav.navigate(BookDetailRoute(book.uuid))
    }

    // A link can arrive before the library has loaded, so this waits for the
    // book to exist rather than dropping the request.
    LaunchedEffect(app.pendingBook, app.books) { openPendingBook() }
    // An intent runs outside the screens and cannot navigate, so it leaves
    // the book in an inbox, collected as the library appears and whenever it
    // is written.
    LaunchedEffect(app.intentInbox.bookId) { app.intentInbox.deliver(app) }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { app.intentInbox.deliver(app) }
    // "Show in Library", from a tag or author page or the Reading tab.
    LaunchedEffect(libraryNavigator.showRequests) { if (libraryNavigator.showRequests > 0) showLibraryRoot() }
    LaunchedEffect(state.libraryRootRequests) { if (state.libraryRootRequests > 0) libraryNavigator.showLibrary() }
    LaunchedEffect(selected) { switching.active = false }
    // Nothing to expand into once the book has stopped.
    LaunchedEffect(app.playback == null) { if (app.playback == null) state.showsPlayer = false }

    val snackbar = remember { SnackbarHostState() }
    DownloadRemovalToast(snackbar)

    CompositionLocalProvider(
        LocalTabNavigator provides remember(nav) { TabNavigator(nav) },
        LocalLibraryNavigator provides libraryNavigator,
    ) {
        Scaffold(
            containerColor = Palette.paper,
            contentWindowInsets = WindowInsets(0),
            snackbarHost = { DownloadRemovalSnackbarHost(snackbar) },
            bottomBar = {
                Column {
                    val book = app.playbackBook
                    val coordinator = app.playback
                    if (book != null && coordinator != null) {
                        key(coordinator) { MiniPlayer(book, coordinator) { state.showsPlayer = true } }
                    } else {
                        ReservedPlayerBand()
                    }
                    IssaNavigationBar(TABS, selected.ordinal, onSelect = { select(Tab.entries[it]) })
                }
            },
        ) { padding ->
            NavHost(
                navController = nav,
                startDestination = ReadingTab,
                modifier = Modifier.padding(padding).consumeWindowInsets(padding),
                enterTransition = { if (switching.active) EnterTransition.None else push() },
                exitTransition = { if (switching.active) ExitTransition.None else pushAway() },
                popEnterTransition = { if (switching.active) EnterTransition.None else popBack() },
                popExitTransition = { if (switching.active) ExitTransition.None else popAway() },
            ) {
                navigation<LibraryTab>(startDestination = LibraryHome) {
                    composable<LibraryHome> { LibraryScreen() }
                }
                navigation<ReadingTab>(startDestination = ReadingHomeRoute) {
                    composable<ReadingHomeRoute> { ReadingScreen() }
                }
                navigation<SettingsTab>(startDestination = SettingsHome) {
                    composable<SettingsHome> { SettingsScreen(onOpenLocalBooks = { nav.navigate(LocalBooksRoute) }) }
                }
                // The pages any tab can push, on whichever tab pushed them.
                composable<BookDetailRoute> { BookDetailScreen(it.toRoute<BookDetailRoute>().uuid) }
                composable<SeriesRoute> { SeriesScreen(it.toRoute<SeriesRoute>().name) }
                composable<SeriesListRoute> { SeriesListScreen() }
                composable<TagRoute> { TagScreen(it.toRoute<TagRoute>().name) }
                composable<AuthorRoute> { AuthorScreen(it.toRoute<AuthorRoute>().name) }
                composable<DownloadsRoute> { DownloadsScreen(onBack = { nav.popBackStack() }) }
                composable<LocalBooksRoute> { LocalBooksScreen(standalone = false, onConnectServer = {}) }
            }
        }
    }

    if (state.showsPlayer) {
        val shell = LocalShellActions.current
        PlayerSheet(
            onDismiss = { state.showsPlayer = false },
            onReadAlong = {
                state.showsPlayer = false
                app.playbackBook?.let { shell.openReader(it.uuid, local = it.isLocal) }
            },
        )
    }
}

/** The bar's tabs, in its order; Library stays first though the app opens on Reading. */
private val TABS = listOf(
    TabItem("Library", Symbols.booksVerticalFill),
    TabItem("Reading", Symbols.bookmarkFill),
    TabItem("Settings", Symbols.gearshapeFill),
)

private val Tab.graph: Any
    get() = when (this) {
        Tab.LIBRARY -> LibraryTab
        Tab.READING -> ReadingTab
        Tab.SETTINGS -> SettingsTab
    }

private val Tab.home: Any
    get() = when (this) {
        Tab.LIBRARY -> LibraryHome
        Tab.READING -> ReadingHomeRoute
        Tab.SETTINGS -> SettingsHome
    }

/** Which tab a back-stack entry's destination is the graph of, if it is one. */
private fun tabOf(destination: NavDestination): Tab? = when {
    destination.hasRoute<LibraryTab>() -> Tab.LIBRARY
    destination.hasRoute<ReadingTab>() -> Tab.READING
    destination.hasRoute<SettingsTab>() -> Tab.SETTINGS
    else -> null
}

/** Whether the navigation under way is a change of tab, which is instant, as the iPhone's is. */
private class TabSwitch {
    var active: Boolean = false
}

// A push slides the page in from the trailing edge over the one it covers,
// as a navigation stack does on the iPhone; Back reverses it.
private fun AnimatedContentTransitionScope<NavBackStackEntry>.push(): EnterTransition =
    slideInHorizontally(tween(300)) { it }

private fun AnimatedContentTransitionScope<NavBackStackEntry>.pushAway(): ExitTransition =
    slideOutHorizontally(tween(300)) { -it / 3 }

private fun AnimatedContentTransitionScope<NavBackStackEntry>.popBack(): EnterTransition =
    slideInHorizontally(tween(300)) { -it / 3 }

private fun AnimatedContentTransitionScope<NavBackStackEntry>.popAway(): ExitTransition =
    slideOutHorizontally(tween(300)) { it }

/**
 * The strip that plays above the tabs: the shared `MiniPlayerBar`, wired to
 * whatever plays — the audiobook or a reader's narration. A tap expands it
 * into the player; skip uses the reader's command map, as the remote does.
 */
@Composable
private fun MiniPlayer(book: Book, coordinator: PlaybackDriving, onExpand: () -> Unit) {
    val environment = LocalAppEnvironment.current
    val scope = rememberCoroutineScope()
    // Redrawn as the engine moves: its observed state bumps a revision.
    coordinator.player.changes.collectAsState().value
    (coordinator as? Observed)?.changes?.collectAsState()?.value
    val progress = PlaybackProgress(
        scope = environment.settings.progressScope,
        bookProgress = coordinator.bookProgress,
        totalDuration = coordinator.totalDuration,
        chapterSpan = coordinator.chapterSpan,
    ).fraction
    MiniPlayerBar(
        cover = { BookCover(book, Modifier.size(40.dp), aspect = 1f, shape = LibraryService.CoverShape.SQUARE) },
        title = book.title,
        // Only when the book actually names it.
        chapter = environment.app.playbackChapterTitle,
        isPlaying = coordinator.player.isPlaying,
        progress = progress,
        onPlayPause = {
            coordinator.player.togglePlayPause()
            environment.nowPlaying.publish()
        },
        onSkipBack = {
            scope.launch {
                coordinator.perform(PlaybackAction.SKIP_BACKWARD, environment.settings.commandMap)
                environment.nowPlaying.publish()
            }
        },
        onSkipForward = {
            scope.launch {
                coordinator.perform(PlaybackAction.SKIP_FORWARD, environment.settings.commandMap)
                environment.nowPlaying.publish()
            }
        },
        onExpand = onExpand,
    )
}
