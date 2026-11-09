package com.benjaminissa.issareader.playback

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.UUID
import kotlin.math.abs

// Ported from `GainTapTests.swift` (`GainKernelTests`): the arithmetic, on its
// own, with no audio machinery in the way. The decode, per-tap and
// `MTAudioProcessingTap` suites live in `playback-android`, against the Media3
// audio processor, or are listed as not ported in PORTING.md.

class GainKneeTest {
    /**
     * Runs the kernel over a copy, with scratch of the given size — the default
     * being room for the whole block, which is what a prepared stage hands it.
     */
    private fun applied(gain: Float, input: FloatArray, scratch: Int? = null): FloatArray {
        val samples = input.copyOf()
        val room = FloatArray(scratch ?: maxOf(input.size, 1)) { Float.NaN }
        GainKnee.apply(gain, samples, scratch = room)
        return samples
    }

    private fun applied(gain: Float, vararg input: Float): FloatArray = applied(gain, input)

    private val threshold = GainKnee.threshold
    private val ceiling = GainKnee.ceiling

    /** Above unity a sample far past the knee lands exactly on the ceiling. */
    @Test
    fun clipsRatherThanWrapping() {
        val samples = applied(1.5f, 0.9f, -0.9f, 0.5f, -0.5f, 0f)
        assertEquals("0.9 × 1.5 is 1.35, past 2 − T, so it is exactly 1", 1.0f, samples[0])
        assertEquals(-1.0f, samples[1])
        assertEquals("0.75 is under the knee and must not be touched at all", 0.75f, samples[2])
        assertEquals(-0.75f, samples[3])
        assertTrue(samples[4] == 0f)
    }

    /** Below unity every sample scales and nothing meets the ceiling. */
    @Test
    fun scalesDown() {
        val samples = applied(0.5f, 1.0f, -1.0f, 0.5f, 0f)
        assertEquals(0.5f, samples[0])
        assertEquals(-0.5f, samples[1])
        assertEquals(0.25f, samples[2])
        assertTrue(samples[3] == 0f)
    }

    /**
     * The common case by a wide margin — most books are never trimmed — and it
     * runs on the audio thread, so it has to cost nothing. Including the clip:
     * an out-of-range sample the recording already contained is left exactly as
     * it was, because at unity this code is not in the path.
     */
    @Test
    fun unityIsFree() {
        val original = floatArrayOf(0.9f, -0.9f, 0.123_456f, 2.0f, -2.0f)
        assertTrue(sameSamples(original, applied(1f, original)))
    }

    /**
     * The promise `tanh` and a cubic both broke, and the reason neither was
     * chosen. They shape every sample, so they colour a book at gains that
     * cannot possibly clip. Under unity this kernel multiplies and stops.
     *
     * The gains are unity and every rung of the quiet half of the slider, 0 dB
     * down to −8 dB.
     */
    @Test
    fun exactBelowUnity() {
        for (gain in floatArrayOf(1.0f, 0.891_251f, 0.794_328f, 0.707_946f, 0.630_957f, 0.562_341f, 0.501_187f, 0.446_684f, 0.398_107f)) {
            // Loud samples included, and they are the point: at 0.99 × 0.891 the
            // product is 0.882, well past the knee, and the knee must not see it.
            val input = floatArrayOf(0f, 0.5f, -0.5f, 0.99f, -0.99f, 1.0f, -1.0f, 0.123_456_7f) +
                FloatArray(2000) { -1 + 2 * it.toFloat() / 1999 }
            val expected = FloatArray(input.size) { input[it] * gain }
            assertTrue("$gain", sameSamples(expected, applied(gain, input)))
        }
    }

    /**
     * The other half of the same promise, and the harder half: at a gain that
     * *does* engage the knee, a sample under the threshold still comes out of
     * the multiply untouched — even sitting next to one that is being limited,
     * which is the case a whole-block early-out would flatter.
     */
    @Test
    fun transparentBelowTheKnee() {
        val gain = 2.512f
        // Everything here scales to at most 0.8 × 0.999.
        val input = FloatArray(4000) { -0.318f + 0.636f * it.toFloat() / 3999 }
        val quiet = applied(gain, input)
        assertTrue(sameSamples(FloatArray(input.size) { input[it] * gain }, quiet))

        // And again with one sample loud enough to force the long path.
        val mixed = applied(gain, input + floatArrayOf(0.9f))
        assertTrue(
            "the early-out was doing the work, not the arithmetic",
            sameSamples(FloatArray(input.size) { input[it] * gain }, mixed.copyOf(input.size)),
        )
        assertEquals(1.0f, mixed.last())
    }

