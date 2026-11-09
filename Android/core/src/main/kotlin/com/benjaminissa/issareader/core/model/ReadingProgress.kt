package com.benjaminissa.issareader.core.model

/**
 * How far through a book, said the same way everywhere.
 *
 * There is only ever one quantity — `totalProgression`, which the reader
 * computes and the server hands back verbatim — but it used to be *formatted*
 * two ways. The reader's footer and the widget rounded; the book screen and
 * the Continue card truncated. So a book at 13.7% read "14%" in the reader and
 * "13%" everywhere else: an off-by-one that never closed, because it was never
 * staleness.
 */
object ReadingProgress {
    /**
     * The whole percent to show a reader.
     *
     * Rounded, not truncated. Truncating means a book sits at "99%" through the
     * whole of its last page, and that a ring drawn from the same value appears
     * closed while the number beside it disagrees.
     *
     * [asProgression], the shared clamp, rather than an inline `coerceIn`:
     * that passes NaN through, so whether an inline clamp catches one depends
     * on how it was written. Bounded to 0...1 first, so the conversion cannot
     * be handed anything out of range. Rounded half away from zero, as Swift's
     * `rounded()` is, so 13.5% is 14 on both clients.
     */
    fun percent(progression: Double): Int =
        ((progression.asProgression ?: 0.0) * 100).roundedHalfAwayFromZero().toInt()

    /** The same number as a label: "42%". */
    fun percentText(progression: Double): String = "${percent(progression)}%"
}
