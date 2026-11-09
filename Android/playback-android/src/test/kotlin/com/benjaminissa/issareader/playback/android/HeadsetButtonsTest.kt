package com.benjaminissa.issareader.playback.android

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.KeyEvent
import com.benjaminissa.issareader.playback.CommandMap
import com.benjaminissa.issareader.playback.CommandRouter
import com.benjaminissa.issareader.playback.ControlSurface
import com.benjaminissa.issareader.playback.PlaybackAction
import com.benjaminissa.issareader.playback.PlaybackControl
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import java.time.Duration

/**
 * A headset's presses, counted here rather than by Media3.
 *
 * iOS received AirPods' gestures already decoded — one press play/pause, two
 * next track, three previous track — and resolved those against the reader's
 * bindings. A one-button Android headset sends the same key each time, and
 * Media3's own decoding turns a double press into the next chapter: the jump
 * the shipped bindings exist to never make unasked.
 */
@RunWith(RobolectricTestRunner::class)
class HeadsetButtonsTest {
    private val keys = mutableListOf<Pair<HeadsetButtons.Key, ControlSurface?>>()
    private val buttons = HeadsetButtons(Handler(Looper.getMainLooper()), WINDOW) { key, from -> keys += key to from }

    private fun down(code: Int, repeat: Int = 0): KeyEvent {
        val now = SystemClock.uptimeMillis()
        return KeyEvent(now, now, KeyEvent.ACTION_DOWN, code, repeat)
    }

    private fun up(code: Int): KeyEvent {
        val now = SystemClock.uptimeMillis()
        return KeyEvent(now, now, KeyEvent.ACTION_UP, code, 0)
    }

    private fun press(code: Int = KeyEvent.KEYCODE_HEADSETHOOK, from: ControlSurface? = null) {
        assertTrue(buttons.handle(down(code), from))
        assertTrue(buttons.handle(up(code), from))
    }

