package com.benjaminissa.issareader.app.ui.settings

import android.content.Context
import android.os.Build
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.platform.LocalContext
import com.benjaminissa.issareader.app.AppGraph
import com.benjaminissa.issareader.app.IssaApplication
import com.benjaminissa.issareader.app.local.LocalBooksRoute
import com.benjaminissa.issareader.app.local.LocalDevice
import com.benjaminissa.issareader.app.local.LocalLibrary
import com.benjaminissa.issareader.app.model.AppModel
import com.benjaminissa.issareader.app.model.CoverCache
import com.benjaminissa.issareader.app.model.NowPlayingController
import com.benjaminissa.issareader.app.model.PlaybackSettings
import com.benjaminissa.issareader.ui.Symbols

/**
 * What the Settings, player and local-books screens read: the objects the
 * Swift views take from the environment — `AppModel`, `PlaybackSettings`,
 * `NowPlayingController`, `LocalLibrary` and `LocalBooksRoute` — gathered
 * from the app's graph.
 *
 * A screen asks [screenServices]: a test hands its own fixture in through
 * [LocalScreenServices], and the app is answered from the application's
 * [AppGraph], the way `MainActivity` reaches it.
 */
@Stable
class ScreenServices(
    val app: AppModel,
    val settings: PlaybackSettings,
    val nowPlaying: NowPlayingController,
    /** The books from the reader's own files. Null where there is no library to show. */
    val local: LocalLibrary?,
    /** Where this window is in the local books' flow: the book whose reader is presented over it. */
    val localRoute: LocalBooksRoute?,
    val coverCache: CoverCache = CoverCache.shared,
    /** "1.5.1 (52)", as Settings › About states the build. */
    val versionText: String = "?",
) {
    companion object {
        fun from(graph: AppGraph): ScreenServices = ScreenServices(
            app = graph.app,
            settings = graph.settings,
            nowPlaying = graph.nowPlaying,
            local = graph.local,
            localRoute = graph.localBooksRoute,
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

/** A test's or a preview's services, standing in for the application's graph. */
val LocalScreenServices = staticCompositionLocalOf<ScreenServices?> { null }

/** The services in force: a provided fixture, or the app's own graph. */
@Composable
fun screenServices(): ScreenServices {
    LocalScreenServices.current?.let { return it }
    val context = LocalContext.current.applicationContext
    return remember(context) { ScreenServices.from((context as IssaApplication).graph) }
}

/** The device's own glyph, for the Settings row: Swift's `LocalDevice.symbol`. */
val LocalDevice.symbol: Int get() = if (noun == "tablet") Symbols.ipad else Symbols.iphone
