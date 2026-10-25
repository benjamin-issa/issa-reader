package com.benjaminissa.issareader.playback

import com.benjaminissa.issareader.core.model.roundedHalfAwayFromZero
import kotlin.math.abs
import kotlin.math.log10
import kotlin.math.pow

/**
 * How far one book's level may depart from the level it was recorded at.
 *
 * Self-hosted libraries are assembled from whatever the reader could find, so
 * one book is mastered six decibels under the next and the listener rides the
 * hardware volume between them. This is the per-book correction: a number of
 * decibels either side of "as recorded", stated once so the slider, the
 * keyboard shortcuts and the stored preference cannot disagree about what is
 * legal — the same defect [PlaybackRate] exists to close for speed.
 *
 * **Decibels, and that is the whole fix.** This shipped as a percentage of the
 * recorded level, and the percentage was lying twice over. −50% is −6.02 dB
 * while +50% is only +3.52 dB, so two thirds of a 9.5 dB slider sat on the
 * quiet side; and because the scale is linear the detents shrink as they climb
 * — −50 → −45% is 0.83 dB, +45 → +50% is 0.29 dB, and a +145 → +150% would
 * have been 0.18 dB. The just-noticeable difference on speech is about 1 dB,
 * so **every detent on the upper half of the old slider was below audibility**,
 * which is exactly what a reader reported: a difference they could hear
 * between the two ends and "pretty much" nowhere else.
 *
 * A ladder in decibels has none of that. Seventeen rungs from −8 to +8 in
 * steps of one, so every click is one just-noticeable difference wide,
 * wherever on the slider it is. The top rung is 2.512×, which is the 150%
 * louder that was asked for, hit almost exactly — and honestly, because a
 * label that says +8 dB is a claim about loudness rather than about a
 * multiplier the ear does not perceive linearly.
 *
 * Upwards it costs headroom: a book already mastered near full scale would
 * clip, which [GainKnee] limits with a soft knee rather than wrapping. That is
 * a trade the reader makes deliberately, one detent at a time, hearing each
 * one.
 *
 * Levels are taken as `Long` as well as `Int`: Swift's `Int` is 64-bit, and a
 * stored level is whatever a preferences file says.
 */
object VolumeTrim {
    /** The legal levels, in decibels either side of the recorded one. */
    val range: IntRange = -8..8

    /**
     * The detent spacing. One decibel is about the smallest change audible on
     * speech, so a finer slider would only offer values that feel like nothing
     * happened — which is precisely what the percentage scale offered.
     */
    const val STEP: Int = 1

    /**
     * The rungs themselves, named the way [PlaybackRate] names its own so a
     * caller walking the offered levels does not rederive them from the range.
     */
    val ladder: List<Int> = (range.first..range.last step STEP).toList()

    /**
     * The multipliers [range] maps onto — 0.398 to 2.512 — named so a caller
     * clamping a raw float does not have to rederive them. Read off [gain] so
     * the two cannot drift apart by a rounding.
     */
    val gainRange: ClosedFloatingPointRange<Float> = gain(range.first)..gain(range.last)

    /**
     * The nearest legal level.
     *
     * Both ends have to hold: a slider with a step still hands back the odd
     * unsnapped value while a drag is in flight, and a nudge or a restored
     * preference can arrive from outside the range entirely.
     *
     * **Clamped first, and snapped in integers.** The Swift version once
     * snapped through `Double` before the clamp, which trapped at the
     * magnitudes it exists to sanitise: `Double(Int.max)` rounds *up* to one
     * past `Int.max`, and converting that back is an uncatchable crash — on the
     * launch path, because every stored level runs through here while the app
     * is starting. Clamping first bounds every operand below to ±8, so nothing
     * here can overflow, and the second clamp is what keeps the answer legal if
     * [range]'s ends ever stop being multiples of [STEP].
     */
    fun clamped(decibels: Long): Int {
        val bounded = minOf(maxOf(decibels, range.first.toLong()), range.last.toLong()).toInt()
        // A step of one snaps nothing — every integer is already on the ladder
        // — and returning here is also what keeps the remainder below from
        // being a division by zero.
        if (STEP <= 1) return bounded
        val remainder = bounded % STEP
        if (remainder == 0) return bounded
        // Away from zero on a tie, which is what Swift's `rounded()` did.
        val carry = if (abs(remainder) * 2 >= STEP) (if (bounded < 0) -STEP else STEP) else 0
        val snapped = bounded - remainder + carry
        return minOf(maxOf(snapped, range.first), range.last)
    }

