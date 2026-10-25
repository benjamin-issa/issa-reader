package com.benjaminissa.issareader.app.ui.fixture

import com.benjaminissa.issareader.app.model.AppModel
import com.benjaminissa.issareader.app.processStorageRoot
import com.benjaminissa.issareader.app.model.BrowserSignInModel
import com.benjaminissa.issareader.app.model.CoverCache
import com.benjaminissa.issareader.app.model.CustomFonts
import com.benjaminissa.issareader.app.model.DeviceSignInModel
import com.benjaminissa.issareader.app.model.FontImport
import com.benjaminissa.issareader.app.model.NowPlayingController
import com.benjaminissa.issareader.app.model.PlaybackSettings
import com.benjaminissa.issareader.app.reader.ReaderServices
import com.benjaminissa.issareader.app.ui.reader.QuietBackend
import com.benjaminissa.issareader.app.ui.reader.ReaderEnvironment
import com.benjaminissa.issareader.app.ui.shell.AppEnvironment
import com.benjaminissa.issareader.core.InMemoryKeyValueStore
import com.benjaminissa.issareader.core.Session
import com.benjaminissa.issareader.core.StorageRoot
import com.benjaminissa.issareader.core.auth.HttpDeviceGrantTransport
import com.benjaminissa.issareader.core.networking.MonitoredReachability
import com.benjaminissa.issareader.render.android.ReaderFonts
import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.awaitCancellation
import java.io.File

/**
 * The layout sweep's app: an [AppEnvironment] in front of [FixtureServer], on
 * the main thread as the app's is, with its files in [root].
 *
 * Signed in, the keychain holds the fixture's token and the last server is
 * the fixture's, so the launch restore takes the real signed-in path and the
 * library arrives over HTTP. Signed out, nothing is stored, as the iPhone's
 * sweep launches its sign-in screen with `-issa.lastServer ""`.
 */
object Sweep {
    /** The three iPhones the sweep's contact sheets are drawn at, in points. */
    data class Device(val name: String, val width: Int, val height: Int)

    val SE = Device("iphone-se3", 375, 667)
    val PRO = Device("iphone-17-pro", 402, 874)
    val PRO_MAX = Device("iphone-17-pro-max", 440, 956)

    /**
     * The process's storage root, the one the model suites share: the download
     * service settles on its Books directory once per process, and the app's
     * suites run in one, so every one of them has to use the same root. Made
     * the root again for each test, with the fixture's downloads planted
     * afresh, because a model test empties it after itself.
     */
    private fun useStorage() {
        val storage = processStorageRoot
        StorageRoot.configure(root = File(storage, "files"), caches = File(storage, "caches"), isPurgeable = false)
        FixtureLibrary.plantDownloads()
    }

    /**
     * @param root this test's own files: its cover cache. The books on the
     *   device are the process's (see [useStorage]).
     */
    fun environment(root: File, signedIn: Boolean): AppEnvironment {
        useStorage()
        val defaults = InMemoryKeyValueStore()
        if (signedIn) defaults.putString("issa.lastServer", FixtureServer.SERVER)
        val tokens = InMemoryTokens(signedIn)
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
        val app = AppModel(
            keychain = tokens,
            defaults = defaults,
            reachability = MonitoredReachability(),
            scope = scope,
            makeSession = { Session(it, tokens, http = FixtureServer.client) },
        )
        val covers = CoverCache(File(root, "caches/Covers"))
        val nowPlaying = NowPlayingController(scope)
        val settings = PlaybackSettings(defaults)
        val fonts = ReaderFonts(ApplicationProvider.getApplicationContext())
        // The reader's services, as the graph hands the app its own: a book
        // opened here lays out in the real reader and plays into nothing.
        app.readerServices = ReaderServices(scope = scope, fonts = fonts, makeMediaBackend = { QuietBackend() })
        // "Add a font…", over this test's own faces and fonts folder.
        val fontImport = FontImport(CustomFonts(fonts, directory = { File(root, "Fonts") }), contentResolver = null)
        return AppEnvironment(
            app = app,
            nowPlaying = nowPlaying,
            settings = settings,
            browserSignIn = { url -> BrowserSignInModel(url, scope, isSupported = { true }) { awaitCancellation() } },
            deviceSignIn = { url -> DeviceSignInModel(url, scope) { HttpDeviceGrantTransport(url, FixtureServer.client) } },
            isBrowserSupported = { true },
            covers = { covers },
            readerEnvironment = { ReaderEnvironment(settings, fonts, defaults, scope, app, nowPlaying, fontImport = fontImport) },
            fontImport = fontImport,
            versionText = "1.5.1 (52)",
        )
    }
}
