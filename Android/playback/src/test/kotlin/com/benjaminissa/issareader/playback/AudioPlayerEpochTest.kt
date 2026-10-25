package com.benjaminissa.issareader.playback

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.UUID
import kotlin.math.abs

// Ported from `AudioPlayerEpochTests.swift`, over the scripted engine.

/**
 * The player's own contract with whoever drives it: which call owns the item,
 * which owns the playhead, and what a file that will not play does to both.
 */
class AudioPlayerEpochTest {
    private val silence = AudioLocation.LocalFile(Silence.file)

    /**
     * A clip time is whatever the overlay says. `SmilClock` refuses only the
     * non-finite and the negative, so `clipBegin="1e20s"` reaches the player,
     * and so does a manifest track that claims `1e300` seconds. The Swift seek
     * converted with a conversion that traps past `Int64.max / 600` seconds —
     * about 1.5e16 — and on infinity: a malformed book crashed the app on every
     * attempt to open it at that sentence.
     */
    @Test
    fun anAbsurdSeekDoesNotTrap() = runTest {
        for (seconds in listOf(1.6e16, 1e20, 1e300, Double.POSITIVE_INFINITY)) {
            val player = scriptedPlayer()
            player.load(silence, "silence.wav")

            player.seek(seconds)

            assertTrue("$seconds", player.currentTime.isFinite())
        }
    }

    // A file that will not play

    /**
     * A file the engine cannot open: the shape a files-source chunk deleted from
     * disk has, and a streamed track whose request failed.
     */
    private fun missingFile(): AudioLocation =
        AudioLocation.LocalFile(File(System.getProperty("java.io.tmpdir"), "issa-missing-${UUID.randomUUID()}.mp3"))

    /**
     * The player was told to play, the next file would not open, and it said
     * nothing: `load` reported success, `isPlaying` stayed true, and every
     * surface drew a pause glyph over silence while the sleep timer counted.
     */
    @Test
    fun aFileThatWillNotOpenStopsThePlayer() = runTest {
        val player = scriptedPlayer()
        player.play()

        val outcome = player.load(missingFile(), "missing.mp3", startAt = 30.0)

        assertEquals(AudioPlayer.LoadOutcome.FAILED, outcome)
        assertFalse("a player holding nothing it can play claimed to be playing", player.isPlaying)
        assertEquals(0f, player.engineRate)
    }

    /**
     * A failure reported for an item a later load has already replaced is about
     * audio nobody is listening to.
     */
    @Test
    fun aStaleFailureStopsNothing() = runTest {
        val player = scriptedPlayer()
        player.load(silence, "older.wav")
        val olderItem = player.itemGenerationForTests
        player.load(silence, "newer.wav")
        player.play()

        player.itemDidFail(olderItem, "test")
        assertTrue("the item playing now did not fail", player.isPlaying)

        // And the item playing now failing does stop it — the path the engine's
        // failure report takes.
        player.itemDidFail(player.itemGenerationForTests, "test")
        assertFalse(player.isPlaying)
    }

    // Which call owns the playhead

    /**
     * A seek into the file a load is still opening. The load used to wake up,
     * find no newer *load*, and run its own trailing seek over the newer one.
     */
    @Test
    fun aSeekDuringALoadOvertakesIt() = runTest {
        val player = scriptedPlayer()
        player.whileLoadingAsset = { player.seek(7.0) }

        val outcome = player.load(silence, "silence.wav", startAt = 300.0)

        assertEquals(AudioPlayer.LoadOutcome.OVERTAKEN, outcome)
        assertTrue("the load's own offset was written over the seek", abs(player.currentTime - 7) < 0.01)
        assertTrue("the engine ran the load's trailing seek: ${player.engineTime}", abs(player.engineTime - 7) < 0.01)
        // The item is still this load's, and what describes it was written.
        assertEquals("silence.wav", player.currentAudioHref)
        assertEquals(Silence.DURATION, player.duration, 0.0)
    }

