package com.benjaminissa.issareader.app.ui.shell

import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Modifier
import androidx.navigation.NavDestination.Companion.hasRoute
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.toRoute
import com.benjaminissa.issareader.app.ask.LocalBookRequests
import com.benjaminissa.issareader.app.model.AppModel
import com.benjaminissa.issareader.app.model.RootScreen
import com.benjaminissa.issareader.app.model.showLibrary
import com.benjaminissa.issareader.app.ui.local.LocalBooksScreen
import com.benjaminissa.issareader.app.ui.player.PlayerSheet
import com.benjaminissa.issareader.app.ui.reader.ReaderScreen
import com.benjaminissa.issareader.app.ui.signin.SignInScreen
import com.benjaminissa.issareader.core.model.isLocal
import com.benjaminissa.issareader.core.sync.LibraryArrangement
import com.benjaminissa.issareader.ui.Palette

/**
 * What the window shows: Swift's `RootView`.
 *
 * Two levels. The root holds the app's phase — launching, signing in, the
 * books from the reader's files, the library — and, over all of it, the
 * reader: a full-screen destination the tabs do not reach, so a session
 * expiring mid-chapter swaps the screen underneath the book rather than the
 * book itself.
 */
@Composable
fun IssaRoot(environment: AppEnvironment) {
    CompositionLocalProvider(LocalAppEnvironment provides environment) {
        val app = environment.app
        val rootNav = rememberNavController()
        val state = remember { RootState() }
        val actions = remember(rootNav, state, app) { RootActions(rootNav, state, app) }
        // Nothing to expand into once the book has stopped.
        LaunchedEffect(app.playback == null) { if (app.playback == null) state.showsPlayer = false }

        // The books from the reader's files: the route says which one's reader
        // is over this window, and the root presents it — and takes it down
        // when the route lets it go (the book removed, a server book pushed).
        val localRoute = environment.localRoute
        val local = environment.local
        if (localRoute != null && local != null) {
            LaunchedEffect(localRoute, local) { localRoute.observe(app, local, this) }
            LaunchedEffect(rootNav, localRoute) {
                snapshotFlow { localRoute.openBook }.collect { uuid ->
                    val reader = rootNav.currentBackStackEntry?.takeIf { it.destination.hasRoute<ReaderRoute>() }?.toRoute<ReaderRoute>()
                    when {
                        uuid != null && reader?.bookUuid != uuid -> actions.openReader(uuid, local = true)
                        uuid == null && reader?.local == true -> rootNav.popBackStack(RootRoute, inclusive = false)
                    }
                }
            }
            // A tapped answer for one of those books: not in the catalogue, so
            // it comes to the local route rather than the app's pending book.
            LaunchedEffect(localRoute) {
                snapshotFlow { LocalBookRequests.shared.pending }.collect {
                    LocalBookRequests.shared.take()?.let(localRoute::open)
                }
            }
        }

        // A link to another book arriving while a reader is up takes the
        // reader down, so the tabs underneath can open the link's book; a
        // link to the book already being read is that book, and is dropped.
        LaunchedEffect(rootNav, app) {
            snapshotFlow { app.pendingBook }.collect { pending ->
                pending ?: return@collect
                val reader = rootNav.currentBackStackEntry?.takeIf { it.destination.hasRoute<ReaderRoute>() }?.toRoute<ReaderRoute>()
                when {
                    reader == null -> Unit
                    reader.bookUuid == pending.uuid || app.visibleReaderUuid == pending.uuid -> app.discardPendingBook()
                    else -> rootNav.popBackStack(RootRoute, inclusive = false)
                }
            }
        }

        CompositionLocalProvider(LocalShellActions provides actions) {
            Box(Modifier.fillMaxSize().background(Palette.paper)) {
                NavHost(
                    navController = rootNav,
                    startDestination = RootRoute,
                    enterTransition = { fadeIn(tween(200)) },
                    exitTransition = { fadeOut(tween(200)) },
                ) {
                    composable<RootRoute> { PhaseSwitch(state) }
                    composable<ReaderRoute>(
                        // A full-screen cover: up from the bottom, and back down.
                        enterTransition = { slideInVertically(tween(320)) { it } },
                        exitTransition = { fadeOut(tween(200)) },
                        popEnterTransition = { fadeIn(tween(200)) },
                        popExitTransition = { slideOutVertically(tween(320)) { it } },
                    ) { entry ->
                        val route = entry.toRoute<ReaderRoute>()
                        ReaderScreen(
                            bookUuid = route.bookUuid,
                            local = route.local,
                            onClose = {
                                if (route.local) localRoute?.openBook = null
                                rootNav.popBackStack()
                            },
                            onOpenPlayer = actions::showPlayer,
                        )
                    }
                }
                // The full player, over the tabs or the reader alike: the
                // reader's waveform raises it as the mini bar does.
                if (state.showsPlayer) {
                    PlayerSheet(
                        onDismiss = { state.showsPlayer = false },
                        onReadAlong = {
                            state.showsPlayer = false
                            app.playbackBook?.let { actions.openReader(it.uuid, local = it.isLocal) }
                        },
                    )
                }
            }
        }
    }
}

