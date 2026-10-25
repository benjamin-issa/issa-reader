package com.benjaminissa.issareader.playback

import com.benjaminissa.issareader.core.model.AudiobookManifest
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

// Ported from `BookClockTests.swift`, over the scripted engine.

/**
 * The book clock is what the lock screen publishes and what every skip is
 * measured from. A single non-finite sample used to latch into it, make the
 * system count up from zero, send both rewind and fast-forward to the start of
 * the book, and then persist that zero to the server — losing hours of
 * position.
 */
class BookClockTest {
    /** Decoded, the way a real manifest arrives. */
    private fun manifest(trackCount: Int = 60, each: Double = 1_600.0): AudiobookManifest =
        decodedManifest((0 until trackCount).map { "t$it.mp4" to each }, type = "audio/mp4", titled = true)

    private fun coordinator(manifest: AudiobookManifest, scope: CoroutineScope): AudiobookCoordinator =
        AudiobookCoordinator(manifest, AudiobookCoordinator.Source.Local(Silence.file), player = scriptedPlayer(), scope = scope)

    /**
     * Swift's `min`/`max` return the other operand when a comparison against
     * NaN is false, so the old `min(max(NaN, 0), 1)` produced NaN, not 0.
     */
    @Test
    fun nanDoesNotBecomeProgress() = runTest {
        val subject = coordinator(manifest(), backgroundScope)
        // The Swift suite first proved the hazard on Swift's own `min`/`max`;
        // Kotlin's `maxOf` passes the NaN through as well, so the guard is the
        // same either way.
        assertTrue(minOf(maxOf(Double.NaN, 0.0), 1.0).isNaN())
        subject.player.onTimeUpdate?.invoke(Double.NaN)
        assertTrue("a NaN sample must not reach the book clock", subject.bookTime.isFinite())
        assertTrue(subject.progress.isFinite())
        assertEquals(0.0, subject.progress, 0.0)
    }

    /** An infinite sample is refused too. */
    @Test
    fun infinityIsRefused() = runTest {
        val subject = coordinator(manifest(), backgroundScope)
        subject.player.onTimeUpdate?.invoke(Double.POSITIVE_INFINITY)
        assertTrue(subject.bookTime.isFinite())
    }

    /**
     * The fingerprint of the reported bug: a fast-forward that jumps backwards
     * to 0:00, because `max(0, min(NaN + delta, total))` collapses to zero.
     */
    @Test
    fun skipFromBrokenClockDoesNothing() = runTest {
        val subject = coordinator(manifest(), backgroundScope)
        subject.seekToBookTime(4 * 3_600.0)
        val before = subject.bookTime
        assertTrue(before > 0)

        subject.player.onTimeUpdate?.invoke(Double.NaN)
        subject.skip(30.0)
        assertTrue(subject.bookTime.isFinite())
        assertTrue("must not have been thrown back to the start", subject.bookTime > 0)

        // And the arithmetic that used to do it, stated plainly — in Swift's
        // semantics, where a comparison with NaN hands back the other operand.
        val swiftMin = { x: Double, y: Double -> if (y < x) y else x }
        val swiftMax = { x: Double, y: Double -> if (y >= x) y else x }
        assertEquals("this is what the old clamp did", 0.0, swiftMax(0.0, swiftMin(Double.NaN + 30, 96_000.0)), 0.0)
    }

    /**
     * Elapsed is published as book-wide seconds; the lock-screen scrubber hands
     * the same number back. The round trip must be the identity.
     */
    @Test
    fun positionRoundTrips() = runTest {
        val subject = coordinator(manifest(), backgroundScope)
        val total = subject.totalDuration
        assertEquals(60 * 1_600.0, total, 0.0)

        for (target in listOf(0.0, 1_600.0, 4 * 3_600.0, total - 1)) {
            subject.seekToBookTime(target)
            val published = total * subject.bookProgress
            assertTrue("published $published for $target", abs(published - target) < 1)

            // What the scrubber delivers, converted the way the listening layer
            // converts it.
            subject.seekToBookProgress(published / total)
            assertTrue(abs(subject.bookTime - target) < 1)
        }
    }

