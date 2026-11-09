package com.benjaminissa.issareader.app.ui.shell

import android.content.Context
import android.os.Build
import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.staticCompositionLocalOf
import com.benjaminissa.issareader.app.AppGraph
import com.benjaminissa.issareader.app.ask.AskCoordinator
import com.benjaminissa.issareader.app.local.LocalBooksRoute
import com.benjaminissa.issareader.app.local.LocalLibrary
import com.benjaminissa.issareader.app.model.AppModel
import com.benjaminissa.issareader.app.model.BrowserSignInModel
import com.benjaminissa.issareader.app.model.CoverCache
import com.benjaminissa.issareader.app.model.DeviceSignInModel
import com.benjaminissa.issareader.app.model.FontImport
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
 * playback settings, the local library and its route, Ask — and the two
 * sign-in flows, which the graph builds against the platform's browser.
 *
 * One object in one composition local, [LocalAppEnvironment], for every
 * screen — the shell, the library, Settings, the player, the books on this
 * phone, the reader and Ask — so a test hands the screens a fixture the same
 * way the activity hands them the real one, and no screen reaches for the
 * application's graph itself.
 *
 * @param isBrowserSupported whether this phone's browser can hand a sign-in
 *   back to the app (Chrome's Auth Tab). When it cannot, the browser route says
 *   so and offers the device code.
 * @param localBooksAvailable whether the books-from-your-files flow is wired.
 *   Swift draws its link only when a `LocalLibrary` is in the environment.
 * @param covers the cover cache the screens draw from.
 * @param readerEnvironment what the reader is drawn with: the faces, the
 *   preferences, the scope its writes outlive the screen in. Null where no
 *   reader can open.
 * @param localBook a book from the reader's own files, by uuid, and where its
 *   reader's writes go.
 * @param local the books from the reader's own files. Null where there is no
 *   library to show.
 * @param localRoute where this window is in the local books' flow: the book
 *   whose reader is over it, and whether the list stands in for sign-in.
 * @param fontImport "Add a font…" and the faces it imported, which Settings
 *   and a book's own sheet share. Null where importing is not offered.
 * @param ask Ask's coordinator, whose switch Settings carries. Null where Ask
 *   is not built.
 * @param versionText "1.5.1 (52)", as Settings › About states the build.
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
    val local: LocalLibrary? = null,
    val localRoute: LocalBooksRoute? = null,
    val fontImport: FontImport? = null,
    val ask: AskCoordinator? = null,
    val versionText: String = "?",
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
                    fontImport = graph.fontImport,
                )
            },
            localBook = { uuid -> graph.local.book(uuid)?.let { LocalReaderBook(it, graph.local) } },
            local = graph.local,
            localRoute = graph.localBooksRoute,
            fontImport = graph.fontImport,
            ask = graph.ask,
            versionText = versionText(graph.context),
        )

        /** The marketing version and the build number, as Swift's `"\(short) (\(build))"`. */
        fun versionText(context: Context): String {
            val info = runCatching { context.packageManager.getPackageInfo(context.packageName, 0) }.getOrNull()
            val short = info?.versionName ?: "?"
            val build = info?.let { if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) it.longVersionCode.toString() else null } ?: "?"
            return "$short ($build)"
        }
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
