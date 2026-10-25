package com.benjaminissa.issareader.render

/**
 * A span of a chapter's rendered string, in UTF-16 code units: Foundation's
 * `NSRange`, which is what every offset on the Swift side is.
 *
 * Kept as `location` and `length` rather than a Kotlin `IntRange` so the
 * arithmetic reads as the Swift does — `NSMaxRange` is [end], one past the
 * last unit, and `NSLocationInRange` is [contains] — and so a range written
 * down by one client (`fragmentRanges`, the parity goldens) is the same pair of
 * numbers on the other.
 */
data class TextRange(val location: Int, val length: Int) {
    /** `NSMaxRange`: one past the last unit. */
    val end: Int get() = location + length

    /** `NSLocationInRange`: false for every index of an empty range. */
    operator fun contains(index: Int): Boolean = index >= location && index - location < length

    /**
     * `NSIntersectionRange`. Disjoint ranges answer an empty range, as
     * Foundation's does, so `intersection(other).length > 0` is the overlap
     * test the Swift code writes.
     */
    fun intersection(other: TextRange): TextRange {
        val start = maxOf(location, other.location)
        val stop = minOf(end, other.end)
        return if (stop <= start) TextRange(0, 0) else TextRange(start, stop - start)
    }

    override fun toString(): String = "{$location, $length}"
}
