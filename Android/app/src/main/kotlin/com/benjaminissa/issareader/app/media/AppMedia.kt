package com.benjaminissa.issareader.app.media

import android.content.ComponentName
import android.content.Context
import androidx.compose.runtime.snapshotFlow
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import com.benjaminissa.issareader.app.AppGraph
import com.benjaminissa.issareader.app.model.AppModel
import com.benjaminissa.issareader.app.model.CoverCache
import com.benjaminissa.issareader.app.model.NowPlayingController
import com.benjaminissa.issareader.app.model.NowPlayingSink
import com.benjaminissa.issareader.app.model.PlaybackSettings
import com.benjaminissa.issareader.core.diagnostics.IssaLog
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.sync.CarCatalogue
import com.benjaminissa.issareader.core.sync.LibraryService
import com.benjaminissa.issareader.playback.CommandRouter
import com.benjaminissa.issareader.playback.android.CarPresence
import com.benjaminissa.issareader.playback.android.SessionTransport
import com.google.common.util.concurrent.ListenableFuture
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File

/**
 * The app's half of the media session and Android Auto: Swift's
 * `AppServices.connectCarPlay()`.
 *
 * Built with the graph and started with it, so it exists however the process
 * was started — including by Android Auto binding the media service with no
 * activity at all. It hands the service a [MediaHost] over the graph, tells
 * the model when a car comes and goes, serves the car's covers, and keeps the
 * service bound while a book is playing so its session and notification
 * exist.
 */
class AppMedia(private val graph: AppGraph) {
    /**
     * Whether a car is connected, and the surface with it. Connecting makes
     * the car the surface the controls resolve against; disconnecting hands
     * the listening back to the reader on the phone, as CarPlay's
     * disconnecting does.
     */
    val carPresence = CarPresence { connected ->
        IssaLog.info(if (connected) "android auto connected" else "android auto disconnected")
        graph.setCarConnected(connected)
    }

    val host: MediaHost = AppMediaHost(graph, carPresence)

    private val connection = PlaybackConnection(graph.context, graph.mainScope, graph.nowPlaying)
    private var carWatch: AutoCloseable? = null
    private var started = false

    /** Starts watching for the car and for playback. Idempotent. */
    fun start() {
        if (started) return
        started = true
        val covers = CoverCache.shared
        CarCovers.install(
            object : CarCovers.Source {
                // Read once, here: the provider asks from its binder threads.
                override val directory: File = covers.fileFor("cover").parentFile ?: File(".")

                override suspend fun fetch(book: Book): File? {
                    val session = graph.app.session ?: return null
                    return covers.file(book, session, LibraryService.CoverShape.SQUARE, CarCovers.PIXELS)
                }
            },
        )
        // The car library is a guest here: an Android Auto that answers
        // nothing is a car the controllers' fallback still finds.
        carWatch = runCatching { CarPresence.watch(graph.context, carPresence) }
            .onFailure { IssaLog.failure("car connection watch", it) }
            .getOrNull()
        connection.start()
    }
}

/**
 * The rate button's press: CarPlay's `onCycleRate`, through the rates a driver
 * actually wants, wrapping round — there is no menu in a car. The listener's
 * speed, so it is saved as well as applied.
 */
object CarRate {
    fun cycle(settings: PlaybackSettings, nowPlaying: NowPlayingController) {
        val next = SessionTransport.nextCarRate(settings.playbackRate)
        settings.playbackRate = next
        nowPlaying.coordinator?.player?.rate = next.toFloat()
        nowPlaying.publish()
    }
}

/** [MediaHost] over the app's graph. */
internal class AppMediaHost(private val graph: AppGraph, override val carPresence: CarPresence) : MediaHost {
    private val app: AppModel get() = graph.app

    override val router: CommandRouter get() = graph.nowPlaying.remote

    override fun attachSink(sink: NowPlayingSink?) {
        graph.nowPlaying.sink = sink
    }

    override val access: MediaHost.Access
        get() = access(app.phase)

    override val catalogue: CarCatalogue
        get() = AutoBrowseTree.catalogue(app.books, app.downloadedUuids, app.localBookUuids())

    override fun observeLibrary(onChange: () -> Unit): AutoCloseable {
        val job = graph.mainScope.launch {
            snapshotFlow { Triple(app.books, app.downloadedUuids, access(app.phase)) }
                .distinctUntilChanged()
                .drop(1)
                .collect { onChange() }
        }
        return AutoCloseable { job.cancel() }
    }

