package com.benjaminissa.issareader.playback.android

import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import androidx.media3.common.util.UnstableApi
import com.benjaminissa.issareader.playback.GainKnee
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.roundToInt

/**
 * The gain stage: a Media3 audio processor that scales 16-bit PCM by the
 * book's level, softly limiting anything the scale pushes past the knee.
 *
 * The Android counterpart of iOS's `GainTap`. The player's own volume is 0…1
 * and spoken for by the sleep timer's fade, so a book that needs to be
 * *louder* can only be made so in the samples. Placed after the
 * time-stretcher (see [GainAfterSonicChain]) for the reason the iOS tap is
 * created post-effects: gain applied before Sonic would be re-scaled by it, and
 * the level would then depend on the playback rate.
 *
 * Float maths: each sample is read as a float in −1…1, run through
 * [GainKnee.apply] exactly as the iOS kernel runs its float samples, and
 * written back. At unity it is a copy and nothing else, so a book set to "as
 * recorded" is bit-exact.
 *
 * One instance lives for the life of the player and is configured by the
 * sink for every format it plays, so a chapter change does not drop the level.
 * [gain] is written on the main thread and read on the playback thread, which
 * may not block: a volatile float, no lock.
 *
 * A format other than 16-bit PCM is passed through untouched — the sink only
 * hands this 16-bit samples, because Sonic in front of it takes nothing else —
 * rather than reinterpreted, which would not be quiet or loud but noise at
 * full scale.
 */
@OptIn(UnstableApi::class)
class GainKneeAudioProcessor : BaseAudioProcessor() {
    /** The multiplier every sample is scaled by. 1 means "as recorded". */
    @Volatile var gain: Float = 1f

    /**
     * Frames this stage has actually processed. Nothing in the app reads it —
     * it is how a test tells "the stage was in the chain and ran" from "the
     * stage was attached and silently skipped", which is otherwise
     * indistinguishable from correct output.
     */
    val processedFrames = AtomicLong(0)

    private var samples = FloatArray(0)
    private var scratch = FloatArray(0)

    override fun onConfigure(inputAudioFormat: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat {
        if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT) return AudioProcessor.AudioFormat.NOT_SET
        return inputAudioFormat
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        val bytes = inputBuffer.remaining()
        if (bytes == 0) return
        val output = replaceOutputBuffer(bytes)
        val count = bytes / 2
        val frameSize = inputAudioFormat.bytesPerFrame.coerceAtLeast(2)
        processedFrames.addAndGet((bytes / frameSize).toLong())
        val gain = gain
        if (gain == 1f) {
            output.put(inputBuffer)
            output.flip()
            return
        }
        if (samples.size < count) samples = FloatArray(count)
        // Room for the whole block, as a prepared tap has room for its largest
        // buffer: the kernel walks anything bigger in chunks of it.
        if (scratch.size < count) scratch = FloatArray(count)
        val order = inputBuffer.order()
        val input = inputBuffer.slice().order(order)
        for (index in 0 until count) samples[index] = input.getShort(index * 2) / FULL_SCALE
        inputBuffer.position(inputBuffer.position() + count * 2)
        GainKnee.apply(gain, samples, 0, count, scratch)
        for (index in 0 until count) output.putShort(toShort(samples[index]))
        // An odd trailing byte cannot be a sample; it passes as it came.
        while (inputBuffer.hasRemaining()) output.put(inputBuffer.get())
        output.flip()
    }

    override fun onReset() {
        samples = FloatArray(0)
        scratch = FloatArray(0)
    }

    companion object {
        private const val FULL_SCALE = 32768f

        /**
         * Back to 16 bits: rounded, and clamped, because the knee's ceiling is
         * exactly 1. A NaN — which only a NaN gain could make — is silence
         * rather than an exception on the audio thread.
         */
        internal fun toShort(sample: Float): Short {
            if (sample.isNaN()) return 0
            val scaled = (sample * FULL_SCALE).roundToInt()
            return scaled.coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort()
        }
    }
}
