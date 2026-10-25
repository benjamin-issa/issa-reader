package com.benjaminissa.issareader.core.model

/**
 * This value as a progression through a book: finite, and between 0 and 1.
 *
 * `coerceIn(0.0, 1.0)` passes NaN straight through, and a NaN saved as a
 * position is how a reader's place was lost; so this answers `null` when there
 * is no honest answer, rather than 0. A NaN is not "the start of the book".
 */
val Double.asProgression: Double?
    get() = if (isFinite()) coerceIn(0.0, 1.0) else null

/**
 * The same clamp, for callers with a sensible default and nothing to report —
 * a progress bar's width, say, where 0 is the right answer for a value that
 * means nothing.
 */
fun Double.clampedToUnitInterval(orElse: Double = 0.0): Double = asProgression ?: orElse
