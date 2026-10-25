package com.benjaminissa.issareader.app.ui.fixture

import com.benjaminissa.issareader.app.model.AppModel
import com.benjaminissa.issareader.app.model.BrowserSignInModel
import com.benjaminissa.issareader.app.model.CoverCache
import com.benjaminissa.issareader.app.model.DeviceSignInModel
import com.benjaminissa.issareader.app.model.NowPlayingController
import com.benjaminissa.issareader.app.model.PlaybackSettings
import com.benjaminissa.issareader.app.ui.shell.AppEnvironment
import com.benjaminissa.issareader.core.InMemoryKeyValueStore
import com.benjaminissa.issareader.core.Session
import com.benjaminissa.issareader.core.StorageRoot
import com.benjaminissa.issareader.core.auth.HttpDeviceGrantTransport
import com.benjaminissa.issareader.core.networking.MonitoredReachability
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
     * One storage root for the process. The download service settles on its
     * Books directory once per process, and Robolectric runs a class's tests
     * in one, so a root per test left the second test reading the first's.
     */
    private val storage: File by lazy {
        val directory = kotlin.io.path.createTempDirectory("issa-sweep").toFile()
        StorageRoot.configure(root = File(directory, "files"), caches = File(directory, "caches"), isPurgeable = false)
        FixtureLibrary.plantDownloads()
        directory
    }

    /**
     * @param root this test's own files: its cover cache. The books on the
     *   device are the process's (see [storage]).
     */
    fun environment(root: File, signedIn: Boolean): AppEnvironment {
        storage
        StorageRoot.configure(root = File(storage, "files"), caches = File(storage, "caches"), isPurgeable = false)
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
        return AppEnvironment(
            app = app,
            nowPlaying = NowPlayingController(scope),
            settings = PlaybackSettings(defaults),
            browserSignIn = { url -> BrowserSignInModel(url, scope, isSupported = { true }) { awaitCancellation() } },
            deviceSignIn = { url -> DeviceSignInModel(url, scope) { HttpDeviceGrantTransport(url, FixtureServer.client) } },
            isBrowserSupported = { true },
            covers = { covers },
        )
    }
}
