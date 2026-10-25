package com.benjaminissa.issareader.app.ui.shell

import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.staticCompositionLocalOf
import com.benjaminissa.issareader.app.AppGraph
import com.benjaminissa.issareader.app.model.AppModel
import com.benjaminissa.issareader.app.model.BrowserSignInModel
import com.benjaminissa.issareader.app.model.CoverCache
import com.benjaminissa.issareader.app.model.DeviceSignInModel
import com.benjaminissa.issareader.app.model.LibraryNavigator
import com.benjaminissa.issareader.app.model.NowPlayingController
import com.benjaminissa.issareader.app.model.PlaybackSettings
import com.benjaminissa.issareader.app.ui.reader.LocalReaderBook
import com.benjaminissa.issareader.app.ui.reader.ReaderEnvironment
import com.benjaminissa.issareader.core.sync.LibraryArrangement
import java.net.URI

/**
 * What every screen reads instead of reaching for the graph: the values the
 * Swift app hands down with `.environment(…)` — the app, the transport, the
 * playback settings — and the two sign-in flows, which the graph builds
 * against the platform's browser.
 *
 * One object in one composition local, so a screenshot test hands the screens
 * a fixture library the same way the activity hands them the real one.
 *
 * @param isBrowserSupported whether this phone's browser can hand a sign-in
 *   back to the app (Chrome's Auth Tab). When it cannot, the browser route says
 *   so and offers the device code.
 * @param localBooksAvailable whether the books-from-your-files flow is wired.
 *   Swift draws its link only when a `LocalLibrary` is in the environment.
 * @param readerEnvironment what the reader is drawn with: the faces, the
 *   preferences, the scope its writes outlive the screen in. Null where no
 *   reader can open.
 * @param localBook a book from the reader's own files, by uuid, and where its
 *   reader's writes go.
 */
class AppEnvironment(
    val app: AppModel,
    val nowPlaying: NowPlayingController,
    val settings: PlaybackSettings,
    val browserSignIn: (URI) -> BrowserSignInModel,
    val deviceSignIn: (URI) -> DeviceSignInModel,
    val isBrowserSupported: () -> Boolean,
    val localBooksAvailable: Boolean = false,
    val covers: () -> CoverCache = { CoverCache.shared },
    val readerEnvironment: () -> ReaderEnvironment? = { null },
    val localBook: (String) -> LocalReaderBook? = { null },
) {
    companion object {
        /** The app's own, from its graph. */
        fun from(graph: AppGraph): AppEnvironment = AppEnvironment(
            app = graph.app,
            nowPlaying = graph.nowPlaying,
            settings = graph.settings,
            browserSignIn = graph::browserSignIn,
            deviceSignIn = graph::deviceSignIn,
            isBrowserSupported = { graph.authTab.isSupported },
            localBooksAvailable = true,
            readerEnvironment = {
                ReaderEnvironment(
                    settings = graph.settings,
                    fonts = graph.fonts,
                    defaults = graph.defaults,
                    appScope = graph.mainScope,
                    app = graph.app,
                    nowPlaying = graph.nowPlaying,
                    ask = graph.ask,
                )
            },
            localBook = { uuid -> graph.local.book(uuid)?.let { LocalReaderBook(it, graph.local) } },
        )
    }
}

val LocalAppEnvironment = staticCompositionLocalOf<AppEnvironment> { error("No AppEnvironment provided") }

/** The app model, as `@Environment(AppModel.self)` reads it. */
val appModel: AppModel
    @Composable @ReadOnlyComposable get() = LocalAppEnvironment.current.app

/**
 * What a screen can ask of the shell around it: the things only the root can
 * do — present the reader over the tabs, raise the player, switch to the
 * Library tab. Swift's root answers the same requests through bindings and
 * `LibraryNavigator`.
 */
interface ShellActions {
    /** The reader, full screen over the tabs. */
    fun openReader(bookUuid: String, local: Boolean = false)

    /** The full player, as the mini bar's tap raises it. */
    fun showPlayer()

    /**
     * The Library tab from its root: the flat grid on [shelf], or the
     * library's landing for null (`LibraryModeSwitch.fromReading`).
     */
    fun showLibrary(fromReading: LibraryArrangement.Shelf?)

    companion object {
        /** For a screen drawn on its own, in a test or a preview. */
        val None: ShellActions = object : ShellActions {
            override fun openReader(bookUuid: String, local: Boolean) = Unit
            override fun showPlayer() = Unit
            override fun showLibrary(fromReading: LibraryArrangement.Shelf?) = Unit
        }
    }
}

val LocalShellActions = staticCompositionLocalOf { ShellActions.None }

/**
 * This window's "Show in Library" requests: a page asks, the shell answers
 * by showing the Library tab from its root, and the library takes the search
 * the request carried. Swift's `LibraryNavigator` in the environment.
 */
val LocalLibraryNavigator = staticCompositionLocalOf<LibraryNavigator?> { null }
