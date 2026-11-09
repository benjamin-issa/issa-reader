package com.benjaminissa.issareader.playback

import com.benjaminissa.issareader.core.model.roundedHalfAwayFromZero
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.util.Locale

/**
 * Stops playback after a set time, or at the end of the current chapter.
 *
 * Fades out over the last few seconds rather than cutting off mid-word, which
 * is the difference between falling asleep to a book and being jolted by
 * silence.
 *
 * Main-thread-only, as the Swift type is `@MainActor`: [scope] runs the
 * countdown, and [sleep] is its clock — `delay` by default, which a test's
 * virtual time drives.
 *
 * @param onExpire called when the timer runs out; pauses playback.
 * @param fade called with a 0…1 volume multiplier during the fade-out.
 */
class SleepTimer(
    private val scope: CoroutineScope,
    private val onExpire: () -> Unit,
    private val fade: (Float) -> Unit = {},
    private val sleep: suspend (seconds: Double) -> Unit = { delay((it * 1000).toLong()) },
) : Observed() {
    sealed interface Mode {
        val title: String

        data object Off : Mode {
            override val title: String get() = "Off"
        }

        data class Duration(val seconds: Double) : Mode {
            override val title: String get() = "${(seconds / 60).toInt()} min"
        }

        /** Stop when the chapter being narrated finishes. */
        data object EndOfChapter : Mode {
            override val title: String get() = "End of chapter"
        }
    }

    var mode: Mode by observed(Mode.Off)
        private set

    /** Seconds left, for the countdown a listener glances at. */
    var remaining: Double? by observed(null)
        private set

    private var job: Job? = null

    /**
     * Whether audio is playing, so a paused book does not burn the timer.
     *
     * A function rather than a coordinator reference: this type is
     * deliberately ignorant of which kind of book it is timing, and the
     * listening layer already holds whichever coordinator is live.
     */
    var isPlaying: (() -> Boolean)? = null

    fun start(mode: Mode) {
        cancel()
        this.mode = mode
        if (mode !is Mode.Duration) {
            // End-of-chapter is driven by the coordinator reaching a boundary,
            // not by a clock.
            remaining = null
            return
        }
        val seconds = mode.seconds
        remaining = seconds
        job = scope.launch {
            val step = 1.0
            var left = seconds
            while (left > 0 && isActive) {
                sleep(step)
                if (!isActive) return@launch
                // Only while something is actually playing. This counted
                // wall-clock time regardless, so pausing to answer the door and
                // coming back twenty minutes later found the timer had run out,
                // faded the volume down, paused an already-paused player and
                // reset itself — which sets the mode to off. The moon icon then
                // read "not armed", and the listener pressed play believing it
                // still was.
                if (!(isPlaying?.invoke() ?: true)) continue
                left -= step
                remaining = maxOf(0.0, left)
                if (left <= FADE_DURATION) {
                    fade(maxOf(0.0, left / FADE_DURATION).toFloat())
                }
            }
            if (!isActive) return@launch
            fade(1f)
            onExpire()
            reset()
        }
    }

    /** Called when a chapter boundary is crossed, for the end-of-chapter mode. */
    fun chapterDidEnd() {
        if (mode != Mode.EndOfChapter) return
        onExpire()
        reset()
    }

    fun cancel() {
        job?.cancel()
        job = null
        fade(1f)
        reset()
    }

    private fun reset() {
        mode = Mode.Off
        remaining = null
    }

    /** "12:30" for a glance in the dark. */
    val remainingText: String?
        get() {
            val remaining = remaining ?: return null
            val total = remaining.roundedHalfAwayFromZero().toInt()
            return String.format(Locale.ROOT, "%d:%02d", total / 60, total % 60)
        }

    companion object {
        val presets: List<Mode> = listOf(
            Mode.Duration(5.0 * 60), Mode.Duration(15.0 * 60), Mode.Duration(30.0 * 60),
            Mode.Duration(45.0 * 60), Mode.Duration(60.0 * 60), Mode.EndOfChapter,
        )

        /** The last stretch is faded rather than cut. */
        const val FADE_DURATION: Double = 8.0
    }
}