    /**
     * The three pieces of the curve, checked where they join. `f(2 − T)` has to
     * be exactly 1 or the limiter has a step in it at the loudest moment of the
     * loudest passage.
     */
    @Test
    fun shape() {
        val gain = 2.0f
        // Straight onto the join, and either side of it. A hair either side will
        // not do: the curve arrives at the ceiling with a slope of zero, which is
        // the whole point of it, so a step of 1e-4 lands 1.25e-8 under 1 —
        // closer than a Float can hold at that magnitude.
        val landed = applied(gain, ceiling / gain, (ceiling - 0.05f) / gain, (ceiling + 0.05f) / gain)
        assertEquals("f(2 − T) is not exactly 1, got ${landed[0]}", 1.0f, landed[0])
        assertTrue("the curve is on the ceiling before it reaches it, ${landed[1]}", landed[1] < 1.0f)
        assertEquals(1.0f, landed[2])

        val rising = FloatArray(4001) { it.toFloat() / 4000 }
        val positive = applied(gain, rising)
        val negative = applied(gain, FloatArray(rising.size) { -rising[it] })
        assertTrue("f(−x) ≠ −f(x)", positive.indices.all { positive[it] == -negative[it] })
        assertTrue("the curve goes back on itself", (1 until positive.size).all { positive[it - 1] <= positive[it] })
        assertTrue(positive.all { it <= 1.0f })
        assertEquals(1.0f, positive.last())
    }

    /**
     * What makes it a knee rather than a corner. A hard clip's slope falls from
     * 1 to 0 in one sample and that discontinuity is the crackle; here it
     * arrives at the threshold still at 1 and leaves the ceiling at 0.
     */
    @Test
    fun unitySlopeAtTheKnee() {
        val gain = 2.0f
        val step = 1e-4f
        val around = applied(gain, (threshold - step) / gain, (threshold + step) / gain)
        val slope = (around[1] - around[0]) / (2 * step)
        assertTrue("the knee has a corner in it, slope $slope", abs(slope - 1) < 0.01)
    }

    /**
     * A decoder can hand back anything. The rule is that poison is passed on
     * rather than turned into full-scale noise: a NaN stays a NaN — which is what
     * it did before the limiter arrived — and an infinity, which *is*
     * representable as a level, lands on the ceiling like any other loud sample.
     */
    @Test
    fun nonFinite() {
        val poisoned = applied(2.0f, Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY, 0.25f)
        assertTrue("a NaN was read as a level", poisoned[0].isNaN())
        assertEquals(1.0f, poisoned[1])
        assertEquals(-1.0f, poisoned[2])
        assertEquals(0.5f, poisoned[3])

        // Alone, so the block's peak is the NaN itself. The peak is NaN,
        // `NaN <= threshold` is false, and the block therefore does *not* take
        // the quiet early-out — which is the ordering this depends on.
        assertTrue(applied(2.0f, Float.NaN)[0].isNaN())
    }

    /**
     * The test that catches a scratch buffer leaking state across calls, or an
     * early-out that depends on where the block boundaries happen to fall. The
     * audio sink picks the block size and it changes with the route, the sample
     * rate and whatever else the system is doing.
     */
    @Test
    fun blockSizeInvariance() {
        val ramp = FloatArray(4096) { -1 + 2 * it.toFloat() / 4095 }
        val whole = applied(2.512f, ramp)

        for (size in listOf(1024, 37, 1, 4095, 4096)) {
            val chunked = ramp.copyOf()
            val scratch = FloatArray(size) { Float.NaN }
            var offset = 0
            while (offset < chunked.size) {
                val frames = minOf(size, chunked.size - offset)
                GainKnee.apply(2.512f, chunked, offset, frames, scratch)
                offset += frames
            }
            assertTrue("blocks of $size do not agree with one block", sameSamples(whole, chunked))
        }
    }

    /**
     * A stage prepared for 512 frames handed 4096. It should not happen, and the
     * kernel walks the block in chunks of whatever room it has rather than
     * running off the end of the scratch if it does.
     */
    @Test
    fun scratchSmallerThanTheBlock() {
        val ramp = FloatArray(4096) { -1 + 2 * it.toFloat() / 4095 }
        for (size in listOf(1, 7, 512, 4095)) {
            assertTrue("$size", sameSamples(applied(2.512f, ramp), applied(2.512f, ramp, scratch = size)))
        }
    }

    /** An empty buffer is a no-op. */
    @Test
    fun emptyBuffer() {
        val samples = FloatArray(0)
        GainKnee.apply(1.5f, samples, scratch = FloatArray(0))
        assertEquals(0, samples.size)
        // And a run of nothing inside a real buffer, which is what a sink can
        // genuinely hand over.
        val untouched = floatArrayOf(0.5f, 0.5f)
        GainKnee.apply(1.5f, untouched, offset = 1, count = 0, scratch = FloatArray(4))
        assertTrue(sameSamples(floatArrayOf(0.5f, 0.5f), untouched))
    }

    /**
     * The only path that can reach the kernel without working room is a stage
     * that reported no frames to prepare. If it ever happens anyway, the reader
     * gets the level they asked for, hard-limited — never a chapter that
     * silently plays flat.
     */
    @Test
    fun noScratch() {
        val samples = applied(2.0f, floatArrayOf(0.1f, 0.9f, -0.9f), scratch = 0)
        assertEquals(0.2f, samples[0])
        assertEquals(1.0f, samples[1])
        assertEquals(-1.0f, samples[2])
    }
}

