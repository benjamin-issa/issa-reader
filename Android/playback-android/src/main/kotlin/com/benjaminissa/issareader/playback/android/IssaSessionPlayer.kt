package com.benjaminissa.issareader.playback.android

import android.os.Looper
import android.os.SystemClock
import androidx.annotation.OptIn
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.SimpleBasePlayer
import androidx.media3.common.util.UnstableApi
import com.benjaminissa.issareader.playback.CommandRouter
import com.benjaminissa.issareader.playback.ControlSurface
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import com.google.common.util.concurrent.MoreExecutors

/**
 * The listening session as Media3 sees it: the player a `MediaSession` holds,
 * which is not the engine.
 *
 * What plays is `AudioPlayer` over an [ExoMediaBackend], owned by a
 * coordinator that decides every move — a read-along's sentence boundaries,
 * an audiobook's chapter list, the position guard. Handing Media3 that
 * ExoPlayer would let the lock screen and the car drive it behind the
 * coordinator's back, so this player only *presents*: its state is the
 * [SessionPresentation] the app publishes, and every command it receives goes
 * through [CommandRouter], the one funnel Swift's `RemoteCommandCenter` was, so
 * the reader's per-surface bindings decide what a button does.
 *
 * - **State** is the book playing: playing or paused (or buffering, through a
 *   stall), the position within the published span — the chapter's or the
 *   book's, as the reader chose — its duration, and the chosen speed.
 * - **The playlist is the chapters**, which is Android Auto's queue: CarPlay's
 *   Up Next, with the chapter playing as the current item. Picking another
 *   plays it from its start.
 * - **Commands are attributed** to the surface that sent them
 *   ([Delegate.requestSurface]) — the car, the phone — or left to
 *   [CommandRouter]'s inference where the sender says nothing.
 *
 * Main-thread only, like the coordinators it fronts.
 */
