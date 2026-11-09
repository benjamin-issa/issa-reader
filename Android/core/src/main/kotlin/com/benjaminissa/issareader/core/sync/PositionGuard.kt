package com.benjaminissa.issareader.core.sync

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Why a position write happened.
 *
 * This is the only thing that separates a legitimate step backwards from a
 * destructive one. Readers move backwards constantly — a page, a chapter, a
 * bookmark, a search hit, the scrubber, starting a finished book again — so a
 * rule that refuses every smaller progression is not a safety net, it is a
 * second bug.
 *
 * What does hold is whether the reader named the **destination**. The word is
 * load-bearing: pressing play is the reader's doing, but *where playback
 * resumes* is the app's, and that is precisely the write that destroyed a place
 * in a part-read novel. A rule keyed on "the user initiated something" would
 * have classified that tap as intentional and let it through.
 */
@Serializable
enum class PositionOrigin {
    /**
     * The reader named the place: a page turn, a Contents entry, a bookmark, a
     * search hit, a tapped sentence, the scrubber, the skip controls. Any
     * distance, in any direction, is legitimate.
     */
    @SerialName("chosen") CHOSEN,

    /**
     * Somewhere a clock arrived at: the narration highlight moving on, the
     * audiobook's periodic writer, a chapter loaded because the audio crossed
     * into it, or a resume position the app resolved on the reader's behalf.
     * Forward is expected; a long step back is a bug.
     */
    @SerialName("derived") DERIVED,
}

/**
 * Refuses a position write that would move a reader backwards without their
 * having asked for it.
 *
 * Pure, with no clock and no I/O, so the rule can be tested exhaustively —
 * including the cases that must *not* be blocked, which matter more than the
 * one that must.
 *
 * Swift's is a value type with a `mutating` [decide]. This class mutates in
 * place too; where a caller needs a separate copy of one clock's state it
 * takes one with [copy]. Equal by state, as the Swift struct is `Hashable`.
 */
