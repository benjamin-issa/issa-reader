package com.benjaminissa.issareader.app.model

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * Whether the display may be held awake while a book is open.
 *
 * The phone and tablet adopt Storyteller's behaviour: the display stays awake
 * for as long as a book is on screen, and the sleep timer running out is what
 * lets it go — the answer to a book left open on the nightstand.
 *
 * The failure mode of getting this wrong is worse than the bug it fixes: a
 * display held awake that nothing releases never lets the phone sleep again,
 * and a flat battery is a larger complaint than a dimmed screen. So every input
 * is also a release path — the reader being dismissed, the app going to the
 * background and the sleep timer expiring each take one away — and `AppModel`
 * recomputes on every write to each of them.
 *
 * Pure, so the truth table is the part that can be asserted.
 */
object ScreenAwake {
    /** Which rule a platform applies. */
    enum class Policy {
        /** A book on screen holds the display, narrated or not, playing or paused. The phone and tablet. */
        WHILE_READER_OPEN,

        /** Only narration playing for its own page holds it: the television's rule. */
        WHILE_NARRATING,
    }

    /**
     * The rule this build applies. Android's is the phone's: there is no
     * television target.
     */
    val platformPolicy: Policy = Policy.WHILE_READER_OPEN

    /**
     * Whether the display should be kept awake right now.
     *
     * @param isPlaying whether audio is genuinely running.
     * @param isReaderVisible whether a reader screen is on screen.
     * @param followsText whether what is audible is the narration belonging to
     *   that reader. Only the television's rule asks.
     * @param isForeground whether the app is frontmost: backgrounding does not
     *   dismiss the reader, so without this a phone pocketed with a book open
     *   would hold its own display awake for as long as the book stayed open.
     * @param sleepTimerRanOut whether the sleep timer has expired since the
     *   reader last opened a book, pressed play or picked the phone up.
     */
    fun shouldKeepAwake(
        policy: Policy,
        isPlaying: Boolean,
        isReaderVisible: Boolean,
        followsText: Boolean,
        isForeground: Boolean,
        sleepTimerRanOut: Boolean,
    ): Boolean {
        if (!isReaderVisible || !isForeground || sleepTimerRanOut) return false
        return when (policy) {
            Policy.WHILE_READER_OPEN -> true
            Policy.WHILE_NARRATING -> isPlaying && followsText
        }
    }
}

/**
 * The single holder of the "keep the display awake" decision.
 *
 * One instance, owned by `AppModel`, because the state it guards is one flag
 * for the window: two screens each setting it for themselves means whichever
 * leaves second decides. The activity applies [isHeld] with
 * `WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON` — observable snapshot state,
 * so it follows every change.
 *
 * Idempotent on purpose: [apply] is called from a rate observer that fires on
 * every play, pause, rate change and chapter boundary.
 */
class ScreenAwakeAssertion {
    /** Whether the display is being held awake. */
    var isHeld: Boolean by mutableStateOf(false)
        private set

    /** Applies a decision, doing nothing when it has not changed. */
    fun apply(shouldKeepAwake: Boolean) {
        if (shouldKeepAwake == isHeld) return
        isHeld = shouldKeepAwake
    }
}
