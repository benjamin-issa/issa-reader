package com.benjaminissa.issareader.app.model

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.benjaminissa.issareader.core.Session
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.sync.LibraryService
import com.benjaminissa.issareader.playback.AudiobookCoordinator
import com.benjaminissa.issareader.playback.CommandRouter
import com.benjaminissa.issareader.playback.ControlSurface
import com.benjaminissa.issareader.playback.PlaybackDriving
import com.benjaminissa.issareader.playback.PlaybackProgress
import com.benjaminissa.issareader.playback.PlaybackRate
import com.benjaminissa.issareader.playback.ProgressScope
import com.benjaminissa.issareader.playback.ReadalongCoordinator
import com.benjaminissa.issareader.playback.SleepTimer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Where the system's Now Playing surfaces are drawn: the media session, its
 * notification and lock-screen controls, and Android Auto.
 *
 * The media-session service implements this (and drives [NowPlayingController.remote]
 * from the session's callbacks); until it is attached nothing is published,
 * and attaching it republishes what is playing.
 */
interface NowPlayingSink {
    /**
     * What is playing, or null when nothing is.
     *
     * @param artwork the cover's bytes, already checked to decode, or null.
     */
    fun publish(entry: CommandRouter.NowPlaying?, artwork: ByteArray?)
}

/**
 * Connects whatever is playing to the system's Now Playing surfaces.
 *
 * One controller owns the remote-command routing for the whole app, so the
 * lock screen, headphone buttons, Android Auto's transport and a car's
 * steering-wheel controls all resolve through the same [CommandMap]
 * ([CommandRouter]). Deliberately not owned by a screen: playback outlives the
 * reader.
 *
 * Observable for the player sheet: [coordinator], [book] and [sleepTimer] are
 * snapshot state. Main-thread only.
 *
 * @param scope a main-thread scope whose dispatcher posts (the coordinators'
 *   own), for the five-second republish and the artwork fetches.
 */
class NowPlayingController(private val scope: CoroutineScope) {
    var coordinator: PlaybackDriving? by mutableStateOf(null)
        private set
    var book: Book? by mutableStateOf(null)
        private set

    /**
     * Owned here rather than by the player sheet: a sleep timer that dies when
     * the sheet is dismissed is a sleep timer that never once worked.
     */
    var sleepTimer: SleepTimer? by mutableStateOf(null)
        private set

    /**
     * Told when a sleep timer runs out, after the book has stopped. `AppModel`
     * listens so an open book's screen may lock again.
     */
    var onSleepTimerExpired: (() -> Unit)? = null

    /** The commands' routing, which the media session calls into and reads its transport from. */
    val remote: CommandRouter = CommandRouter()

    /** Where Now Playing is drawn. Assigning one republishes. */
    var sink: NowPlayingSink? = null
        set(value) {
            field = value
            if (coordinator == null) value?.publish(null, null) else publish()
        }

    /** Cover art for the lock screen and the car, as bytes. */
    private var artwork: ByteArray? = null
    private var session: Session? = null

    /** The cover on disk, for a book from the reader's own files: there is no server to fetch one from. */
    private var artworkFile: File? = null
    private var settings: PlaybackSettings? = null
    private var refreshTask: Job? = null

    /** Stamps each artwork fetch so one that outlives its book cannot land. */
    private var artworkGeneration = 0

    /**
     * How many times the command routing has been re-registered: the unit of
     * the bug where every configure and every reader window re-registered the
     * whole set.
     */
    var remoteActivations: Int = 0
        private set

    private var settingsObservation: AutoCloseable? = null

    private var currentChapterTitle: () -> String? = { null }

    /**
     * Idempotent: a second call with the same settings object is the same
     * configuration and has nothing to do. A different object is a real
     * reconfiguration, and the previous one stops being observed.
     */
    fun configure(settings: PlaybackSettings) {
        if (this.settings === settings) return
        this.settings = settings
        remote.commandMap = settings.commandMap
        remote.onAction = action@{ action ->
            val coordinator = coordinator ?: return@action
            val live = this.settings ?: return@action
            scope.launch {
                coordinator.perform(action, live.commandMap)
                publish()
            }
        }
        remote.onSeek = seek@{ seconds ->
            val coordinator = coordinator ?: return@seek
            // The system reports the drag in the units of the duration it was
            // given, so this inverts exactly what `publish` sent.
            val target = readout(coordinator).bookProgressForSeconds(seconds)
            scope.launch {
                coordinator.seekToBookProgress(target)
                publish()
            }
        }
        remote.onRateChange = { rate ->
            // Clamped: the value is the system's to populate.
            val legal = PlaybackRate.clamped(rate.toDouble())
            coordinator?.player?.rate = legal.toFloat()
            this.settings?.playbackRate = legal
        }
        remote.activate()
        remoteActivations += 1
        settingsObservation?.close()
        // Keeps the system's buttons in step with the reader's choices: a
        // binding or a skip amount changed in Settings reaches the transport
        // at once, and a change of progress scope republishes what the lock
        // screen's numbers mean.
        settingsObservation = settings.observePlayback {
            syncCommandMap()
            publish()
        }
    }

    /**
     * Called when a book starts playing, and again when it stops.
     *
     * Idempotent for the same engine and the same book: this rebuilds the
     * sleep timer from scratch, and a rebuilt timer is a disarmed one, so
     * re-attaching the same pair used to cancel a timer the listener had set.
     */
    fun attach(
        coordinator: PlaybackDriving?,
        book: Book?,
        session: Session? = null,
        artworkFile: File? = null,
        chapterTitle: () -> String? = { null },
    ) {
        // Identity for the engine, uuid for the book: the `Book` value is
        // rebuilt by every position write.
        if (coordinator != null && book != null && this.coordinator === coordinator && this.book?.uuid == book.uuid) {
            return
        }

        // Captured before anything is replaced: `cancel()` resets the mode.
        val previousBook = this.book?.uuid
        val armed = sleepTimer?.let { it.mode to it.remaining }
        // Cancelled, not merely dropped: `cancel()` is the only caller of
        // `fade(1)`, so replacing the timer mid-fade left the outgoing engine
        // stuck at whatever level the fade had reached.
        sleepTimer?.cancel()

        this.coordinator = coordinator
        this.book = book
        this.session = session
        this.artworkFile = artworkFile
        currentChapterTitle = chapterTitle
        refreshTask?.cancel()
        refreshTask = null
        artwork = null
        // Detaching must also invalidate any fetch still in flight.
        artworkGeneration += 1

        if (coordinator == null || book == null) {
            sleepTimer = null
            sink?.publish(null, null)
            return
        }

        // The timer pauses playback and fades the last seconds rather than
        // cutting off mid-word — and, being the end of listening for the night,
        // gives the audio route back.
        val timer = SleepTimer(
            scope = scope,
            onExpire = {
                coordinator.player.endSession()
                onSleepTimerExpired?.invoke()
            },
            fade = { level -> coordinator.player.volume = level },
        )
        // A duration timer counts time spent listening, not wall-clock time.
        timer.isPlaying = { coordinator.player.isPlaying }
        sleepTimer = timer
        // "End of chapter" is driven by the audio running off the end of one,
        // and only by that: a chapter the listener picked is not a chapter
        // ending.
        when (coordinator) {
            is ReadalongCoordinator -> coordinator.onChapterChangeObserved = {
                timer.chapterDidEnd()
                publish()
            }
            is AudiobookCoordinator -> {
                coordinator.onChapterChangeObserved = { timer.chapterDidEnd() }
                coordinator.onChapterChange = { publish() }
            }
        }
        // Publish the moment anything changes, rather than waiting up to five
        // seconds for the poll.
        coordinator.player.setRateObserver(this) { publish() }
        // A speed chosen from a bound control is the listener's speed.
        coordinator.player.onRateChosen = { rate -> settings?.playbackRate = rate.toDouble() }

        // A sleep timer set before the engine changed hands, carried across —
        // for the same book only. The duration transfers as what is left.
        if (armed != null && previousBook == book.uuid) {
            when (val mode = armed.first) {
                SleepTimer.Mode.Off -> Unit
                SleepTimer.Mode.EndOfChapter -> timer.start(SleepTimer.Mode.EndOfChapter)
                is SleepTimer.Mode.Duration -> timer.start(SleepTimer.Mode.Duration(armed.second ?: mode.seconds))
            }
        }

        loadArtwork(book)
        // A periodic refresh keeps the scrubber honest without publishing on
        // every tick.
        refreshTask = scope.launch {
            while (isActive) {
                publish()
                delay(REFRESH_MILLIS)
            }
        }
    }

    /**
     * Bindings resolve against the surface the command came from, so the
     * wheel can mean one thing in the car and another on the sofa.
     */
    fun setSurface(surface: ControlSurface) {
        remote.activeSurface = surface
    }

    fun syncCommandMap() {
        val settings = settings ?: return
        remote.commandMap = settings.commandMap
        remote.activate()
        remoteActivations += 1
    }

    /** What the system's bar should show, under the reader's chosen scope. */
    private fun readout(coordinator: PlaybackDriving): PlaybackProgress = PlaybackProgress(
        scope = settings?.progressScope ?: ProgressScope.BOOK,
        bookProgress = coordinator.bookProgress,
        totalDuration = coordinator.totalDuration,
        chapterSpan = coordinator.chapterSpan,
    )

    /** What the system is told now, for the tests and the service. */
    var published: CommandRouter.NowPlaying? = null
        private set

    fun publish() {
        val coordinator = coordinator ?: return
        val book = book ?: return
        val progress = readout(coordinator)
        val total = progress.spanDuration
        val elapsed = progress.elapsed
        // Never hand the system a number it cannot hold: it extrapolates from
        // the last value, so publishing nothing leaves the last good one.
        if (!total.isFinite() || total <= 0 || !elapsed.isFinite()) return
        val entry = CommandRouter.nowPlaying(
            title = book.title,
            author = book.byline,
            chapter = currentChapterTitle(),
            elapsed = elapsed,
            duration = total,
            // From the player, not from intent: through a buffering stall the
            // clock must stop.
            rate = coordinator.player.effectiveRate,
        )
        published = entry
        sink?.publish(entry, artwork)
    }

    /**
     * Fetches the square audiobook cover: the right shape for a Now Playing
     * tile, where the portrait ebook cover would be letterboxed.
     */
    private fun loadArtwork(book: Book) {
        artworkFile?.let {
            loadArtwork(it)
            return
        }
        val session = session ?: return
        artworkGeneration += 1
        val generation = artworkGeneration
        scope.launch {
            val data = try {
                LibraryService(session.client).coverData(book, LibraryService.CoverShape.SQUARE, pixelWidth = 600)
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (_: Exception) {
                return@launch
            }
            if (!CoverCache.isImage(data)) return@launch
            // A slow fetch for a previous book must not overwrite the current one.
            if (artworkGeneration != generation) return@launch
            artwork = data
            publish()
        }
    }

    /** The cover cut from a local book at import, read off the disk. Never a request. */
    private fun loadArtwork(file: File) {
        artworkGeneration += 1
        val generation = artworkGeneration
        scope.launch {
            val data = withContext(Dispatchers.IO) { runCatching { file.readBytes() }.getOrNull() } ?: return@launch
            if (!CoverCache.isImage(data) || artworkGeneration != generation) return@launch
            artwork = data
            publish()
        }
    }

    companion object {
        const val REFRESH_MILLIS = 5_000L
    }
}