class PositionGuard(
    highWater: Double = 0.0,
    /**
     * Total narration in seconds, where the book has any. Used only to tighten
     * the tolerance on very long audiobooks.
     */
    val duration: Double? = null,
    awaitingChoice: Boolean = false,
) {
    /**
     * The furthest point reached since the reader last chose where to be.
     *
     * A high-water mark rather than the last value written: a wrong position
     * rarely arrives alone, and one small step back, then another, then another
     * walks a book out from under a "compare with the previous write" rule
     * while every individual step looks innocent.
     */
    var highWater: Double = minOf(maxOf(if (highWater.isFinite()) highWater else 0.0, 0.0), 1.0)
        private set

    /**
     * Whether this clock is held because the app could not work out, honestly,
     * where the listener was.
     *
     * A high-water mark alone cannot cover that case. Playback that starts at
     * the beginning because nothing could be resolved sits *below* the mark
     * only when there is a mark on this clock to sit below — and there is
     * none, because the stored position was on the other one. So the first
     * derived write from a resume-at-zero looked like ordinary forward
     * progress, took the mark with it, and replaced a part-read novel's
     * position with 0.0001.
     *
     * A held clock therefore refuses a derived write carrying *no*
     * progression too. Such a write makes no claim about where the reader is,
     * which is why the ordinary rule waves it through — but `recordPosition`
     * still replaces the stored locator with it, and the stored locator is
     * the thing being protected. Only the listener naming a place — a
     * [PositionOrigin.CHOSEN] write — releases the hold.
     */
    var awaitingChoice: Boolean = awaitingChoice
        private set

    sealed interface Decision {
        data object Allow : Decision
        data class Refuse(val held: Double, val candidate: Double) : Decision

        /**
         * Refused because this clock is held: the app does not know where the
         * listener was, and will not guess on their behalf.
         */
        data class AwaitChoice(val candidate: Double?) : Decision

        val isAllowed: Boolean get() = this == Allow
    }

    internal val tolerance: Double
        get() {
            val duration = duration
            if (duration == null || !(duration > 0)) return FRACTION_TOLERANCE
            return minOf(FRACTION_TOLERANCE, SECONDS_TOLERANCE / duration)
        }

    /**
     * The same clock with its mark cleared, for when the *other* clock has
     * news this one cannot express.
     *
     * Guards are kept one per book *per clock* — `uuid#text` and `uuid#audio`
     * — because a fraction of the text and a fraction of the audio are
     * answers to different questions: the unnarrated front matter of a book
     * spends text and no seconds, so no value on one corresponds to a value on
     * the other. Every seeding rule in the app model is same-clock-only for
     * that reason, and the gap it leaves is what happens when the listener
     * steers one of them.
     *
     * The drive: the reader reads to 0.60, so `#text` holds 0.60. In the car
     * they scrub, which is a place named — but named on `#audio`, where it
     * re-baselines that clock and nothing else. When the drive ends the reader
     * is handed the book back at around 0.30 of the text, and that write is
     * measured against a 0.60 the listener invalidated hours ago. It is
     * refused; the reader model's `if accepted, let anchor` then drops the
     * anchor with it, and the whole drive persists nowhere.
     *
     * Cleared, then — not lowered, and not dropped. Lowered is undefined: there
     * is no arithmetic from a fraction of the audio to a fraction of the text,
     * and that impossibility is the reason the keys are split in the first
     * place. Dropped would be worse than it looks, because `admitPosition`
     * re-seeds a missing guard from `book.position` — which is exactly where
     * the stale mark came from, so the next write on the suspension inside
     * `writePosition` would resurrect the very mark being invalidated.
     *
     * What is kept is everything that is not a claim about the reader:
     * [duration] is a fact about the book, and [awaitingChoice] is a fact
     * about what this app was able to work out. The hold in particular
     * travels through untouched. The 2026-09-09 loss — a car starting at zero
     * and writing 0.0001 over a part-read novel — is prevented by the hold and
     * not by the mark (see [awaitingChoice]), so clearing a mark can never be
     * the thing that lets that write back in.
     */
    fun forgettingItsMark(): PositionGuard = PositionGuard(0.0, duration, awaitingChoice)

    /** A separate guard holding the same state. */
    fun copy(): PositionGuard = PositionGuard(highWater, duration, awaitingChoice)

    /** Whether this write may proceed, updating the mark if it may. */
    fun decide(candidate: Double?, origin: PositionOrigin): Decision {
        // Before the null check on purpose: a held clock refuses a derived
        // write that carries no progression as well, because the write still
        // replaces the stored locator. See `awaitingChoice`.
        if (origin == PositionOrigin.DERIVED && awaitingChoice) return Decision.AwaitChoice(candidate)
        // No progression is not a claim about where the reader is.
        if (candidate == null) return Decision.Allow
        if (!(candidate.isFinite() && candidate >= 0 && candidate <= 1)) {
            return Decision.Refuse(held = highWater, candidate = candidate)
        }
        if (origin == PositionOrigin.CHOSEN) {
            // *To* the candidate, not the larger of the two: someone who has
            // just restarted a finished book must be able to read its first
            // chapter without every page being measured against the ending.
            highWater = candidate
            // And a place named is exactly what a held clock was waiting for.
            awaitingChoice = false
            return Decision.Allow
        }
        if (!(candidate >= highWater - tolerance)) return Decision.Refuse(held = highWater, candidate = candidate)
        highWater = maxOf(highWater, candidate)
        return Decision.Allow
    }

    override fun equals(other: Any?): Boolean =
        other is PositionGuard && other.highWater == highWater && other.duration == duration &&
            other.awaitingChoice == awaitingChoice

    override fun hashCode(): Int = (highWater.hashCode() * 31 + (duration?.hashCode() ?: 0)) * 31 + awaitingChoice.hashCode()

    override fun toString(): String =
        "PositionGuard(highWater=$highWater, duration=$duration, awaitingChoice=$awaitingChoice)"

    companion object {
        /**
         * The largest step backwards a clock may take on its own: five per cent
         * of the book, or five minutes of narration, whichever is smaller.
         *
         * Both sit far above anything legitimate — a thirty-second skip back, a
         * player resuming a few seconds early after an interruption, and the
         * highlight re-anchoring at a chapter boundary are all much smaller —
         * and far below a regression that destroys a reading place, which by
         * definition is most of the book.
         */
        internal const val FRACTION_TOLERANCE = 0.05

        /**
         * Five per cent of a forty-hour audiobook is two hours of undetected
         * slack, so long books are held to a tighter absolute bound.
         */
        internal const val SECONDS_TOLERANCE = 300.0
    }
}