/** The phase's screen, decided in one place a test can ask (`RootScreen.forPhase`). */
@Composable
private fun PhaseSwitch(state: RootState) {
    val environment = LocalAppEnvironment.current
    val app = environment.app
    // This window's place in the books-from-your-files flow: the list is the
    // root while signed out once the reader has chosen it — remembered by the
    // route, so a reader with no server lands on their books every launch.
    // A window without the route (a test's) keeps it for itself.
    val route = environment.localRoute
    var ownShowsList by rememberSaveable { mutableStateOf(false) }
    val showsListSignedOut = route?.showsListSignedOut ?: ownShowsList
    fun showList(value: Boolean) {
        if (route != null) route.showsListSignedOut = value else ownShowsList = value
    }
    LaunchedEffect(app.phase) {
        if (route == null && app.phase == AppModel.Phase.READY) ownShowsList = false
    }
    when (RootScreen.forPhase(app.phase, showsListSignedOut)) {
        // Deliberately no content, painted in the app's own ground: the
        // launch, this and the library are one continuous colour.
        RootScreen.LAUNCHING -> Box(Modifier.fillMaxSize().background(Palette.paper))
        RootScreen.SIGN_IN -> SignInScreen(
            onReadFromFiles = if (environment.localBooksAvailable) ({ showList(true) }) else null,
            onStartingSignIn = { showList(false) },
        )
        RootScreen.LOCAL_BOOKS -> LocalBooksScreen(standalone = true, onConnectServer = { showList(false) })
        RootScreen.LIBRARY -> LibraryShell(state)
    }
}

/** The root's own state, shared with the shell it draws. */
class RootState {
    /** The full player, which the mini bar's tap and a "Now Playing" raise. */
    var showsPlayer: Boolean by mutableStateOf(false)

    /** A request to show the Library tab from its root, bumped by each. */
    var libraryRootRequests: Int by mutableStateOf(0)
}

/** What a screen can ask of the root. */
private class RootActions(
    private val rootNav: NavHostController,
    private val state: RootState,
    private val app: AppModel,
) : ShellActions {
    override fun openReader(bookUuid: String, local: Boolean) {
        state.showsPlayer = false
        rootNav.navigate(ReaderRoute(bookUuid, local)) { launchSingleTop = true }
    }

    override fun showPlayer() {
        if (app.playback != null) state.showsPlayer = true
    }

    override fun showLibrary(fromReading: LibraryArrangement.Shelf?) {
        app.showLibrary(fromReading = fromReading)
        state.libraryRootRequests += 1
    }
}

/** The root's first destination: the phase's screen. */
@kotlinx.serialization.Serializable
data object RootRoute