@OptIn(UnstableApi::class)
class IssaSessionPlayer(
    private val router: CommandRouter,
    private val delegate: Delegate,
    looper: Looper = Looper.getMainLooper(),
) : SimpleBasePlayer(looper) {
    /** What the session asks of the app. */
    interface Delegate {
        /**
         * The surface the command being handled came from, or null to infer it.
         * Asked while a command runs, which is when the session can say.
         */
        fun requestSurface(): ControlSurface?

        /**
         * A controller set what should play: a book from the car's list, a
         * voice search's best match, the book to resume. The future settles
         * when the start has — successfully or not — so the session's
         * placeholder state lasts exactly as long as the start does.
         */
        fun setMediaItems(items: List<MediaItem>, startIndex: Int, startPositionMs: Long): ListenableFuture<*>

        /** A chapter picked from the queue, played from its start. */
        fun playChapter(index: Int): ListenableFuture<*>
    }

    /** What is shown now, or null while nothing is playing. */
    var presentation: SessionPresentation? = null
        private set

    /** When [presentation] was taken, for the clock to run on from. */
    private var presentedAt = 0L

    /** Starts a controller asked for that have not settled. */
    private var startsInFlight = 0

    /** The skip intervals the session advertises, in milliseconds. */
    private var seekBackMillis = DEFAULT_SEEK_BACK_MILLIS
    private var seekForwardMillis = DEFAULT_SEEK_FORWARD_MILLIS

    /** Shows [presentation]. A no-op when nothing changed, so a five-second republish costs nothing. */
    fun present(presentation: SessionPresentation?) {
        if (this.presentation == presentation) return
        this.presentation = presentation
        presentedAt = SystemClock.elapsedRealtime()
        invalidateState()
    }

    /** The intervals the system's skip buttons carry, from the command map. */
    fun setSkipIntervals(backSeconds: Double, forwardSeconds: Double) {
        val back = (backSeconds * 1000).toLong().coerceAtLeast(1)
        val forward = (forwardSeconds * 1000).toLong().coerceAtLeast(1)
        if (back == seekBackMillis && forward == seekForwardMillis) return
        seekBackMillis = back
        seekForwardMillis = forward
        invalidateState()
    }

    override fun getState(): State {
        val builder = State.Builder()
            .setAvailableCommands(AVAILABLE_COMMANDS)
            .setAudioAttributes(SPOKEN)
            .setRepeatMode(Player.REPEAT_MODE_OFF)
            .setSeekBackIncrementMs(seekBackMillis)
            .setSeekForwardIncrementMs(seekForwardMillis)
            .setPlaylistMetadata(QUEUE)
        val shown = presentation ?: return builder
            .setPlaylist(emptyList())
            .setPlaybackState(Player.STATE_IDLE)
            .setPlayWhenReady(false, Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)
            .build()

        // A book with no chapters to name is one item, so the car still has
        // something to show as playing.
        val titles = shown.chapters.ifEmpty { listOf(shown.chapter ?: shown.title) }
        val current = (shown.chapterIndex ?: 0).coerceIn(0, titles.lastIndex)
        val durationMillis = if (shown.duration.isFinite() && shown.duration > 0) (shown.duration * 1000).toLong() else C.TIME_UNSET
        val playlist = titles.mapIndexed { index, title ->
            MediaItemData.Builder(SessionMediaIds.chapter(shown.bookId, index))
                .setMediaItem(chapterItem(shown.bookId, index, title))
                .setIsSeekable(true)
                .setDurationUs(if (index == current && durationMillis != C.TIME_UNSET) durationMillis * 1000 else C.TIME_UNSET)
                // The current chapter's row is the queue's; the Now Playing
                // metadata — the book, its byline, the chapter, the cover — is
                // this, which the session reads instead.
                .setMediaMetadata(if (index == current) nowPlaying(shown) else null)
                .build()
        }
        return builder
            .setPlaylist(playlist)
            .setCurrentMediaItemIndex(current)
            .setContentPositionMs(position(shown, durationMillis))
            .setPlayWhenReady(shown.isPlaying, Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)
            .setPlaybackState(if (shown.isPlaying && shown.effectiveRate <= 0f) Player.STATE_BUFFERING else Player.STATE_READY)
            .setPlaybackParameters(PlaybackParameters(if (shown.rate > 0f) shown.rate else 1f))
            .build()
    }

    /**
     * Where the bar is, running on at the rate the audio actually moves from
     * the moment it was published — not from whenever the session asks, which
     * would set it back every time it did.
     */
    private fun position(shown: SessionPresentation, durationMillis: Long): PositionSupplier {
        val elapsed = if (shown.elapsed.isFinite()) (shown.elapsed * 1000).toLong().coerceAtLeast(0) else 0L
        val rate = shown.effectiveRate
        if (rate <= 0f) return PositionSupplier.getConstant(elapsed)
        val from = presentedAt
        return PositionSupplier {
            val moved = elapsed + ((SystemClock.elapsedRealtime() - from) * rate).toLong()
            if (durationMillis != C.TIME_UNSET) minOf(moved, durationMillis) else moved
        }
    }

    // Commands. Each goes through the router, which consults the bindings at
    // the moment it fires, or to the app for what only it can do.

    override fun handleSetPlayWhenReady(playWhenReady: Boolean): ListenableFuture<*> {
        // A start a controller asked for plays by itself once it has a place
        // to play from. Passing this on meanwhile would resume whatever was
        // playing before — two voices, or the wrong book, for a moment.
        if (startsInFlight > 0) return Futures.immediateVoidFuture()
        // Discrete, never the toggle: the system already says which it means.
        if (playWhenReady) router.play() else router.pause()
        return Futures.immediateVoidFuture()
    }

    override fun handlePrepare(): ListenableFuture<*> = Futures.immediateVoidFuture()

    /** Stopping from the notification pauses: there is nothing else to stop, and the place is kept. */
    override fun handleStop(): ListenableFuture<*> {
        router.pause()
        return Futures.immediateVoidFuture()
    }

    override fun handleRelease(): ListenableFuture<*> = Futures.immediateVoidFuture()

    override fun handleSetPlaybackParameters(playbackParameters: PlaybackParameters): ListenableFuture<*> {
        // Clamped by whoever listens, as the lock screen's speed always was.
        router.changeRate(playbackParameters.speed)
        return Futures.immediateVoidFuture()
    }

    override fun handleSetMediaItems(mediaItems: List<MediaItem>, startIndex: Int, startPositionMs: Long): ListenableFuture<*> {
        startsInFlight += 1
        val started = delegate.setMediaItems(mediaItems, startIndex, startPositionMs)
        started.addListener({
            startsInFlight -= 1
            invalidateState()
        }, MoreExecutors.directExecutor())
        return started
    }

    /**
     * Every seek is read by the command that asked for it, not by where
     * Media3 would have landed: a "next" is the wheel's `»`, whatever the
     * reader bound it to, and the system's skip buttons are the tap controls.
     */
    override fun handleSeek(mediaItemIndex: Int, positionMs: Long, seekCommand: Int): ListenableFuture<*> {
        val from = delegate.requestSurface()
        when (seekCommand) {
            Player.COMMAND_SEEK_BACK -> router.skipBackward(from)
            Player.COMMAND_SEEK_FORWARD -> router.skipForward(from)
            Player.COMMAND_SEEK_TO_NEXT, Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM -> router.nextTrack(from)
            Player.COMMAND_SEEK_TO_PREVIOUS, Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM -> router.previousTrack(from)
            Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM -> seekWithin(positionMs)
            Player.COMMAND_SEEK_TO_DEFAULT_POSITION -> return delegate.playChapter(currentMediaItemIndex)
            Player.COMMAND_SEEK_TO_MEDIA_ITEM -> {
                // The queue: a chapter picked plays from its start. A position
                // inside the chapter already playing is a scrub.
                if (mediaItemIndex == currentMediaItemIndex && positionMs != C.TIME_UNSET && positionMs > 0) {
                    seekWithin(positionMs)
                } else if (mediaItemIndex >= 0) {
                    return delegate.playChapter(mediaItemIndex)
                }
            }
        }
        return Futures.immediateVoidFuture()
    }

    /** A drag on the bar, in the published span's own seconds; the router's listener inverts the scope. */
    private fun seekWithin(positionMs: Long) {
        if (positionMs == C.TIME_UNSET) return
        router.seekTo(positionMs.coerceAtLeast(0) / 1000.0)
    }

    companion object {
        const val DEFAULT_SEEK_BACK_MILLIS = 15_000L
        const val DEFAULT_SEEK_FORWARD_MILLIS = 30_000L

        /** CarPlay called its Up Next list "Chapters"; the queue keeps the name. */
        const val QUEUE_TITLE = "Chapters"

        private val QUEUE: MediaMetadata = MediaMetadata.Builder().setTitle(QUEUE_TITLE).build()

        /** Speech, as the engine declares it. */
        private val SPOKEN: AudioAttributes = AudioAttributes.Builder()
            .setUsage(C.USAGE_MEDIA)
            .setContentType(C.AUDIO_CONTENT_TYPE_SPEECH)
            .build()

        /**
         * Everything this player answers. Each controller is offered a subset
         * of it — the track pair only where the bindings say so; see
         * [SessionTransport].
         */
        val AVAILABLE_COMMANDS: Player.Commands = Player.Commands.Builder()
            .addAll(
                Player.COMMAND_PLAY_PAUSE,
                Player.COMMAND_PREPARE,
                Player.COMMAND_STOP,
                Player.COMMAND_SEEK_TO_DEFAULT_POSITION,
                Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM,
                Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM,
                Player.COMMAND_SEEK_TO_PREVIOUS,
                Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM,
                Player.COMMAND_SEEK_TO_NEXT,
                Player.COMMAND_SEEK_TO_MEDIA_ITEM,
                Player.COMMAND_SEEK_BACK,
                Player.COMMAND_SEEK_FORWARD,
                Player.COMMAND_SET_SPEED_AND_PITCH,
                Player.COMMAND_GET_CURRENT_MEDIA_ITEM,
                Player.COMMAND_GET_TIMELINE,
                Player.COMMAND_GET_METADATA,
                Player.COMMAND_SET_MEDIA_ITEM,
                Player.COMMAND_GET_AUDIO_ATTRIBUTES,
                Player.COMMAND_RELEASE,
            )
            .build()

        /** A row of the queue: the chapter's name and nothing else. */
        fun chapterItem(bookId: String, index: Int, title: String): MediaItem = MediaItem.Builder()
            .setMediaId(SessionMediaIds.chapter(bookId, index))
            .setMediaMetadata(
                MediaMetadata.Builder()
                    .setTitle(title)
                    .setDisplayTitle(title)
                    .setIsPlayable(true)
                    .setIsBrowsable(false)
                    .setMediaType(MediaMetadata.MEDIA_TYPE_AUDIO_BOOK_CHAPTER)
                    .build(),
            )
            .build()

        /**
         * Now Playing: the book as the title, the byline as the artist, the
         * chapter as the album — the real chapter, not the title a second time —
         * and the square cover.
         */
        fun nowPlaying(shown: SessionPresentation): MediaMetadata = MediaMetadata.Builder()
            .setTitle(shown.title)
            .setArtist(shown.artist)
            .setAlbumTitle(shown.chapter)
            .setArtworkData(shown.artworkData, MediaMetadata.PICTURE_TYPE_FRONT_COVER)
            .setArtworkUri(shown.artworkUri)
            .setIsPlayable(true)
            .setIsBrowsable(false)
            .setMediaType(MediaMetadata.MEDIA_TYPE_AUDIO_BOOK_CHAPTER)
            .build()
    }
}
