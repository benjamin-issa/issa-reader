package com.benjaminissa.issareader.app

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.snapshots.Snapshot
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import com.benjaminissa.issareader.app.download.WorkManagerTransferBackend
import com.benjaminissa.issareader.app.local.LocalBooksRoute
import com.benjaminissa.issareader.app.local.LocalBooksWiring
import com.benjaminissa.issareader.app.local.LocalDevice
import com.benjaminissa.issareader.app.local.LocalLibrary
import com.benjaminissa.issareader.app.model.AppModel
import com.benjaminissa.issareader.app.model.BrowserSignInModel
import com.benjaminissa.issareader.app.model.CoverCache
import com.benjaminissa.issareader.app.model.CurrentBookPublisher
import com.benjaminissa.issareader.app.model.DeviceSignInModel
import com.benjaminissa.issareader.app.model.LauncherShortcutBackend
import com.benjaminissa.issareader.app.model.NowPlayingController
import com.benjaminissa.issareader.app.model.PlaybackSettings
import com.benjaminissa.issareader.app.model.ShortcutPublisher
import com.benjaminissa.issareader.app.model.TerminationSequence
import com.benjaminissa.issareader.app.platform.AndroidReachability
import com.benjaminissa.issareader.app.platform.AuthTabBrowser
import com.benjaminissa.issareader.app.platform.KeystoreTokenStorage
import com.benjaminissa.issareader.app.platform.SharedPreferencesKeyValueStore
import com.benjaminissa.issareader.app.reader.ReaderServices
import com.benjaminissa.issareader.app.widget.CurrentBookWidget
import com.benjaminissa.issareader.core.CurrentBookSnapshotStore
import com.benjaminissa.issareader.core.StorageRoot
import com.benjaminissa.issareader.core.networking.TokenProviding
import com.benjaminissa.issareader.core.diagnostics.IssaLog
import com.benjaminissa.issareader.core.download.BookContentService
import com.benjaminissa.issareader.core.download.DownloadManager
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.networking.ApiClient
import com.benjaminissa.issareader.core.networking.ServerAddress
import com.benjaminissa.issareader.core.sync.LibraryService
import com.benjaminissa.issareader.playback.MediaBackend
import com.benjaminissa.issareader.playback.android.AndroidDurationMeasurer
import com.benjaminissa.issareader.playback.android.AndroidMediaSupport
import com.benjaminissa.issareader.playback.android.ExoMediaBackend
import com.benjaminissa.issareader.render.android.ReaderFonts
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import java.io.File
import java.net.URI

/**
 * The app's long-lived objects, and the one place it is started from: Swift's
 * `AppServices`.
 *
 * Built in [IssaApplication.onCreate], so it exists however the process was
 * started — the launcher, a widget tap, a download worker, or Android Auto
 * binding the media service with no activity at all. The car finds a working
 * app: a restored session, a library, and somewhere to start a book.
 *
 * Main-thread only.
 *
 * @param makeMediaBackend a fresh playback engine: ExoPlayer, over the app's
 *   own HTTP client, so streams share its connection pool and TLS settings.
 */
