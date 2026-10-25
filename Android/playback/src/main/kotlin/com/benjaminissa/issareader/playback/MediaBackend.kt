package com.benjaminissa.issareader.playback

import java.io.File

/** Somewhere audio can be opened from. */
sealed interface AudioLocation {
    /** A file on disk: extracted narration, or a downloaded audiobook. */
    data class LocalFile(val file: File) : AudioLocation

    /**
     * A stream, with the headers its request needs. The server's audio routes
     * take the session token both as a bearer and as the `st_token` cookie the
     * web player sends; see [AudiobookCoordinator.Source.streaming].
     */
    data class Remote(val url: String, val headers: Map<String, String> = emptyMap()) : AudioLocation
}

/**
 * A time on the player's grid: `value / timescale` seconds.
 *
 * `CMTime`'s place. Targets are kept on the 1/600 s timescale both clients
 * seek on, and rounded *up* onto it — see [AudioPlayer.mediaTime].
 */
data class MediaTime(val value: Long, val timescale: Int = TIMESCALE) {
    val seconds: Double get() = value.toDouble() / timescale

    companion object {
        const val TIMESCALE: Int = 600
        val ZERO: MediaTime = MediaTime(0)
    }
}

/**
 * The engine under [AudioPlayer]: one item at a time, as iOS's `AVQueuePlayer`
 * is used.
 *
 * Thin on purpose. Everything that decides anything — which call owns the item
 * and which the playhead, what a failure does, when the engine may start — is
 * [AudioPlayer]'s, written against this, so the races it closes can be stated
 * in a JVM test with a scripted engine. `playback-android`'s `ExoMediaBackend`
 * is the real one, over Media3's ExoPlayer.
 *
 * Main-thread-only, like the player that drives it: every call is made on the
 * main thread, and every listener is called back on it.
 */
interface MediaBackend {
    /** What happens to the audio route without the app asking. */
    interface SessionListener {
        /** Something else took the audio — a call, another app. The engine has stopped. */
        fun onInterruptionBegan()

        /** The interruption is over; [shouldResume] when the system expects playback to carry on. */
        fun onInterruptionEnded(shouldResume: Boolean)

        /** Headphones came out or a Bluetooth device went away: the audio is becoming noisy. */
        fun onRouteLost()
    }

    /** What happens to the item the engine holds. Only ever reported for the current item. */
    interface ItemListener {
        /** The item played to its end. The engine has stopped. */
        fun onPlayedToEnd()

        /** The item stopped for good: it never became playable, or it stopped part-way. */
        fun onFailed(reason: String)
    }

    /** One opened file or stream. */
    interface Item {
        /**
         * The item's length in seconds — NaN or infinite for a stream with no
         * length — once it is known.
         *
         * @throws Exception when the item will not open.
         */
        suspend fun loadDuration(): Double

        /**
         * Whether this item's audio runs through the gain stage, so a gain above
         * one can be heard.
         *
         * @throws Exception when the item's tracks cannot be read.
         */
        suspend fun loadCarriesGain(): Boolean

        /** Whether the item has stopped for good. */
        val hasFailed: Boolean

        /** Why, when it has. */
        val failureReason: String?
    }

    var sessionListener: SessionListener?

    /** Declares the session as spoken audio without taking the route. */
    fun configureSession()

    /** Takes the audio route: on Android, requests audio focus. */
    fun activateSession()

    /** Gives the route back so whatever this interrupted can carry on: abandons audio focus. */
    fun deactivateSession()

    /** The item the engine holds, if any. */
    val currentItem: Item?

    /**
     * Drops the current item and opens [location] in its place, stopped at its
     * start. Events about the replaced item are not reported again.
     */
    fun replaceItem(location: AudioLocation, listener: ItemListener): Item

    /** Releases any seek still waiting on the current item, answering it `false`. */
    fun cancelPendingSeeks()

    /**
     * Moves the playhead exactly — no tolerance either side — and answers once
     * it has landed, `false` when something newer or a failure interrupted it.
     */
    suspend fun seek(to: MediaTime): Boolean

    /**
     * The engine's rate. Zero is stopped; anything else plays at that speed
     * with the pitch preserved, as spoken audio at 1.5–3× is unlistenable
     * without it.
     */
    var rate: Float

    /** The engine's own volume, 0…1: the sleep timer's fade, and the quieter half of a trim without a gain stage. */
    var volume: Float

    /** The gain stage's multiplier, applied after time-stretching. */
    var gain: Float

    /** Seconds into the current item; NaN when there is none. */
    val currentTime: Double

    /** Whether audio is actually coming out — not merely asked for, as through a buffering stall. */
    val isPlaying: Boolean

    /** Calls [observer] with [currentTime] every [intervalSeconds] on the main thread, replacing any earlier one. */
    fun setTimeObserver(intervalSeconds: Double, observer: ((Double) -> Unit)?)

    /** Stops observing and frees the engine. */
    fun release()
}
