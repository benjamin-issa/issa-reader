package com.benjaminissa.issareader.playback.android

import android.os.Handler
import android.os.Looper
import android.view.KeyEvent
import android.view.ViewConfiguration
import com.benjaminissa.issareader.playback.CommandRouter
import com.benjaminissa.issareader.playback.ControlSurface

/**
 * A headset's buttons, decoded here rather than by Media3.
 *
 * A wired or Bluetooth headset with one button sends one key, again and again:
 * the press count is the gesture. iOS never saw that — AirPods arrive
 * already decoded, a single press as play/pause, a double as next track and a
 * triple as previous track — and Swift's `RemoteCommandCenter` resolved those
 * against the reader's bindings. Media3 decodes the double press itself and
 * turns it into "next item", which here would be the next *chapter*: the jump
 * the shipped bindings exist to never make unasked. So the presses are counted
 * here, with the platform's own double-tap window, and land where they land on
 * iOS: one is play/pause, two is the wheel's `»`, three its `«`.
 *
 * Next and previous become the skips where the bindings offer no track
 * commands — what iOS does with AirPods when the track pair is not registered —
 * so on the shipped bindings a double press is thirty seconds on, never a
 * chapter. Dedicated keys (play, pause, next, previous, fast-forward, rewind)
 * act at once.
 *
 * Main-thread only.
 *
 * @param windowMillis how long after a press another still counts as part of
 *   the same gesture: the platform's double-tap timeout.
 * @param onKey what a decoded gesture asks for, and the surface its first
 *   press came from.
 */
class HeadsetButtons(
    private val handler: Handler = Handler(Looper.getMainLooper()),
    private val windowMillis: Long = ViewConfiguration.getDoubleTapTimeout().toLong(),
    private val onKey: (Key, ControlSurface?) -> Unit,
) {
    /** What a key, or a run of presses, asks for. */
    enum class Key {
        /** One press of the headset's button. */
        TOGGLE,
        PLAY,
        PAUSE,

        /** Two presses, or the next key: the wheel's `»`. */
        NEXT,

        /** Three presses, or the previous key: the wheel's `«`. */
        PREVIOUS,

        /** Fast-forward: the tap control, as the system's skip button is. */
        SKIP_FORWARD,
        SKIP_BACKWARD,
    }

    private var presses = 0
    private var firstPressFrom: ControlSurface? = null
    private val settle = Runnable { finishPresses() }

    /**
     * Takes one key event.
     *
     * @param from the surface the key came from, when the session knows it.
     * @return whether the key is a media key this decoder answers, including
     *   the key-up and repeats it swallows; false lets the session handle it.
     */
    fun handle(event: KeyEvent, from: ControlSurface? = null): Boolean {
        val code = event.keyCode
        if (code !in KEYS) return false
        // The key-up of a press already counted, and a held button's repeats:
        // a long press on a headset belongs to the phone's assistant.
        if (event.action != KeyEvent.ACTION_DOWN || event.repeatCount > 0) return true
        when (code) {
            KeyEvent.KEYCODE_HEADSETHOOK, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE -> press(from)
            else -> {
                // A different key ends a run of presses first, in order.
                finishPresses()
                onKey(keyFor(code), from)
            }
        }
        return true
    }

    /** Settles a run of presses now, as the window running out would. */
    fun flush() = finishPresses()

    private fun press(from: ControlSurface?) {
        handler.removeCallbacks(settle)
        if (presses == 0) firstPressFrom = from
        presses += 1
        // Three is as many as a gesture has: nothing waits for a fourth.
        if (presses >= MAX_PRESSES) finishPresses() else handler.postDelayed(settle, windowMillis)
    }

    private fun finishPresses() {
        handler.removeCallbacks(settle)
        val count = presses
        if (count == 0) return
        presses = 0
        val from = firstPressFrom
        firstPressFrom = null
        onKey(
            when (count) {
                1 -> Key.TOGGLE
                2 -> Key.NEXT
                else -> Key.PREVIOUS
            },
            from,
        )
    }

    companion object {
        private const val MAX_PRESSES = 3

        private val KEYS = setOf(
            KeyEvent.KEYCODE_HEADSETHOOK,
            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
            KeyEvent.KEYCODE_MEDIA_PLAY,
            KeyEvent.KEYCODE_MEDIA_PAUSE,
            KeyEvent.KEYCODE_MEDIA_STOP,
            KeyEvent.KEYCODE_MEDIA_NEXT,
            KeyEvent.KEYCODE_MEDIA_PREVIOUS,
            KeyEvent.KEYCODE_MEDIA_FAST_FORWARD,
            KeyEvent.KEYCODE_MEDIA_REWIND,
            KeyEvent.KEYCODE_MEDIA_SKIP_FORWARD,
            KeyEvent.KEYCODE_MEDIA_SKIP_BACKWARD,
        )

        private fun keyFor(code: Int): Key = when (code) {
            KeyEvent.KEYCODE_MEDIA_PLAY -> Key.PLAY
            // Stop is a pause: the place is kept, and nothing else would stop.
            KeyEvent.KEYCODE_MEDIA_PAUSE, KeyEvent.KEYCODE_MEDIA_STOP -> Key.PAUSE
            KeyEvent.KEYCODE_MEDIA_NEXT -> Key.NEXT
            KeyEvent.KEYCODE_MEDIA_PREVIOUS -> Key.PREVIOUS
            KeyEvent.KEYCODE_MEDIA_FAST_FORWARD, KeyEvent.KEYCODE_MEDIA_SKIP_FORWARD -> Key.SKIP_FORWARD
            else -> Key.SKIP_BACKWARD
        }

        /**
         * What [key] does through [router]: the same entry points the lock
         * screen's buttons use, so the bindings decide.
         */
        fun route(router: CommandRouter, key: Key, from: ControlSurface?) {
            when (key) {
                Key.TOGGLE -> router.togglePlayPause()
                Key.PLAY -> router.play()
                Key.PAUSE -> router.pause()
                Key.NEXT -> if (router.offersTrackCommands(from)) router.nextTrack(from) else router.skipForward(from)
                Key.PREVIOUS -> if (router.offersTrackCommands(from)) router.previousTrack(from) else router.skipBackward(from)
                Key.SKIP_FORWARD -> router.skipForward(from)
                Key.SKIP_BACKWARD -> router.skipBackward(from)
            }
        }
    }
}
