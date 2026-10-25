package com.benjaminissa.issareader.playback

import com.benjaminissa.issareader.core.model.asProgression
import com.benjaminissa.issareader.core.model.roundedHalfAwayFromZero
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * How much of a book a progress bar stands for.
 *
 * The chapter, by default. The whole book sounds like the honest answer, but
 * for a five-hour audiobook it makes a chapter a sliver you cannot aim at, and
 * "3:49:09 remaining" answers a question nobody asked while listening to
 * chapter seventeen. [CHAPTER] is first here so the picker lists the default
 * first.
 *
 * [rawValue] is what sits in preferences, so renaming a case must not quietly
 * reset everyone who chose the other one.
 */
@Serializable
enum class ProgressScope(val rawValue: String) {
    @SerialName("chapter") CHAPTER("chapter"),
    @SerialName("book") BOOK("book"),
    ;

    val title: String
        get() = when (this) {
            BOOK -> "Whole book"
            // "This chapter" read as a description of the bar rather than a
            // choice of scope, next to "Whole book" which plainly is one.
            CHAPTER -> "Current chapter"
        }
}

/**
 * What a progress bar shows, and what dragging it means.
 *
 * A value rather than three computations, because the same numbers have to
 * appear on the player, on the mini bar's hairline, on the lock screen and in
 * the car, and a bar that disagrees with its own times is worse than one that
 * is merely coarse. It is also the inverse: [bookProgressForFraction] turns a
 * drag back into a position, so the surface that drew the bar is the one that
 * says what a drag on it meant.
 *
 * Pure, so every case that matters — a book with no chapters, a chapter of
 * zero length, a duration that has not loaded yet — can be tested rather than
 * discovered in a car.
 */
class PlaybackProgress(
    scope: ProgressScope,
    bookProgress: Double,
    totalDuration: Double,
    chapterSpan: ChapterSpan?,
) {
    /** Whether the visible span is a chapter rather than the whole book. */
    val isChapterScoped: Boolean

    /** Where the visible span begins on the book clock, and how long it runs. */
    val spanStart: Double
    val spanDuration: Double
    val bookDuration: Double
    val bookProgress: Double

    init {
        val total = if (totalDuration.isFinite() && totalDuration > 0) totalDuration else 0.0
        this.bookProgress = if (bookProgress.isFinite()) bookProgress.asProgression ?: 0.0 else 0.0
        bookDuration = total

        // Falls back to the whole book whenever a chapter cannot be described:
        // a single-file audiobook, a read-along whose document has no
        // narration, a manifest still loading. Degrading to a coarse bar is
        // right; dividing by zero is not.
        if (scope == ProgressScope.CHAPTER && total > 0 && chapterSpan != null &&
            chapterSpan.duration > 0 && chapterSpan.start.isFinite() && chapterSpan.duration.isFinite()
        ) {
            isChapterScoped = true
            spanStart = maxOf(0.0, chapterSpan.start)
            spanDuration = minOf(chapterSpan.duration, total - maxOf(0.0, chapterSpan.start))
        } else {
            isChapterScoped = false
            spanStart = 0.0
            spanDuration = total
        }
    }

    /** Time into the visible span. */
    val elapsed: Double
        get() {
            if (!(spanDuration > 0)) return 0.0
            return minOf(maxOf(bookProgress * bookDuration - spanStart, 0.0), spanDuration)
        }

    val remaining: Double get() = maxOf(spanDuration - elapsed, 0.0)

    /** Where the thumb sits, 0…1 of the visible span. */
    val fraction: Double get() = if (spanDuration > 0) elapsed / spanDuration else 0.0

    /**
     * Time left in the whole book, whatever the bar is scoped to.
     *
     * Deliberately not [remaining], which is the span's. On a chapter-scoped
     * bar — the default — nothing on the player answers "how much of the book
     * is left", and that is the question someone deciding whether to start the
     * washing-up is actually asking.
     *
     * Here rather than in the view because the type is pure and tested, and
     * because the mini bar, the lock screen and the car would otherwise each
     * grow their own arithmetic and disagree.
     */
    val bookRemaining: Double get() = maxOf(bookDuration * (1 - bookProgress), 0.0)

    /**
     * 0…100, rounded. [bookProgress] is already clamped by the constructor, so
     * this needs no guard of its own.
     */
    val bookPercentComplete: Int get() = (bookProgress * 100).roundedHalfAwayFromZero().toInt()

    /** The book position a drag to [fraction] of this bar means. */
    fun bookProgressForFraction(fraction: Double): Double {
        if (!(bookDuration > 0)) return 0.0
        val clamped = if (fraction.isFinite()) fraction.asProgression ?: 0.0 else 0.0
        val time = spanStart + clamped * spanDuration
        return (time / bookDuration).asProgression ?: 0.0
    }

    /**
     * The book position a lock-screen scrub to [seconds] means.
     *
     * The system reports the drag in the same units as the duration it was
     * given, so this has to be the inverse of whatever [elapsed]/[spanDuration]
     * were published — otherwise a drag on a chapter-scoped bar lands somewhere
     * else entirely in the book.
     */
    fun bookProgressForSeconds(seconds: Double): Double {
        if (!(spanDuration > 0)) return 0.0
        return bookProgressForFraction(seconds / spanDuration)
    }

    override fun equals(other: Any?): Boolean =
        other is PlaybackProgress && other.isChapterScoped == isChapterScoped && other.spanStart == spanStart &&
            other.spanDuration == spanDuration && other.bookDuration == bookDuration &&
            other.bookProgress == bookProgress

    override fun hashCode(): Int =
        listOf(isChapterScoped, spanStart, spanDuration, bookDuration, bookProgress).hashCode()

    override fun toString(): String =
        "PlaybackProgress(isChapterScoped=$isChapterScoped, spanStart=$spanStart, spanDuration=$spanDuration, " +
            "bookDuration=$bookDuration, bookProgress=$bookProgress)"
}
