package com.benjaminissa.issareader.playback.android

import androidx.media3.common.C
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.SonicAudioProcessor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.log10
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt

// Ported from `GainTapTests.swift` (`GainTapDecodeTests`, and what of
// `GainTapPerTapStateTests` applies to a sink's processor): a book's samples
// through the gain stage, because the kernel being right says nothing about
// whether the stage was ever consulted. A stage that is silently skipped looks
// exactly like one that is applied and happens to do nothing.

@RunWith(RobolectricTestRunner::class)
class GainKneeAudioProcessorTest {
    private val mono = AudioProcessor.AudioFormat(44_100, 1, C.ENCODING_PCM_16BIT)

    /** One second of 440 Hz at a known amplitude, as 16-bit mono: a sine has a peak, and speech does not. */
    private fun sine(amplitude: Double): ShortArray = ShortArray(44_100) {
        (amplitude * sin(2 * PI * 440 * it / 44_100.0) * 32767).roundToInt().toShort()
    }

    private class Measured(val peak: Double, val rms: Double, val clipped: Double)

    /**
     * What came out of the stage, measured three ways. The peak alone cannot
     * tell "the level moved" from "the level was clamped"; the RMS is what says
     * how loud the book actually got, and the clipped fraction at what cost.
     * Fed in blocks of 1024 samples, as a sink feeds it.
     */
    private fun measure(samples: ShortArray, stage: GainKneeAudioProcessor): Measured {
        stage.configure(mono)
        stage.flush()
        val out = ArrayList<Short>()
        var at = 0
        while (at < samples.size) {
            val count = minOf(1024, samples.size - at)
            val block = ByteBuffer.allocateDirect(count * 2).order(ByteOrder.nativeOrder())
            for (index in 0 until count) block.putShort(samples[at + index])
            block.flip()
            stage.queueInput(block)
            val output = stage.output
            while (output.hasRemaining()) out.add(output.short)
            at += count
        }
        var peak = 0.0
        var squares = 0.0
        var clipped = 0
        for (value in out) {
            val magnitude = abs(value / 32768.0)
            peak = maxOf(peak, magnitude)
            squares += magnitude * magnitude
            if (value >= Short.MAX_VALUE || value <= Short.MIN_VALUE + 1) clipped += 1
        }
        return Measured(peak, sqrt(squares / out.size), clipped.toDouble() / out.size)
    }

    private fun stage(gain: Float): GainKneeAudioProcessor = GainKneeAudioProcessor().also { it.gain = gain }

    /** A recording read through the stage comes out louder. */
    @Test
    fun louder() {
        val stage = stage(1.5f)
        val measured = measure(sine(0.5), stage)
        assertTrue("the stage was never consulted, so the peak below means nothing", stage.processedFrames.get() > 0)
        assertEquals("0.5 × 1.5 should be 0.75, got ${measured.peak}", 0.75, measured.peak, 0.02)
    }

    /** And quieter the other way. */
    @Test
    fun quieter() {
        val stage = stage(0.5f)
        val measured = measure(sine(0.5), stage)
        assertTrue(stage.processedFrames.get() > 0)
        assertEquals("0.5 × 0.5 should be 0.25, got ${measured.peak}", 0.25, measured.peak, 0.02)
    }

    /**
     * A book already mastered close to full scale is the one that most tempts a
     * listener to turn it up, and it is the one where an unlimited multiply
     * would wrap into a buzz.
     */
    @Test
    fun loudRecordingStaysInRange() {
        val stage = stage(1.5f)
        val measured = measure(sine(0.9), stage)
        assertTrue(stage.processedFrames.get() > 0)
        assertTrue("0.9 × 1.5 is 1.35 and must be limited, got ${measured.peak}", measured.peak <= 1.0)
        assertTrue("and it should be reaching the ceiling, not sitting under it", measured.peak > 0.99)
    }

