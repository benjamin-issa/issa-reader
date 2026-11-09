package com.benjaminissa.issareader.playback

import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

// Ported from `SleepTimerTests.swift`. The last two tests are Android's own:
// the Swift suite never ran the clock, and here the clock is the test's.

class SleepTimerTest {
    /** Presets cover the useful range and read sensibly. */
    @Test
    fun presets() {
        val titles = SleepTimer.presets.map { it.title }
        assertTrue(titles.contains("15 min"))
        assertTrue(titles.contains("End of chapter"))
        assertEquals("Off", SleepTimer.Mode.Off.title)
    }

    /** Starts off, and cancelling restores full volume. */
    @Test
    fun cancelRestoresVolume() = runTest {
        val faded = ArrayList<Float>()
        val timer = SleepTimer(backgroundScope, onExpire = {}, fade = { faded.add(it) })
        assertEquals(SleepTimer.Mode.Off, timer.mode)
        assertNull(timer.remaining)

        timer.start(SleepTimer.Mode.Duration(600.0))
        assertEquals(SleepTimer.Mode.Duration(600.0), timer.mode)
        assertEquals(600.0, checkNotNull(timer.remaining), 0.0)

        timer.cancel()
        assertEquals(SleepTimer.Mode.Off, timer.mode)
        // Cancelling must undo any partial fade, or the next play is silent.
        assertEquals(1f, faded.last())
    }

    /** End-of-chapter fires only on a chapter boundary. */
    @Test
    fun endOfChapter() = runTest {
        var expired = 0
        val timer = SleepTimer(backgroundScope, onExpire = { expired += 1 })

        // No timer set: a boundary must not stop playback.
        timer.chapterDidEnd()
        assertEquals(0, expired)

        timer.start(SleepTimer.Mode.EndOfChapter)
        // A clock-based countdown does not apply to this mode.
        assertNull(timer.remaining)
        timer.chapterDidEnd()
        assertEquals(1, expired)
        assertEquals(SleepTimer.Mode.Off, timer.mode)

        // And it does not fire twice.
        timer.chapterDidEnd()
        assertEquals(1, expired)
    }

    /** A duration timer ignores chapter boundaries. */
    @Test
    fun durationIgnoresChapters() = runTest {
        var expired = 0
        val timer = SleepTimer(backgroundScope, onExpire = { expired += 1 })
        timer.start(SleepTimer.Mode.Duration(300.0))
        timer.chapterDidEnd()
        assertEquals(0, expired)
        timer.cancel()
    }

    /** Formats the countdown for a glance in the dark. */
    @Test
    fun countdownText() = runTest {
        val timer = SleepTimer(backgroundScope, onExpire = {})
        assertNull(timer.remainingText)
        timer.start(SleepTimer.Mode.Duration(750.0))
        assertEquals("12:30", timer.remainingText)
        timer.cancel()
    }

    /** The last eight seconds fade rather than cut, and then the timer expires and disarms. */
    @Test
    fun theCountdownFadesAndExpires() = runTest {
        val faded = ArrayList<Float>()
        var expired = 0
        val timer = SleepTimer(backgroundScope, onExpire = { expired += 1 }, fade = { faded.add(it) })
        timer.start(SleepTimer.Mode.Duration(10.0))
        // Starting cancels whatever ran before, which hands back full volume.
        assertEquals(listOf(1f), faded)
        faded.clear()

        advanceTimeBy(2_000)
        runCurrent()
        assertEquals(8.0, checkNotNull(timer.remaining), 0.0)
        assertEquals("the fade starts eight seconds out", listOf(1f), faded)

        advanceTimeBy(8_000)
        runCurrent()
        assertEquals(1, expired)
        assertEquals(SleepTimer.Mode.Off, timer.mode)
        assertNull(timer.remaining)
        assertEquals(0f, faded[faded.size - 2])
        assertEquals("and full volume is handed back for the next play", 1f, faded.last())
    }

    /**
     * Only while something is playing. Counting wall-clock time regardless had
     * a paused book's timer run out, fade, and disarm itself while the listener
     * answered the door.
     */
    @Test
    fun aPausedBookDoesNotBurnTheTimer() = runTest {
        var expired = 0
        var playing = false
        val timer = SleepTimer(backgroundScope, onExpire = { expired += 1 })
        timer.isPlaying = { playing }
        timer.start(SleepTimer.Mode.Duration(5.0))

        advanceTimeBy(60_000)
        runCurrent()
        assertEquals(0, expired)
        assertEquals(5.0, checkNotNull(timer.remaining), 0.0)

        playing = true
        advanceTimeBy(5_000)
        runCurrent()
        assertEquals(1, expired)
    }
}
