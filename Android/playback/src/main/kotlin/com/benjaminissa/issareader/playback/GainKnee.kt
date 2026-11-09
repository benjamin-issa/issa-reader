package com.benjaminissa.issareader.playback

import kotlin.math.abs

/**
 * The gain stage's arithmetic: scale a block of samples, softly limiting
 * anything the scale pushed past the knee.
 *
 * Swift's `GainTap` kernel, with the `MTAudioProcessingTap` around it left
 * behind: on Android the samples arrive through a Media3 audio processor
 * placed *after* the time-stretcher (`GainKneeAudioProcessor`), so the level
 * does not depend on the playback rate, exactly as the iOS tap is created
 * post-effects for the same reason.
 *
 * The player's own volume cannot do this job: it is documented 0…1 on both
 * platforms and does not go above unity, so it can make a book quieter and
 * never louder — and it is already spoken for by the sleep timer's fade. So the
 * per-book level ([VolumeTrim]) lives in the samples themselves.
 *
 * The shape, for a scaled sample `y` and a threshold `T` of 0.8:
 *
 * - `|y| ≤ T` — untouched, bit for bit.
 * - `T < |y| < 2 − T` — `|y| − (|y| − T)² / 4(1 − T)`, signed like `y`.
 * - `|y| ≥ 2 − T` — exactly 1.
 *
 * A knee rather than a curve over the whole signal, and that is the point of
 * it. Measured on an ACX-mastered book at 2.5×, this delivers 7.90 dB of the
 * 7.96 asked for, at 2.41% THD+N, with 1.8% of blocks touching the ceiling; the
 * hard clip it replaces put 17.4% of blocks on the ceiling and its error above
 * 8 kHz was 4 dB worse. `tanh` and a cubic were both tried and both rejected
 * for the same reason: they shape *every* sample, so at gain 1.0 `tanh` costs
 * 0.16 dB and 1.59% THD+N — a volume control that audibly changes a book set
 * to "As recorded" is not shippable. Look-ahead limiting was rejected too: 3 ms
 * of latency, a delay line nothing flushes on a seek, and it throws the boost
 * away — 4.65 dB of the 7.96 asked for on a hot master, which is the wrong
 * trade for a reader whose complaint is that they cannot hear a difference.
 *
 * Below unity the knee is not engaged at all. A gain under 1 cannot push an
 * in-range recording out of range, and a sample the recording already carried
 * out of range is left exactly as it was — the same promise `gain == 1` has
 * always kept by short-circuiting.
 *
 * Float maths, in the order the Swift kernel's vDSP passes run, so the two
 * clients produce the same bits for the same samples. Real-time safe: no
 * allocation and no lock, over one caller-supplied scratch buffer.
 */
object GainKnee {
    /**
     * Where the knee starts, in linear amplitude. Everything quieter than this
     * is passed through bit-exact, which is the whole reason a knee was chosen
     * over the shapes that curve the entire signal.
     */
    @JvmField val threshold: Float = 0.8f

    /**
     * Where the knee reaches the ceiling. Above it every sample is exactly 1.
     *
     * `2 − T` and not a number of its own: it is what makes the curve meet the
     * ceiling with a slope of zero, so the limiter has no corner at either end.
     */
    @JvmField val ceiling: Float = 2f - threshold

    /**
     * The quadratic's coefficient, `1 / 4(1 − T)`. Chosen so the curve leaves
     * the threshold at slope 1 and arrives at [ceiling] at slope 0 and height 1.
     */
    @JvmField val curvature: Float = 1f / (4f * (1f - threshold))

    /**
     * Scales `samples[offset until offset + count]` by [gain], limiting past the
     * knee.
     *
     * Layout-agnostic — mono, interleaved stereo and one channel of a
     * deinterleaved pair are all just a run of floats.
     *
     * @param scratch working room the kernel writes over. Any size: the samples
     *   are walked in chunks of it, which is exact because the shape is
     *   memoryless — no sample's output depends on its neighbours. An empty one
     *   is answered with the hard clip this replaced rather than with
     *   silence-or-nothing, so a stage that somehow reached the audio thread
     *   without scratch still delivers the level the reader asked for.
     */
    fun apply(
        gain: Float,
        samples: FloatArray,
        offset: Int = 0,
        count: Int = samples.size - offset,
        scratch: FloatArray,
    ) {
        if (gain == 1f || count <= 0) return
        val end = offset + count
        for (index in offset until end) samples[index] = samples[index] * gain
        if (!(gain > 1f)) return

        if (scratch.isEmpty()) {
            for (index in offset until end) samples[index] = clip(samples[index], -1f, 1f)
            return
        }
        var at = 0
        while (at < count) {
            limit(samples, offset + at, minOf(scratch.size, count - at), scratch)
            at += scratch.size
        }
    }

    /** The knee itself, over one run of samples that fits the scratch. */
    private fun limit(samples: FloatArray, start: Int, frames: Int, temp: FloatArray) {
        var peak = 0f
        for (index in 0 until frames) {
            val magnitude = abs(samples[start + index])
            temp[index] = magnitude
            // NaN-propagating, as `vDSP_maxv` is: once the peak is NaN nothing
            // compares above it.
            if (magnitude > peak || magnitude.isNaN()) peak = magnitude
        }
        // Written inverted, and it matters: a NaN anywhere in the block makes
        // the peak NaN, `NaN <= threshold` is false, and the block therefore
        // takes the long path — where the poison stays a NaN instead of being
        // read as "quiet" and skipped. Most blocks of most books never reach
        // the knee at all, and this is what makes them cheap.
        if (peak <= threshold) return

        for (index in 0 until frames) {
            // Everything past the point where the curve has already reached 1,
            // ±infinity included, folded onto the one value the arithmetic
            // below turns into exactly 1.
            val sample = clip(samples[start + index], -ceiling, ceiling)
            // How far the sample is past the knee, floored at zero so every
            // sample under it is reduced by exactly nothing (`vDSP_vthr`, which
            // also floors a NaN).
            var excess = abs(sample) + (-threshold)
            excess = if (excess >= 0f) excess else 0f
            // (excess)² / 4(1 − T), signed like the sample it comes off.
            excess *= excess
            excess *= curvature
            temp[index] = Math.copySign(excess, sample)
            samples[start + index] = sample - temp[index]
        }
    }

    /** `vDSP_vclip`'s comparison, which passes a NaN through. */
    private fun clip(value: Float, low: Float, high: Float): Float =
        if (value < low) low else if (value > high) high else value
}