    fun clamped(decibels: Int): Int = clamped(decibels.toLong())

    /**
     * The multiplier a level stands for: 0 → 1, +8 → 2.512, −8 → 0.398.
     *
     * Exactly 1 at zero — `10^0` is, to the bit — which is what lets the gain
     * stage short-circuit an untrimmed book to no work at all.
     */
    fun gain(decibels: Long): Float = 10f.pow(clamped(decibels).toFloat() / 20)

    fun gain(decibels: Int): Float = gain(decibels.toLong())

    /**
     * The nearest legal multiplier.
     *
     * Non-finite input is answered with 1 rather than with a bound: a NaN gain
     * reaching the gain stage would multiply every sample into
     * silence-or-noise with nothing on screen to explain it, and "as recorded"
     * is the only honest reading of a number that is not a number.
     */
    fun clampedGain(gain: Float): Float {
        if (!gain.isFinite()) return 1f
        return minOf(maxOf(gain, gainRange.start), gainRange.endInclusive)
    }

    /**
     * The rung a level stored by a build that stored percentages stands for.
     *
     * Builds up to 1.1.0 (32) wrote a percentage of the recorded level. The
     * levels have to keep meaning what they meant — a reader who set a book to
     * −30% and never touched it again should hear the same book — so the
     * percentage is converted through the multiplier it always stood for
     * rather than reinterpreted as a number of decibels.
     *
     * Rounding to the nearest rung moves the level a little, and the arithmetic
     * says how much: over every value a shipped build could hold, the worst
     * shift is **0.4988 dB, at −25%** — half a just-noticeable difference, so
     * nobody can hear the migration happen.
     *
     * A percentage at or under −100 would be silence or a phase inversion, and
     * neither is a level any control offered; it reads as the bottom rung.
     */
    fun decibels(forLegacyPercent: Long): Int {
        val multiplier = 1 + forLegacyPercent.toDouble() / 100
        if (!(multiplier > 0)) return range.first
        return clamped((20 * log10(multiplier)).roundedHalfAwayFromZero().toLong())
    }

    fun decibels(forLegacyPercent: Int): Int = decibels(forLegacyPercent.toLong())

    /**
     * What the row shows on the right: "As recorded", "+3 dB" or "−6 dB".
     *
     * U+2212 MINUS SIGN, not a hyphen: the value is set in a monospaced-digit
     * face beside a "+" of the same width, and a hyphen is visibly shorter and
     * sits lower than the plus it alternates with.
     */
    fun label(decibels: Long): String {
        val legal = clamped(decibels)
        if (legal == 0) return "As recorded"
        return if (legal > 0) "+$legal dB" else "−${-legal} dB"
    }

    fun label(decibels: Int): String = label(decibels.toLong())

    /**
     * What a screen reader says instead. "+3 dB" is read as "plus three D B",
     * which says nothing about the direction the sound moves in.
     *
     * Singular at one decibel, which is a rung the reader will land on: the
     * step is a decibel, so it is the first thing either side of "as recorded".
     */
    fun spoken(decibels: Long): String {
        val legal = clamped(decibels)
        if (legal == 0) return "as recorded"
        val unit = if (abs(legal) == 1) "decibel" else "decibels"
        return if (legal > 0) "$legal $unit louder" else "${-legal} $unit quieter"
    }

    fun spoken(decibels: Int): String = spoken(decibels.toLong())
}