    /** A load another load replaced. It owns nothing, and writes nothing. */
    @Test
    fun aSupersededLoadWritesNothing() = runTest {
        val player = scriptedPlayer()
        var newer: AudioPlayer.LoadOutcome? = null
        player.whileLoadingAsset = { newer = player.load(silence, "newer.wav", startAt = 42.0) }

        val older = player.load(silence, "older.wav", startAt = 300.0)

        assertEquals(AudioPlayer.LoadOutcome.SUPERSEDED, older)
        assertEquals(AudioPlayer.LoadOutcome.LOADED, newer)
        assertEquals("newer.wav", player.currentAudioHref)
        assertTrue(abs(player.currentTime - 42) < 0.01)
        assertTrue("the superseded load seeked the newer item: ${player.engineTime}", abs(player.engineTime - 42) < 0.01)
    }

    /**
     * A seek that completes after something newer took the playhead: the
     * trailing seek of a load the next load interrupted, which the engine calls
     * back unfinished. It wrote the clock and restored the rate regardless, so
     * the new item started from its first second with the old file's time on
     * the clock.
     *
     * The clock is not asserted mid-window: the engine really does move for the
     * stale seek here. What the guard owns is the answer and the rate.
     */
    @Test
    fun anOvertakenSeekWritesNothing() = runTest {
        val player = scriptedPlayer()
        player.load(silence, "older.wav", startAt = 60.0)
        player.play()
        val issuedBefore = player.playheadGeneration
        var owned: Boolean? = null
        var rateWhileLanding: Float? = null
        player.whileLoadingAsset = {
            // The older seek completing inside the newer load's window.
            owned = player.seekPlayhead(500.0, issuedBefore)
            rateWhileLanding = player.engineRate
        }

        player.load(silence, "newer.wav", startAt = 42.0)

        assertEquals("a seek something newer overtook claimed the playhead", false, owned)
        assertEquals("the stale seek started the new item before it was placed", 0f, rateWhileLanding)
        assertTrue(abs(player.currentTime - 42) < 0.01)
        assertEquals("and the newer load started it once placed", player.rate, player.engineRate)
    }

    /**
     * Play — or a new speed — pressed while a chapter is opening. Either one set
     * the engine's rate straight away, so the new item played from its first
     * second until the load's seek landed: for a streamed track, a network
     * round trip of the wrong audio.
     */
    @Test
    fun playDuringALoadWaitsForThePlacement() = runTest {
        val player = scriptedPlayer()
        var afterPlay: Float? = null
        var afterRate: Float? = null
        player.whileLoadingAsset = {
            player.play()
            afterPlay = player.engineRate
            player.rate = 1.5f
            afterRate = player.engineRate
        }

        val outcome = player.load(silence, "silence.wav", startAt = 120.0)

        assertEquals(AudioPlayer.LoadOutcome.LOADED, outcome)
        assertEquals("play started the new item before its seek had landed", 0f, afterPlay)
        assertEquals("a new speed started it too", 0f, afterRate)
        assertTrue("the intent is kept", player.isPlaying)
        assertEquals("and the placement honours the speed chosen meanwhile", 1.5f, player.engineRate)
    }

    /**
     * The conversion on its own: saturating where it used to trap, and the
     * round-up every ordinary target depends on left exactly as it was.
     */
    @Test
    fun seekTargetsSaturateAndRoundUp() {
        for (seconds in listOf(1.6e16, 1e20, 1e300, Double.POSITIVE_INFINITY)) {
            val target = AudioPlayer.mediaTime(seconds)
            assertEquals("$seconds s became $target", Long.MAX_VALUE, target.value)
            assertEquals(600, target.timescale)
        }
        // The largest that still fits is still exact.
        assertEquals(9_000_000_000_000_000_000L, AudioPlayer.mediaTime(1.5e16).value)
        assertEquals(MediaTime(2_550, 600), AudioPlayer.mediaTime(4.25))
        assertEquals("up, never to nearest", MediaTime(2_551, 600), AudioPlayer.mediaTime(4.2501))
        assertEquals(MediaTime(0, 600), AudioPlayer.mediaTime(-3.0))
        assertEquals(MediaTime.ZERO, AudioPlayer.mediaTime(Double.NaN))
    }
}
