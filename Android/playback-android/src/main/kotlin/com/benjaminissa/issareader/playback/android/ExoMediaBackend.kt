package com.benjaminissa.issareader.playback.android

import android.content.Context
import android.media.AudioManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.annotation.OptIn
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.Timeline
import androidx.media3.common.audio.AudioFocusRequestCompat
import androidx.media3.common.audio.AudioManagerCompat
import androidx.media3.common.util.Clock
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.SeekParameters
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.extractor.DefaultExtractorsFactory
import androidx.media3.extractor.mp3.Mp3Extractor
import com.benjaminissa.issareader.core.diagnostics.IssaLog
import com.benjaminissa.issareader.playback.AudioLocation
import com.benjaminissa.issareader.playback.MediaBackend
import com.benjaminissa.issareader.playback.MediaTime
import kotlinx.coroutines.CompletableDeferred
import okhttp3.Call
import java.io.IOException
import kotlin.math.ceil

/**
 * [MediaBackend] over one Media3 [ExoPlayer], holding one item at a time as
 * iOS's `AVQueuePlayer` is used.
 *
 * What it is configured for, and why:
 *
 * - **Exact seeks.** [SeekParameters.EXACT], and an MP3 extractor that builds
 *   a time-to-byte index as it reads (`FLAG_ENABLE_INDEX_SEEKING`) with
 *   constant-bitrate seeking enabled for files that have no index of their
 *   own. A read-along highlight lands on the wrong sentence if the engine
 *   rounds to the nearest keyframe or estimates a byte offset from a bitrate.
 *   Index seeking reads a file from its start to reach a place it has not
 *   indexed yet, which is nothing for an extracted narration chunk and a long
 *   download for a ten-hour streamed upload; so streams use constant-bitrate
 *   seeking unless [indexSeekingForStreams] says otherwise. Targets are
 *   rounded *up* onto the millisecond grid, as [AudioPlayer] rounds them up
 *   onto 1/600 s, so a seek never lands a hair before the sentence it names.
 * - **Spoken audio.** `USAGE_MEDIA` with `AUDIO_CONTENT_TYPE_SPEECH`, and
 *   speed through Sonic with the pitch held at 1 — narration at 1.5–3× is
 *   unlistenable without it.
 * - **Audio focus**, requested here rather than left to ExoPlayer, because
 *   [AudioPlayer] owns the interruption decision exactly as on iOS: it pauses
 *   when one begins, latches whether it was playing, and resumes only a
 *   listener who was listening and did not pause meanwhile. ExoPlayer's own
 *   focus handling resumes by itself behind that decision and cannot report
 *   the end of an interruption once the player has paused. A transient loss,
 *   or one that would duck — speech pauses rather than talk under something
 *   else — is an interruption that begins; regaining focus ends it, expecting
 *   a resume; a permanent loss begins one that never ends. Focus is requested
 *   when playback is asked for and abandoned at the ends of listening.
 * - **Becoming noisy** — headphones out, a Bluetooth device gone — handled by
 *   ExoPlayer, which pauses, and reported as a lost route.
 * - **Network** through the caller's OkHttp client, with the headers each
 *   [AudioLocation.Remote] carries: the session token as a bearer and as the
 *   `st_token` cookie the server's audio routes expect.
 * - **The gain stage** after Sonic: see [GainRenderersFactory].
 *
 * Main-thread-only: built on the main thread, called on it, and calling back
 * on it.
 *
 * @param httpClient what streams are fetched with — the app's own client, so
 *   they share its connection pool and its TLS settings.
 * @param clock for a test's fake clock; the system's otherwise.
 */
