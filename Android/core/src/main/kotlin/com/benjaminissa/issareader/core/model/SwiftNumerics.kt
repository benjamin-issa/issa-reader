package com.benjaminissa.issareader.core.model

import kotlin.math.floor

/**
 * Swift's `rounded()`: to the nearest whole number, half away from zero.
 *
 * Neither of Kotlin's own does this — `kotlin.math.round` rounds half to even
 * and `Math.round` rounds half up — and the two clients have to print the
 * same number for the same value: 2.5 stars is three, on both.
 */
fun Double.roundedHalfAwayFromZero(): Double {
    if (!isFinite()) return this
    return if (this >= 0) floor(this + 0.5) else -floor(-this + 0.5)
}

/**
 * Swift's `max(_:_:)`, which is `y >= x ? y : x`.
 *
 * The difference from `maxOf` is NaN: Swift's returns the *other* operand when
 * one is NaN in the second position (`max(0, .nan)` is 0), where `maxOf`
 * returns NaN. Code that was written against Swift's answer, and documents
 * it, says so by calling this.
 */
internal fun swiftMax(x: Double, y: Double): Double = if (y >= x) y else x

/** Swift's `min(_:_:)`, which is `y < x ? y : x`. See [swiftMax]. */
internal fun swiftMin(x: Double, y: Double): Double = if (y < x) y else x