    private fun pass(millis: Long) = shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(millis))

    @Test
    fun onePressIsPlayPause() {
        press()
        assertTrue("nothing until the window has passed", keys.isEmpty())
        pass(WINDOW + 1)
        assertEquals(listOf(HeadsetButtons.Key.TOGGLE to null), keys)
    }

    @Test
    fun twoPressesAreNext() {
        press()
        pass(WINDOW / 2)
        press(KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE)
        pass(WINDOW + 1)
        assertEquals(listOf(HeadsetButtons.Key.NEXT to null), keys)
    }

    /** Three is as many as a gesture has: it acts at once. */
    @Test
    fun threePressesArePreviousAtOnce() {
        press()
        press()
        press()
        assertEquals(listOf(HeadsetButtons.Key.PREVIOUS to null), keys)
    }

    /** Presses further apart than the window are separate gestures. */
    @Test
    fun slowPressesAreSeparate() {
        press()
        pass(WINDOW + 1)
        press()
        pass(WINDOW + 1)
        assertEquals(listOf(HeadsetButtons.Key.TOGGLE to null, HeadsetButtons.Key.TOGGLE to null), keys)
    }

    /** A held button is the phone's assistant's, and its repeats count for nothing. */
    @Test
    fun aHeldButtonCountsOnce() {
        assertTrue(buttons.handle(down(KeyEvent.KEYCODE_HEADSETHOOK)))
        assertTrue(buttons.handle(down(KeyEvent.KEYCODE_HEADSETHOOK, repeat = 1)))
        assertTrue(buttons.handle(down(KeyEvent.KEYCODE_HEADSETHOOK, repeat = 2)))
        pass(WINDOW + 1)
        assertEquals(listOf(HeadsetButtons.Key.TOGGLE to null), keys)
    }

    /** Dedicated keys act at once, and settle a run of presses before them. */
    @Test
    fun dedicatedKeys() {
        press()
        press(KeyEvent.KEYCODE_MEDIA_NEXT, from = ControlSurface.CAR)
        press(KeyEvent.KEYCODE_MEDIA_PREVIOUS)
        press(KeyEvent.KEYCODE_MEDIA_FAST_FORWARD)
        press(KeyEvent.KEYCODE_MEDIA_REWIND)
        press(KeyEvent.KEYCODE_MEDIA_PLAY)
        press(KeyEvent.KEYCODE_MEDIA_PAUSE)
        press(KeyEvent.KEYCODE_MEDIA_STOP)
        assertEquals(
            listOf(
                HeadsetButtons.Key.TOGGLE to null,
                HeadsetButtons.Key.NEXT to ControlSurface.CAR,
                HeadsetButtons.Key.PREVIOUS to null,
                HeadsetButtons.Key.SKIP_FORWARD to null,
                HeadsetButtons.Key.SKIP_BACKWARD to null,
                HeadsetButtons.Key.PLAY to null,
                HeadsetButtons.Key.PAUSE to null,
                HeadsetButtons.Key.PAUSE to null,
            ),
            keys,
        )
    }

    /** A key that is not a media key is the session's to handle. */
    @Test
    fun otherKeysAreNotOurs() {
        assertFalse(buttons.handle(down(KeyEvent.KEYCODE_VOLUME_UP)))
        assertTrue(keys.isEmpty())
    }

    // Through the router: what a gesture does under the bindings.

    private fun routed(map: CommandMap, headphones: Boolean, key: HeadsetButtons.Key, from: ControlSurface? = null): List<PlaybackAction> {
        val router = CommandRouter(map)
        val actions = mutableListOf<PlaybackAction>()
        router.onAction = { actions += it }
        router.activate()
        router.headphonesRouted = headphones
        HeadsetButtons.route(router, key, from)
        return actions
    }

    /**
     * On the shipped bindings nothing binds the headphones' wheel, so a double
     * press is thirty seconds on — what iOS does with AirPods when the track
     * pair is not registered — and never a chapter.
     */
    @Test
    fun aDoublePressSkipsOnTheShippedBindings() {
        assertEquals(listOf(PlaybackAction.SKIP_FORWARD), routed(CommandMap(), headphones = true, key = HeadsetButtons.Key.NEXT))
        assertEquals(listOf(PlaybackAction.SKIP_BACKWARD), routed(CommandMap(), headphones = true, key = HeadsetButtons.Key.PREVIOUS))
        assertEquals(listOf(PlaybackAction.PLAY_PAUSE), routed(CommandMap(), headphones = true, key = HeadsetButtons.Key.TOGGLE))
    }

    /** A binding made on the headphones tab is what a double press does with headphones in. */
    @Test
    fun theHeadphonesTabDecidesWithHeadphonesIn() {
        val map = CommandMap().withBinding(PlaybackAction.NEXT_CHAPTER, PlaybackControl.WHEEL_NEXT, ControlSurface.HEADPHONES)
        assertEquals(listOf(PlaybackAction.NEXT_CHAPTER), routed(map, headphones = true, key = HeadsetButtons.Key.NEXT))
        // Out of the headphones the phone's wheel, unbound, offers no track
        // commands: the skip it is, as on iOS.
        assertEquals(listOf(PlaybackAction.SKIP_FORWARD), routed(map, headphones = false, key = HeadsetButtons.Key.NEXT))
    }

    /** A key from the car is the car's wheel. */
    @Test
    fun aKeyFromTheCarIsTheCars() {
        val map = CommandMap().withBinding(PlaybackAction.NEXT_PARAGRAPH, PlaybackControl.WHEEL_NEXT, ControlSurface.CAR)
        assertEquals(listOf(PlaybackAction.NEXT_PARAGRAPH), routed(map, headphones = true, key = HeadsetButtons.Key.NEXT, from = ControlSurface.CAR))
    }

    private companion object {
        const val WINDOW = 300L
    }
}