@OptIn(UnstableApi::class)
class ExoMediaBackend(
    private val context: Context,
    private val httpClient: Call.Factory,
    private val indexSeekingForStreams: Boolean = false,
    clock: Clock? = null,
) : MediaBackend {
    /** The gain stage every item's audio passes through. */
    val gainProcessor = GainKneeAudioProcessor()

    private val handler = Handler(Looper.getMainLooper())

    private val attributes = AudioAttributes.Builder()
        .setUsage(C.USAGE_MEDIA)
        .setContentType(C.AUDIO_CONTENT_TYPE_SPEECH)
        .build()

    /**
     * The engine, for the media session layer to present. Not to be driven
     * directly: [AudioPlayer] owns what plays and when, and a command sent here
     * would be one it never heard about.
     */
    val exoPlayer: ExoPlayer = ExoPlayer.Builder(context, GainRenderersFactory(context, gainProcessor))
        .setLooper(Looper.getMainLooper())
        .setSeekParameters(SeekParameters.EXACT)
        .setAudioAttributes(attributes, /* handleAudioFocus = */ false)
        .setHandleAudioBecomingNoisy(true)
        .apply { if (clock != null) setClock(clock) }
        .build()

    private val localExtractors = DefaultExtractorsFactory()
        .setMp3ExtractorFlags(Mp3Extractor.FLAG_ENABLE_INDEX_SEEKING)
        .setConstantBitrateSeekingEnabled(true)

    private val streamExtractors = DefaultExtractorsFactory()
        .setMp3ExtractorFlags(if (indexSeekingForStreams) Mp3Extractor.FLAG_ENABLE_INDEX_SEEKING else 0)
        .setConstantBitrateSeekingEnabled(true)

    override var sessionListener: MediaBackend.SessionListener? = null

    private var item: Item? = null
    private var pendingSeek: CompletableDeferred<Boolean>? = null

    init {
        exoPlayer.addListener(object : Player.Listener {
            override fun onTimelineChanged(timeline: Timeline, reason: Int) {
                item?.resolveDuration(ready = false)
            }

            override fun onPlaybackStateChanged(playbackState: Int) {
                val current = item ?: return
                when (playbackState) {
                    Player.STATE_READY -> {
                        current.resolveDuration(ready = true)
                        settleSeek(true)
                    }
                    Player.STATE_ENDED -> {
                        current.resolveDuration(ready = true)
                        settleSeek(true)
                        current.listener.onPlayedToEnd()
                    }
                    Player.STATE_IDLE -> settleSeek(false)
                    else -> Unit
                }
            }

            override fun onPlayerError(error: PlaybackException) {
                item?.fail("${error.errorCodeName}: ${error.message}")
            }

            override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
                if (!playWhenReady && reason == Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_BECOMING_NOISY) {
                    sessionListener?.onRouteLost()
                }
            }
        })
    }

    // The session

    private val audioManager: AudioManager = AudioManagerCompat.getAudioManager(context)
    private var focusHeld = false
    private var transientLoss = false

    private val focusRequest: AudioFocusRequestCompat =
        AudioFocusRequestCompat.Builder(AudioManagerCompat.AUDIOFOCUS_GAIN)
            .setAudioAttributes(attributes)
            // Speech pauses rather than talking under something else.
            .setWillPauseWhenDucked(true)
            .setOnAudioFocusChangeListener({ change -> focusChanged(change) }, handler)
            .build()

    private fun focusChanged(change: Int) {
        when (change) {
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT, AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                transientLoss = true
                sessionListener?.onInterruptionBegan()
            }
            AudioManager.AUDIOFOCUS_LOSS -> {
                // Gone for good: another player has the route. Given back, so
                // the next play asks again.
                transientLoss = false
                abandonFocus()
                sessionListener?.onInterruptionBegan()
            }
            AudioManager.AUDIOFOCUS_GAIN -> {
                if (!transientLoss) return
                transientLoss = false
                sessionListener?.onInterruptionEnded(shouldResume = true)
            }
        }
    }

    /** Declaring the session costs nothing on Android: the attributes are on the player already. */
    override fun configureSession() = Unit

    override fun activateSession() {
        if (focusHeld) return
        val result = AudioManagerCompat.requestAudioFocus(audioManager, focusRequest)
        focusHeld = result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        if (!focusHeld) IssaLog.info("audio focus refused", mapOf("result" to result.toString()))
        applyRate()
    }

    override fun deactivateSession() {
        transientLoss = false
        abandonFocus()
    }

    private fun abandonFocus() {
        if (!focusHeld) return
        AudioManagerCompat.abandonAudioFocusRequest(audioManager, focusRequest)
        focusHeld = false
        applyRate()
    }

    // The item

    override val currentItem: MediaBackend.Item? get() = item

    override fun replaceItem(location: AudioLocation, listener: MediaBackend.ItemListener): MediaBackend.Item {
        item?.retire()
        cancelPendingSeeks()
        val made = Item(location, listener)
        item = made
        exoPlayer.setMediaSource(mediaSource(location))
        exoPlayer.prepare()
        return made
    }

    private fun mediaSource(location: AudioLocation): MediaSource = when (location) {
        is AudioLocation.LocalFile -> ProgressiveMediaSource.Factory(DefaultDataSource.Factory(context), localExtractors)
            .createMediaSource(MediaItem.fromUri(Uri.fromFile(location.file)))
        is AudioLocation.Remote -> {
            val network: DataSource.Factory = OkHttpDataSource.Factory(httpClient)
                .setDefaultRequestProperties(location.headers)
            ProgressiveMediaSource.Factory(network, streamExtractors)
                .createMediaSource(MediaItem.fromUri(location.url))
        }
    }

    override fun cancelPendingSeeks() = settleSeek(false)

    private fun settleSeek(landed: Boolean) {
        val waiting = pendingSeek ?: return
        pendingSeek = null
        waiting.complete(landed)
    }

    override suspend fun seek(to: MediaTime): Boolean {
        val current = item ?: return false
        if (current.hasFailed || exoPlayer.playbackState == Player.STATE_IDLE) return false
        // An older seek still waiting is interrupted by this one, as the
        // engine iOS uses calls an interrupted seek back unfinished.
        settleSeek(false)
        val waiting = CompletableDeferred<Boolean>()
        pendingSeek = waiting
        exoPlayer.seekTo(milliseconds(to))
        // A seek from a settled state reports BUFFERING at once and READY when
        // it lands. One that left the state as it was has nothing to wait for
        // beyond the next turn of the main loop.
        val state = exoPlayer.playbackState
        if (state == Player.STATE_READY || state == Player.STATE_ENDED) {
            handler.post { if (pendingSeek === waiting) settleSeek(true) }
        }
        return waiting.await()
    }

    /**
     * The target on the engine's millisecond grid: rounded up, so a target
     * already rounded up onto 1/600 s stays at or after the sentence it names,
     * and held inside the item, so a target past anything a file could hold — a
     * book's `1e20s` clip — is a seek to its end rather than an overflow.
     */
    private fun milliseconds(time: MediaTime): Long {
        val millis = ceil(time.value.toDouble() * 1000.0 / time.timescale)
        val duration = exoPlayer.duration
        val ceiling = if (duration != C.TIME_UNSET && duration > 0) duration.toDouble() else MAXIMUM_SEEK_MILLIS
        return minOf(maxOf(millis, 0.0), ceiling).toLong()
    }

    // The engine

    override var rate: Float = 0f
        set(value) {
            field = value
            applyRate()
        }

    /** Plays only with the focus held: the route is not this app's to use otherwise. */
    private fun applyRate() {
        val wanted = rate
        if (wanted > 0) {
            if (exoPlayer.playbackParameters.speed != wanted) {
                exoPlayer.playbackParameters = PlaybackParameters(wanted, 1f)
            }
            exoPlayer.playWhenReady = focusHeld
        } else {
            exoPlayer.playWhenReady = false
        }
    }

    override var volume: Float
        get() = exoPlayer.volume
        set(value) {
            exoPlayer.volume = value
        }

    override var gain: Float
        get() = gainProcessor.gain
        set(value) {
            gainProcessor.gain = value
        }

    override val currentTime: Double
        get() = if (item == null || exoPlayer.currentMediaItem == null) Double.NaN else exoPlayer.currentPosition / 1000.0

    override val isPlaying: Boolean get() = exoPlayer.isPlaying

    private var observer: ((Double) -> Unit)? = null
    private var observationMillis = 1_000L
    private val tick = object : Runnable {
        override fun run() {
            observer?.invoke(currentTime)
            handler.postDelayed(this, observationMillis)
        }
    }

    override fun setTimeObserver(intervalSeconds: Double, observer: ((Double) -> Unit)?) {
        handler.removeCallbacks(tick)
        this.observer = observer
        observationMillis = maxOf(1L, (intervalSeconds * 1000).toLong())
        if (observer != null) handler.postDelayed(tick, observationMillis)
    }

    override fun release() {
        handler.removeCallbacks(tick)
        observer = null
        item?.retire()
        item = null
        cancelPendingSeeks()
        deactivateSession()
        exoPlayer.release()
    }

    /** One opened file or stream: what its loads wait on, and whether it failed. */
    private inner class Item(val location: AudioLocation, val listener: MediaBackend.ItemListener) : MediaBackend.Item {
        private val duration = CompletableDeferred<Double>()
        private var retired = false

        override var hasFailed = false
            private set
        override var failureReason: String? = null
            private set

        override suspend fun loadDuration(): Double = duration.await()

        /** Every item's audio runs through the gain stage once it opens: it sits in the sink's chain. */
        override suspend fun loadCarriesGain(): Boolean {
            duration.await()
            return true
        }

        /**
         * The item's length, once the engine knows it: from the timeline, or —
         * for a stream that states none — answered as unknown once it is ready
         * to play.
         */
        fun resolveDuration(ready: Boolean) {
            if (duration.isCompleted || this !== item) return
            val millis = exoPlayer.duration
            if (millis != C.TIME_UNSET) {
                duration.complete(millis / 1000.0)
            } else if (ready) {
                duration.complete(Double.NaN)
            }
        }

        fun fail(reason: String) {
            if (retired || hasFailed) return
            hasFailed = true
            failureReason = reason
            duration.completeExceptionally(IOException(reason))
            settleSeek(false)
            listener.onFailed(reason)
        }

        /**
         * Replaced. Its loads are answered so whatever awaits them finishes —
         * the player then finds a newer item and stands down — and nothing more
         * is reported about it.
         */
        fun retire() {
            retired = true
            if (!duration.isCompleted) duration.completeExceptionally(IOException("replaced"))
        }
    }

    companion object {
        /** A year: past anything a narration could last, and far from overflowing the engine's microseconds. */
        private const val MAXIMUM_SEEK_MILLIS = 365.0 * 24 * 3600 * 1000
    }
}