class AppGraph(
    val context: Context,
    val makeMediaBackend: () -> MediaBackend = { ExoMediaBackend(context, ApiClient.sharedHttpClient) },
) {
    /** The main thread's scope. Its dispatcher posts, as the coordinators require. */
    val mainScope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    init {
        configureStorage(context)
    }

    /** The small preferences: `UserDefaults`, as `SharedPreferences`, which the backup rules include. */
    val defaults = SharedPreferencesKeyValueStore(context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE))

    /** The sign-in tokens, sealed by the Keystore, in no-backup storage. */
    val keychain = KeystoreTokenStorage(File(context.noBackupFilesDir, "Tokens"))

    val reachability: AndroidReachability = AndroidReachability.start(context)
    val settings = PlaybackSettings(defaults)
    val nowPlaying = NowPlayingController(mainScope)

    /** The widget's one writer. */
    val publisher = CurrentBookPublisher(
        scope = mainScope,
        reload = { mainScope.launch { runCatching { CurrentBookWidget.reload(context) } } },
    )

    /** The faces a page is set in. */
    val fonts = ReaderFonts(context)

    /** What each reader needs that is not about its book. */
    val readerServices = ReaderServices(
        scope = mainScope,
        fonts = fonts,
        makeMediaBackend = makeMediaBackend,
        scale = context.resources.displayMetrics.density.toDouble(),
        measurer = AndroidDurationMeasurer(),
    )

    /** What this phone's player can decode, for a book added from the reader's own files. */
    val mediaSupport = AndroidMediaSupport()

    /** Chrome's Auth Tab, which the browser sign-in route opens. `MainActivity` attaches it. */
    val authTab = AuthTabBrowser(context)

    /** The launcher's recently opened books. */
    val shortcuts = ShortcutPublisher(LauncherShortcutBackend(context), defaults)

    /**
     * The books added from the reader's own files. `Local/` is under
     * `StorageRoot`, outside the backup rules; the device store goes in
     * `Store/` beside every server's.
     */
    val local: LocalLibrary = LocalLibrary(
        scope = mainScope,
        mediaSupport = mediaSupport,
        contentResolver = context.contentResolver,
        measurer = AndroidDurationMeasurer(),
    )

    /**
     * Where the one window is in the local books' flow: the book whose reader
     * is presented over it, and whether the list stands in for sign-in. Swift
     * keeps one per window in `RootView`; Android has one window, so the
     * graph holds it for the root and the screens alike.
     */
    val localBooksRoute: LocalBooksRoute = LocalBooksRoute(defaults)

    /** Exit bookkeeping: the background flush, so two overlapping ones do not run twice. */
    val termination = TerminationSequence()

    val app: AppModel = AppModel(
        keychain = keychain,
        defaults = defaults,
        reachability = reachability,
        scope = mainScope,
    )

    /**
     * The download manager, built now rather than at the first connect: its
     * WorkManager backend has to exist before any worker runs, and a transfer
     * carried on from an earlier process runs as soon as the app starts. It is
     * pointed at the server and the token when `connect` runs.
     */
    val downloads: DownloadManager = DownloadManager(
        baseUrl = ServerAddress.normalize(defaults.getString("issa.lastServer") ?: "") ?: URI("http://localhost/"),
        tokens = NoToken,
        preferences = defaults,
        dispatcher = Dispatchers.Main,
        destinationFor = { job -> BookContentService.localUrl(BookContentService.defaultDirectory(), job.bookUuid, job.format) },
        makeBackend = { events -> WorkManagerTransferBackend(context, ApiClient.sharedHttpClient, events) },
    )

    private var started = false

    /** Starts the app. Idempotent. */
    fun start() {
        if (started) return
        started = true
        sendSnapshotApplyNotifications()
        BookContentService.migrateFromCachesIfNeeded()
        IssaLog.info(
            "app launched",
            mapOf(
                "version" to runCatching { context.packageManager.getPackageInfo(context.packageName, 0).versionName }.getOrNull().orEmpty(),
                "os" to "Android ${android.os.Build.VERSION.RELEASE}",
            ),
        )
        app.useDownloads(downloads)
        app.readerServices = readerServices
        app.currentBookPublisher = publisher
        app.shortcuts = shortcuts
        nowPlaying.configure(settings)
        // Playback starts and stops from places with no screen to thread this
        // through: a car list item, the reader closing.
        app.nowPlayingController = nowPlaying
        // What the copy deck calls this device: "On this phone", "On this tablet".
        LocalDevice.noun = if (context.resources.configuration.smallestScreenWidthDp >= 600) "tablet" else "phone"
        LocalBooksWiring.connect(app, local, settings, ask = null)
        observeLibraryForShortcuts()
        observeProcessLifecycle()
        app.startRestore()
    }

    /** A new browser sign-in for the server the app is connected to. */
    fun browserSignIn(serverUrl: URI): BrowserSignInModel =
        BrowserSignInModel(serverUrl, mainScope, authTab) { authTab.isSupported }

    /** A new pairing-code sign-in for the server the app is connected to. */
    fun deviceSignIn(serverUrl: URI): DeviceSignInModel = DeviceSignInModel(serverUrl, mainScope)

    // What Android Auto needs, which it cannot reach on its own: somewhere to
    // start a book, chapters, covers, and which surface the controls belong to.

    /**
     * Starts a book from the car. Reported back rather than logged: a row
     * that silently does nothing at 70 mph is indistinguishable from a crash.
     *
     * @return the sentence to show, or null when it started.
     */
    suspend fun startListeningFromCar(bookUuid: String): String? {
        val book = app.books.firstOrNull { it.uuid == bookUuid } ?: return "That book is no longer in your library."
        app.startListening(book, nowPlaying, settings)
        return app.listeningError
    }

    /** Through the rates a driver actually wants, wrapping around: there is no menu in a car. */
    fun cycleRateFromCar() {
        val rates = listOf(1.0, 1.25, 1.5, 1.75, 2.0)
        val current = settings.playbackRate
        val next = rates.firstOrNull { it > current + 0.01 } ?: rates[0]
        settings.playbackRate = next
        nowPlaying.coordinator?.player?.rate = next.toFloat()
        nowPlaying.publish()
    }

    /**
     * A small square cover for a car's list row, by the book where the
     * catalogue has it, so a 3.x server is asked by content hash.
     */
    suspend fun carCover(bookUuid: String): ByteArray? {
        val session = app.session ?: return null
        val service = LibraryService(session.client)
        val book: Book? = app.bookByUuid[bookUuid]
        return runCatching {
            if (book != null) {
                service.coverData(book, LibraryService.CoverShape.SQUARE, pixelWidth = 240)
            } else {
                service.coverData(bookUuid, LibraryService.CoverShape.SQUARE, pixelWidth = 240)
            }
        }.getOrNull()
    }

    /** The car connecting and going: Now Playing picks a command map, the model decides hand-offs. */
    fun setCarConnected(connected: Boolean) {
        val surface = if (connected) com.benjaminissa.issareader.playback.ControlSurface.CAR else com.benjaminissa.issareader.playback.ControlSurface.PHONE
        nowPlaying.setSurface(surface)
        app.setControlSurface(surface)
        // A car connecting is a reason to read the disk again: the offline
        // shelf filters on nothing but the downloaded set.
        if (connected) app.refreshDownloadedSet()
    }

    /** Replaces the launcher's shortcuts whenever the library changes. */
    private fun observeLibraryForShortcuts() {
        mainScope.launch {
            androidx.compose.runtime.snapshotFlow { app.books }.collectLatest { books ->
                if (app.phase == AppModel.Phase.READY && books.isNotEmpty()) shortcuts.update(books)
            }
        }
    }

    /**
     * The app going to and coming back from the background, process-wide:
     * `ProcessLifecycleOwner` tracks activities only, so a car session does
     * not pin the app as foreground.
     */
    private fun observeProcessLifecycle() {
        ProcessLifecycleOwner.get().lifecycle.addObserver(
            object : DefaultLifecycleObserver {
                override fun onStart(owner: LifecycleOwner) {
                    app.setForeground(true)
                    // A transfer can complete while backgrounded.
                    app.refreshDownloadedSet()
                }

                override fun onStop(owner: LifecycleOwner) {
                    app.setForeground(false)
                    flushOnBackground()
                }
            },
        )
    }

    /**
     * Saves the open books and sends the backlog as the app goes to the
     * background. Android gives a backgrounded process time without an
     * assertion; the flush runs to completion, and a second request while one
     * is running waits for it rather than starting another.
     */
    fun flushOnBackground() {
        val flush: suspend () -> Unit = { app.flushOpenReaders() }
        if (termination.begin(flush) != TerminationSequence.Request.LATER) return
        mainScope.launch {
            try {
                flush()
            } finally {
                termination.replyOnce {}
            }
        }
    }

    /** Releases decoded covers under memory pressure; the files stay. */
    fun trimMemory() {
        CoverCache.shared.releaseDecodedCovers()
    }

    /**
     * Compose applies a snapshot write outside any composition only when
     * someone sends the apply notifications, which its UI does every frame.
     * The media service and the car read this app's state through
     * `snapshotFlow` with no UI at all, so the notifications are sent here,
     * on the main thread, whenever a global write happens.
     */
    private fun sendSnapshotApplyNotifications() {
        val handler = Handler(Looper.getMainLooper())
        var pending = false
        Snapshot.registerGlobalWriteObserver {
            if (pending) return@registerGlobalWriteObserver
            pending = true
            handler.post {
                pending = false
                Snapshot.sendApplyNotifications()
            }
        }
    }

    companion object {
        const val PREFERENCES = "issa"

        /**
         * Says where the app's files live, before anything writes.
         *
         * The root is `filesDir`: the backup rules (`data_extraction_rules.xml`)
         * include only `Store/` and `datastore/` under it, and shared
         * preferences, so downloads, extracted narration, books from the
         * reader's files, Ask indexes and the log under the same root are
         * never backed up. Tokens are in `noBackupFilesDir`. The cover cache is
         * in `cacheDir`, which the system may reclaim.
         */
        fun configureStorage(context: Context) {
            StorageRoot.configure(root = context.filesDir, caches = context.cacheDir, isPurgeable = false)
            CurrentBookSnapshotStore.configure(File(context.filesDir, "Widget"))
        }
    }
}

/** The token provider of a manager no session has been handed to yet. */
private object NoToken : TokenProviding {
    override suspend fun currentToken(): String? = null
    override suspend fun invalidate() = Unit
}