    /** Book-wide, not per-file: a skip near a track boundary has to cross it. */
    @Test
    fun skipCrossesTracks() = runTest {
        val subject = coordinator(manifest(trackCount = 10, each = 100.0), backgroundScope)
        subject.seekToBookTime(305.0) // 5s into track 4
        assertEquals(3, subject.trackIndex)

        subject.skip(-30.0) // back across the boundary
        assertTrue("landed at ${subject.bookTime}", abs(subject.bookTime - 275) < 1)
        assertEquals("should be in the previous track", 2, subject.trackIndex)
    }

    /**
     * Through the clock, which is the only path that can put `bookTime` outside
     * the book: a seek goes through `locate`, which clamps its input. A tick
     * past the last track's stated duration — a duration is an estimate, and
     * the file runs on — and a negative one do reach it.
     */
    @Test
    fun progressStaysInRange() = runTest {
        val subject = coordinator(manifest(), backgroundScope)
        val tick = detachClock(subject.player)

        subject.seekToBookTime(10_000_000.0)
        tick(1_612.5)
        assertTrue("the clock has to be past the end to test the clamp", subject.bookTime > subject.totalDuration)
        assertEquals(1.0, subject.progress, 0.0)

        subject.seekToBookTime(0.0)
        tick(-5.0)
        assertTrue("the clock has to be before the start to test the clamp", subject.bookTime < 0)
        assertEquals(0.0, subject.progress, 0.0)
    }

    /**
     * The end of the last track is not somewhere to land.
     *
     * `locate` answers a time at or past the end of the book with the last
     * track and its full duration, so a thirty-second skip in the last half
     * minute — or a scrub to the far end of the bar — seeked exactly onto the end
     * of the file and restored the rate. The read-along has always landed
     * `END_OF_ENTRY_MARGIN` short of an end for this reason; the audiobook had no
     * counterpart.
     */
    @Test
    fun theEndOfTheBookIsNotALandingPlace() = runTest {
        val subject = coordinator(manifest(trackCount = 3, each = 1_000.0), backgroundScope)
        subject.player.onTimeUpdate = null
        val total = subject.totalDuration

        subject.seekToBookTime(total - 10)
        subject.skip(30.0)
        assertEquals(2, subject.trackIndex)
        assertTrue("the skip landed on the end of the file itself", subject.bookTime < total)
        assertTrue("and only a hair short of it", subject.bookTime >= total - 0.01)

        subject.seekToProgress(1.0)
        assertTrue("nor may a scrub to the end of the bar", subject.bookTime < total)
        assertTrue(subject.bookTime >= total - 0.01)
    }

    /**
     * The restart-the-current-track branch of `previousChapter()` used to seek
     * the player directly, without the `bookTime` update every other seek path
     * performs. A skip fired right after a restart computed its target from
     * wherever playback had been a moment before, not from the restart,
     * overshooting by however far into the track the listener had gotten.
     */
    @Test
    fun restartingCurrentChapterUpdatesBookTime() = runTest {
        val subject = coordinator(manifest(trackCount = 3, each = 1_000.0), backgroundScope)
        subject.seekToBookTime(1_010.0) // 10s into track 1
        assertEquals(1, subject.trackIndex)

        // Disconnected deliberately: this test is about `previousChapter()`'s own
        // code, not about a clock sample that happens to repair it.
        subject.player.onTimeUpdate = null

        // Real playback progress past the 3 s threshold that decides "restart
        // this track" versus "go back a track".
        subject.player.seek(10.0)
        assertTrue(subject.player.currentTime > 3)

        subject.previousChapter()
        assertEquals("a restart stays on the same track", 1, subject.trackIndex)
        assertEquals("bookTime must reflect the restart, not the old position", 1_000.0, subject.bookTime, 0.0)

        // The regression, made concrete: a skip fired immediately after must be
        // measured from the true, just-restarted position.
        subject.skip(30.0)
        assertTrue("skip after a restart landed at ${subject.bookTime}, not 1030", abs(subject.bookTime - 1_030) < 0.001)
    }

