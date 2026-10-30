package com.benjaminissa.issareader.playback

import kotlinx.coroutines.yield
import java.io.File
import java.io.IOException

/**
 * A [MediaBackend] whose every answer the test decides.
 *
 * The stand-in for the real engine in the suites that drove `AVQueuePlayer`
 * with silent audio. It keeps what those suites leaned on — a playhead that
 * goes where a seek sends it, an item that will not open when its file is not
 * there, loads and seeks that suspend before they answer so a racing command
 * lands in their window — and nothing else: no clock ticks by itself and no
 * item ends by itself, so a test says exactly which samples and which endings
 * arrive.
 *
 * Every file that exists opens as [Silence.DURATION] seconds long, which is the
 * shape `SilentAudio` gave the Swift suites: long enough that every offset they
 * seek to is inside the file.
 */
internal class ScriptedBackend(
    /** How long an item is, or null when it will not open. */
    var durationOf: (AudioLocation) -> Double? = { location ->
        when (location) {
            is AudioLocation.LocalFile -> if (location.file.isFile) Silence.DURATION else null
            is AudioLocation.Remote -> Silence.DURATION
        }
    },
    /** Whether an item's audio runs through the gain stage, or null when its tracks cannot be read. */
    var carriesGainOf: (AudioLocation) -> Boolean? = { location -> durationOf(location)?.let { true } },
) : MediaBackend {
    override var sessionListener: MediaBackend.SessionListener? = null

    var sessionsConfigured = 0
        private set
    var sessionsActivated = 0
        private set
    var sessionsDeactivated = 0
        private set
    var released = false
        private set

    /** Every location opened, in order. */
    val opened = ArrayList<AudioLocation>()

    private var item: Item? = null

    /** Where the engine's playhead is. */
    var playhead: Double = Double.NaN
        private set

    var observationInterval: Double? = null
        private set
    private var timeObserver: ((Double) -> Unit)? = null

    override fun configureSession() {
        sessionsConfigured += 1
    }

    override fun activateSession() {
        sessionsActivated += 1
    }

    override fun deactivateSession() {
        sessionsDeactivated += 1
    }

    override val currentItem: MediaBackend.Item? get() = item

    override fun replaceItem(location: AudioLocation, listener: MediaBackend.ItemListener): MediaBackend.Item {
        opened.add(location)
        val made = Item(location, listener)
        item = made
        playhead = 0.0
        return made
    }

    override fun clearItem() {
        item = null
        playhead = Double.NaN
    }

    override fun cancelPendingSeeks() = Unit

    override suspend fun seek(to: MediaTime): Boolean {
        val target = item ?: return false
        playhead = to.seconds
        // An engine's seek is answered later, never in the same breath.
        yield()
        return item === target && !target.hasFailed
    }

    override var rate: Float = 0f
    override var volume: Float = 1f
    override var gain: Float = 1f

    override val currentTime: Double get() = if (item == null) Double.NaN else playhead

    override val isPlaying: Boolean get() = rate > 0 && item?.hasFailed == false

    override fun setTimeObserver(intervalSeconds: Double, observer: ((Double) -> Unit)?) {
        observationInterval = intervalSeconds
        timeObserver = observer
    }

    override fun release() {
        released = true
        timeObserver = null
        item = null
    }

    /** One sample from the periodic observer, as the engine would deliver it. */
    fun tick(seconds: Double = currentTime) {
        timeObserver?.invoke(seconds)
    }

    /** The current item playing to its end. */
    fun finishItem() {
        item?.listener?.onPlayedToEnd()
    }

    /** The current item stopping for good. */
    fun failItem(reason: String = "scripted failure") {
        val current = item ?: return
        current.hasFailed = true
        current.failureReason = reason
        current.listener.onFailed(reason)
    }

    fun interruptionBegan() = sessionListener?.onInterruptionBegan()

    fun interruptionEnded(shouldResume: Boolean) = sessionListener?.onInterruptionEnded(shouldResume)

    fun routeLost() = sessionListener?.onRouteLost()

    inner class Item(val location: AudioLocation, val listener: MediaBackend.ItemListener) : MediaBackend.Item {
        override var hasFailed = false
        override var failureReason: String? = null

        override suspend fun loadDuration(): Double {
            yield()
            val duration = durationOf(location)
            if (duration == null) {
                hasFailed = true
                failureReason = "cannot open $location"
                throw IOException("cannot open $location")
            }
            return duration
        }

        override suspend fun loadCarriesGain(): Boolean {
            yield()
            return carriesGainOf(location) ?: throw IOException("no tracks in $location")
        }
    }
}

/**
 * A file the scripted engine opens, standing for `SilentAudio`: thirty minutes
 * of nothing, so every offset a suite seeks to is inside it.
 */
internal object Silence {
    const val DURATION: Double = 1_800.0

    val file: File by lazy {
        File.createTempFile("issa-playback-tests-silence", ".wav").apply {
            deleteOnExit()
            writeBytes(ByteArray(64))
        }
    }
}