// Ported from `GainTapTests.swift` (`AudioPlayerGainTests`), over the scripted
// engine: whether an item's audio runs through the gain stage is the engine's
// answer, and the scripted one gives the answers AVFoundation gave.

/** How the two levels combine, and which of them carries the trim. */
class AudioPlayerGainTest {
    /** A gain outside the range is clamped on the way in. */
    @Test
    fun clampsGain() {
        val player = scriptedPlayer()
        player.gain = 4f
        assertEquals(VolumeTrim.gainRange.endInclusive, player.gain)
        player.gain = 0.1f
        assertEquals(VolumeTrim.gainRange.start, player.gain)
        // In range, and it has to stay: 2× is +6 dB, two rungs below the top,
        // and the old ±50% bound would have taken it back to 1.5.
        player.gain = 2f
        assertEquals(2f, player.gain)
        assertEquals("and the gain stage hears it", 2f, player.scripted.gain)
        player.gain = Float.NaN
        assertEquals(1f, player.gain)
    }

    /**
     * "Not loaded yet" and "cannot be made louder" are different answers, and the
     * screen that captions the second must not caption the first.
     *
     * The fallback arithmetic is the same either way, because there is no gain
     * stage either way.
     */
    @Test
    fun nothingLoadedYet() {
        val player = scriptedPlayer()
        assertNull(player.tapCarriesGain)
        player.gain = VolumeTrim.gain(-6)
        assertTrue(
            "the quieter half has to arrive through the player's own volume",
            abs(player.underlyingVolume - VolumeTrim.gain(-6)) < 1e-6,
        )
        player.gain = VolumeTrim.gain(8)
        assertEquals("and the louder half has nowhere to go", 1f, player.underlyingVolume)
    }

    /** A file with real tracks gets the gain stage, and the fade keeps the player's volume. */
    @Test
    fun localFileCarriesTheTap() = runTest {
        val player = scriptedPlayer()
        assertEquals(AudioPlayer.LoadOutcome.LOADED, player.load(AudioLocation.LocalFile(Silence.file), "sine.wav"))
        assertEquals("a local file has a track to attach to", true, player.tapCarriesGain)

        // The gain is in the samples, so the player's own volume is left to the
        // sleep timer alone — at 1 until it fades.
        player.gain = 1.5f
        assertEquals(1f, player.underlyingVolume)
        player.volume = 0.5f
        assertEquals("the fade must not be multiplied by the trim twice", 0.5f, player.underlyingVolume)
    }

    /**
     * The reason the volume is not simply the fade: with no gain stage, the only
     * level left is the player's own. It can go down and it cannot go up.
     *
     * This is the asset that will not load *at all* — the file is not there.
     */
    @Test
    fun fallbackWhenNothingLoads() = runTest {
        val missing = File(System.getProperty("java.io.tmpdir"), "issa-not-audio-${UUID.randomUUID()}.wav")
        val player = scriptedPlayer()
        player.load(AudioLocation.LocalFile(missing), "missing.wav")
        assertEquals(false, player.tapCarriesGain)
        assertEquals("there is no honest length to report", 0.0, player.duration, 0.0)

        player.gain = 0.5f
        assertEquals("quieter is expressible without a gain stage", 0.5f, player.underlyingVolume)
        player.gain = VolumeTrim.gainRange.endInclusive
        assertEquals(
            "+8 dB is not expressible without a gain stage, and must not be faked by clipping",
            1f, player.underlyingVolume,
        )
    }

    /**
     * The no-gain-stage branch with a real duration: the tracks resolve and hold
     * nothing to hang the gain on, while the duration resolves perfectly well —
     * and the scrubber, the "…m left" caption and the end-of-track arithmetic all
     * depend on it. A track list that fails while the duration succeeds is the
     * same branch, which is why the two are loaded separately.
     */
    @Test
    fun durationSurvivesMissingTracks() = runTest {
        val backend = ScriptedBackend(carriesGainOf = { false })
        val player = scriptedPlayer(backend)
        player.load(AudioLocation.LocalFile(Silence.file), "silent.mp4")
        assertEquals("no audio track to attach a gain stage to", false, player.tapCarriesGain)
        assertTrue("the duration loaded and must not be thrown away, was ${player.duration}", player.duration > 0.5)

        player.gain = 0.5f
        assertEquals(0.5f, player.underlyingVolume)
        player.gain = VolumeTrim.gainRange.endInclusive
        assertEquals(1f, player.underlyingVolume)

        // And a track list that fails outright, beside a duration that loads.
        val failing = scriptedPlayer(ScriptedBackend(carriesGainOf = { null }))
        assertEquals(AudioPlayer.LoadOutcome.LOADED, failing.load(AudioLocation.LocalFile(Silence.file), "stream.m3u8"))
        assertEquals(false, failing.tapCarriesGain)
        assertEquals(Silence.DURATION, failing.duration, 0.0)
    }
}