    /**
     * The assertion the reader's complaint turns on: loudness, measured as RMS,
     * to a tenth of a decibel. The fixture is quiet enough that the knee never
     * engages, which is what makes the arithmetic checkable at all.
     */
    @Test
    fun deliveredLevel() {
        for ((gain, decibels) in listOf(0.398_107_2f to -8.0, 1.0f to 0.0, 2.511_886_4f to 8.0)) {
            val reference = measure(sine(0.2), stage(1f))
            val stage = stage(gain)
            val measured = measure(sine(0.2), stage)
            assertTrue(stage.processedFrames.get() > 0)
            val delivered = 20 * log10(measured.rms / reference.rms)
            assertEquals("$decibels dB was asked for and $delivered dB arrived", decibels, delivered, 0.1)
        }
    }

    /**
     * The top of the slider on a book quiet enough to want it — the book the
     * control exists for. Nothing may touch the ceiling: if the limiter reaches
     * for a quietly mastered file at +8 dB, the threshold is in the wrong place.
     */
    @Test
    fun quietBookAtTheTop() {
        val stage = stage(2.511_886_4f)
        val measured = measure(sine(0.2), stage)
        assertTrue(stage.processedFrames.get() > 0)
        assertEquals("0.2 × 2.512 should be 0.502, got ${measured.peak}", 0.502, measured.peak, 0.02)
        assertEquals("a quiet book was limited at +8 dB", 0.0, measured.clipped, 0.0)
    }

    /**
     * The same rung on a book mastered hot, where +8 dB is 2.26 times more than
     * there is room for. The knee is what stops that being a crackle.
     */
    @Test
    fun hotBookAtTheTop() {
        val stage = stage(2.511_886_4f)
        val measured = measure(sine(0.9), stage)
        assertTrue(stage.processedFrames.get() > 0)
        assertTrue("0.9 × 2.512 is 2.26 and must be limited, got ${measured.peak}", measured.peak <= 1.0)
        assertTrue("and it should be reaching the ceiling, not sitting under it", measured.peak > 0.99)
    }

    /**
     * At unity not a sample moves: a book set to "as recorded" is bit-exact
     * through the stage.
     */
    @Test
    fun unityIsBitExact() {
        val input = sine(0.9)
        val stage = stage(1f)
        stage.configure(mono)
        stage.flush()
        val block = ByteBuffer.allocateDirect(input.size * 2).order(ByteOrder.nativeOrder())
        for (value in input) block.putShort(value)
        block.flip()
        stage.queueInput(block)
        val output = stage.output
        val out = ShortArray(input.size) { output.short }
        assertTrue(input.contentEquals(out))
    }

    /**
     * No samples it can read, no stage — and the sink has to be able to tell.
     * The Android counterpart of "no audio tracks, no mix": a format other than
     * 16-bit PCM is not taken on, rather than reinterpreted, which would be noise
     * at full scale.
     */
    @Test
    fun aFormatItCannotReadIsNotTakenOn() {
        val stage = stage(2f)
        stage.configure(AudioProcessor.AudioFormat(44_100, 1, C.ENCODING_PCM_FLOAT))
        assertFalse(stage.isActive)
        stage.configure(mono)
        assertTrue(stage.isActive)
    }

    /**
     * One stage lives for the life of the player and is configured anew for
     * every item and every format, so a chapter change cannot drop the level —
     * the failure iOS's per-tap state closed, where one chapter played flat.
     */
    @Test
    fun theLevelSurvivesAReconfiguration() {
        val stage = stage(1.5f)
        stage.configure(AudioProcessor.AudioFormat(22_050, 2, C.ENCODING_PCM_16BIT))
        stage.flush()
        stage.reset()
        val measured = measure(sine(0.5), stage)
        assertEquals("the new format's samples still carry the level", 0.75, measured.peak, 0.02)
    }

    /** The stage is the last thing the samples pass through, after the time-stretcher. */
    @Test
    fun theStageComesAfterSonic() {
        val stage = GainKneeAudioProcessor()
        val chain = GainAfterSonicChain(stage)
        val processors = chain.audioProcessors
        assertSame(stage, processors.last())
        assertTrue("Sonic directly in front of it", processors[processors.size - 2] is SonicAudioProcessor)
        // And Sonic keeps its say over the speed.
        val parameters = PlaybackParameters(1.5f, 1f)
        assertEquals(parameters, chain.applyPlaybackParameters(parameters))
    }
}