    override suspend fun awaitLibrary() {
        withTimeoutOrNull(LIBRARY_WAIT_MILLIS) {
            snapshotFlow { access(app.phase) }.first { it != MediaHost.Access.LOADING }
        }
    }

    override suspend fun startListening(bookUuid: String): String? = graph.startListeningFromCar(bookUuid)

    override fun cycleRate() = graph.cycleRateFromCar()

    override val playbackRate: Double get() = graph.settings.playbackRate

    override val playing: MediaHost.Playing?
        get() {
            val book = graph.nowPlaying.book ?: return null
            val player = graph.nowPlaying.coordinator?.player ?: return null
            return MediaHost.Playing(book, player.isPlaying, player.rate)
        }

    /**
     * Chapters from whichever engine is playing. The audiobook engine is what
     * the car itself starts; narration begun from the reader before or
     * during a drive plays through the reader's read-along instead, which
     * has no chapter list — only a table of contents.
     */
    override fun chapters(): List<String> {
        app.listening?.let { coordinator -> return coordinator.chapters.map { it.title } }
        val epubPackage = app.reader?.epubPackage ?: return emptyList()
        return AutoChapters.entries(epubPackage).map { it.title }
    }

    override fun currentChapter(): Int? {
        app.listening?.let { return it.chapterIndex }
        val reader = app.reader ?: return null
        val epubPackage = reader.epubPackage ?: return null
        // By the page's place in its file, not the file alone: several
        // chapters can share one, and each has its own row.
        val layout = reader.layout
        return AutoChapters.currentIndex(
            AutoChapters.entries(epubPackage),
            spineIndex = reader.chapterIndex,
            offset = reader.currentPage?.characterRange?.location ?: 0,
        ) { layout?.fragmentRange(it)?.location }
    }

    override suspend fun playChapter(index: Int) {
        app.listening?.let {
            it.playChapter(index)
            return
        }
        val reader = app.reader ?: return
        val epubPackage = reader.epubPackage ?: return
        val entries = AutoChapters.entries(epubPackage)
        val entry = entries.getOrNull(index) ?: return
        reader.go(toChapter = entry.spineIndex, fragment = entry.fragment)
        // The car asked to *play* the chapter. Turning the page alone left the
        // voice in the old chapter, and the jump was then saved as the
        // listener's chosen place.
        reader.playFirstSentenceOnPage()
    }

    override suspend fun searchLibrary(query: String): List<Book> =
        runCatching { app.store?.search(query) }.getOrNull().orEmpty()

    companion object {
        /** How long a car connecting to a cold process waits for the library before showing what there is. */
        const val LIBRARY_WAIT_MILLIS = 10_000L

        fun access(phase: AppModel.Phase): MediaHost.Access = when (phase) {
            // Re-identifying a stored session passes through signing in.
            AppModel.Phase.LAUNCHING, AppModel.Phase.SIGNING_IN -> MediaHost.Access.LOADING
            AppModel.Phase.READY -> MediaHost.Access.READY
            AppModel.Phase.CHOOSE_SERVER, AppModel.Phase.EXPIRED -> MediaHost.Access.SIGNED_OUT
        }
    }
}

/**
 * The app's own connection to its media session, held while a book is
 * playing or paused, so the service — and with it the session, the
 * notification and the lock screen's controls — exists for as long as there
 * is something to control. Media3 takes the service into the foreground when
 * the book plays and out of it when it pauses.
 *
 * Playback itself is driven by the model, never through this controller:
 * the coordinators decide every move, and the session presents them.
 */
class PlaybackConnection(
    private val context: Context,
    private val scope: CoroutineScope,
    private val nowPlaying: NowPlayingController,
) {
    private var controller: ListenableFuture<MediaController>? = null

    /** Whether the service is bound now. */
    val isConnected: Boolean get() = controller != null

    fun start() {
        scope.launch {
            snapshotFlow { nowPlaying.coordinator != null }.distinctUntilChanged().collect { attached ->
                if (attached) connect() else disconnect()
            }
        }
    }

    private fun connect() {
        if (controller != null) return
        val token = SessionToken(context, ComponentName(context, IssaPlaybackService::class.java))
        controller = MediaController.Builder(context, token).buildAsync()
    }

    private fun disconnect() {
        val held = controller ?: return
        controller = null
        MediaController.releaseFuture(held)
    }
}