    /**
     * The other branch: three or fewer seconds in moves back a whole track, and
     * the load already keeps `bookTime` correct there — this confirms the
     * boundary between the two branches.
     */
    @Test
    fun previousChapterNearStartMovesBackATrack() = runTest {
        val subject = coordinator(manifest(trackCount = 3, each = 1_000.0), backgroundScope)
        subject.seekToBookTime(1_002.0) // 2s into track 1
        subject.player.seek(2.0)
        assertTrue(subject.player.currentTime <= 3)

        subject.previousChapter()
        assertEquals(0, subject.trackIndex)
        assertEquals(0.0, subject.bookTime, 0.0)
    }

    /**
     * `min(trackIndex + 1, tracks.size - 1)` on the final track resolved to the
     * *current* track: a restart at zero, marked as steered — which the position
     * writer then sent to the server as chosen, the one origin the position
     * guard never refuses.
     */
    @Test
    fun nextChapterOnLastTrackDoesNothing() = runTest {
        val subject = coordinator(manifest(trackCount = 3, each = 1_000.0), backgroundScope)
        subject.seekToBookTime(2_500.0) // 500s into the final track
        assertEquals(2, subject.trackIndex)
        subject.consumeSteering()

        subject.nextChapter()

        assertEquals(2, subject.trackIndex)
        assertTrue("must not restart the track at zero", abs(subject.bookTime - 2_500) < 1)
        assertFalse("a refused move must not be written back as a chosen position", subject.consumeSteering())
    }

    /**
     * `advance()` runs `play()` after the load — and the load is what fires
     * `onChapterChange`, which is where an "end of chapter" sleep timer pauses.
     * The unconditional play() undid that pause in the same turn, after the
     * timer had already reset itself, so the rest of the book played on into
     * the night.
     */
    @Test
    fun endOfChapterPauseSurvivesAdvance() = runTest {
        val subject = coordinator(manifest(trackCount = 3, each = 1_000.0), backgroundScope)
        subject.seekToBookTime(999.0)
        subject.player.play()
        // The listening layer's wiring, in miniature: the timer's expiry pauses
        // from inside the chapter-change callback, mid-`advance()`.
        var boundaryCrossed = false
        subject.onChapterChange = {
            subject.player.pause()
            boundaryCrossed = true
        }

        subject.player.onFinishedFile?.invoke()

        assertTrue("the next track never loaded", settle { boundaryCrossed })
        assertEquals(1, subject.trackIndex)
        assertFalse("advance() must not undo the pause the boundary just asked for", subject.player.isPlaying)
    }

    /** The discrete play and pause commands hold their meaning when repeated. */
    @Test
    fun discretePlayPause() = runTest {
        val subject = coordinator(manifest(), backgroundScope)
        val map = CommandMap()

        subject.perform(PlaybackAction.PLAY, map)
        assertTrue(subject.player.isPlaying)
        // A stalled book draws ▶ (the published rate is 0) while `isPlaying` is
        // true; the tap that arrives is PLAY and must not flip to pause.
        subject.perform(PlaybackAction.PLAY, map)
        assertTrue("play is not a toggle", subject.player.isPlaying)

        subject.perform(PlaybackAction.PAUSE, map)
        assertFalse(subject.player.isPlaying)
        subject.perform(PlaybackAction.PAUSE, map)
        assertFalse("pause is not a toggle", subject.player.isPlaying)
    }
}

// Ported from `BookClockTests.swift` (`RateObserverTests`).

/** What the rate observers are told, which is what the widget and the lock screen believe. */
class RateObserverTest {
    /** Changing speed while paused does not announce playback. */
    @Test
    fun pausedRateChangeReportsZero() {
        val subject = scriptedPlayer()
        val reported = ArrayList<Float>()
        val owner = Any()
        subject.setRateObserver(owner) { reported.add(it) }

        // Paused: picking 1.5× from the menu must not tell anyone the book
        // started. The widget's `isPlaying` is published from exactly this
        // number, and a paused book never republishes to correct it.
        subject.rate = 1.5f
        assertEquals("the effective rate of a paused player is zero", listOf(0f), reported)

        subject.play()
        assertEquals(1.5f, reported.last())
        subject.rate = 2.0f
        assertEquals(2.0f, reported.last())
        subject.pause()
        assertEquals(0f, reported.last())
    }
}
