package com.benjaminissa.issareader.core.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Refusing a position write that would destroy a reading place. Ported from
 * `PositionGuardTests.swift`.
 *
 * The reproduction below is one test. The dozen after it are the ones that
 * matter: a guard that blocks a reader from jumping back to chapter one is a
 * worse bug than the one it prevents, so most of this file exists to prove
 * that legitimate backwards movement is untouched.
 */
class PositionGuardTest {
    private val chosen = PositionOrigin.CHOSEN
    private val derived = PositionOrigin.DERIVED

    // The report, reproduced

    /** Narration that starts at the beginning does not destroy a reading place. */
    @Test
    fun refusesTheReportedRegression() {
        val guardState = PositionGuard(highWater = 0.31)
        assertEquals(PositionGuard.Decision.Refuse(held = 0.31, candidate = 0.0004), guardState.decide(0.0004, derived))
        // The write repeats every couple of seconds; every one must be refused.
        assertFalse(guardState.decide(0.0009, derived).isAllowed)
        assertFalse(guardState.decide(0.0016, derived).isAllowed)
        assertEquals("a refused write must not move the mark", 0.31, guardState.highWater, 0.0)
    }

    // Movement the reader asked for, which must never be blocked

    /** A reader who jumps back to chapter one from the contents is not stopped. */
    @Test
    fun allowsContentsJump() {
        assertTrue(PositionGuard(highWater = 0.62).decide(0.01, chosen).isAllowed)
    }

    /** A bookmark twenty chapters back is not stopped. */
    @Test
    fun allowsBookmarkJump() {
        assertTrue(PositionGuard(highWater = 0.62).decide(0.18, chosen).isAllowed)
    }

    /** A search hit behind the reader is not stopped. */
    @Test
    fun allowsSearchHitBehind() {
        assertTrue(PositionGuard(highWater = 0.44).decide(0.02, chosen).isAllowed)
    }

    /** Scrubbing backwards in the player is not stopped. */
    @Test
    fun allowsScrubBack() {
        assertTrue(PositionGuard(highWater = 0.62).decide(0.30, chosen).isAllowed)
    }

    /** Restarting a finished book is not stopped. */
    @Test
    fun allowsRestart() {
        assertTrue(PositionGuard(highWater = 0.99).decide(0.0, chosen).isAllowed)
    }

    /**
     * And reading on from a restart is not stopped either. This fails against
     * a `highWater = max(highWater, candidate)` implementation on the chosen
     * branch, which is the obvious wrong way to write it.
     */
    @Test
    fun allowsReadingOnAfterRestart() {
        val guardState = PositionGuard(highWater = 0.99)
        assertTrue(guardState.decide(0.0, chosen).isAllowed)
        assertEquals("choosing a place re-baselines to it", 0.0, guardState.highWater, 0.0)
        assertTrue(
            "narration must be able to carry on from where the reader restarted",
            guardState.decide(0.004, derived).isAllowed,
        )
    }

    // Small movements, which are ordinary reading

    /** Flipping back a page is not stopped even when it is unattended. */
    @Test
    fun allowsPageFlipBack() {
        assertTrue(PositionGuard(highWater = 0.400).decide(0.399, derived).isAllowed)
    }

    /** A thirty-second skip back is allowed even when it is mislabelled. */
    @Test
    fun allowsMislabelledSkipBack() {
        assertTrue(PositionGuard(highWater = 0.62, duration = 36_000.0).decide(0.6192, derived).isAllowed)
    }

    /** The highlight re-anchoring at a chapter boundary is not stopped. */
    @Test
    fun allowsChapterBoundaryReanchor() {
        // One chapter of an eighty-chapter novel is a little over 1%.
        assertTrue(PositionGuard(highWater = 0.500).decide(0.4875, derived).isAllowed)
    }

    /** A forward write is never refused. */
    @Test
    fun allowsForwardWrites() {
        for (candidate in listOf(0.001, 0.1, 0.5, 1.0)) {
            for (origin in PositionOrigin.entries) {
                assertTrue("$candidate $origin", PositionGuard(highWater = 0.0).decide(candidate, origin).isAllowed)
            }
        }
    }

    /** A book barely started is not guarded. */
    @Test
    fun allowsEarlyBook() {
        assertTrue(PositionGuard(highWater = 0.01).decide(0.0, derived).isAllowed)
    }

    // The state machine

    /**
     * A run of small steps back cannot walk the position out of the book: the
     * discriminator between a high-water mark and a "compare with the last
     * write" rule.
     */
    @Test
    fun refusesCreepingRegression() {
        val guardState = PositionGuard(highWater = 0.62)
        var candidate = 0.62
        var allowed = 0
        repeat(40) {
            candidate -= 0.004
            if (guardState.decide(candidate, derived).isAllowed) allowed += 1
        }
        assertTrue("the mark must not follow the writes downwards", allowed < 20)
        assertEquals(0.62, guardState.highWater, 0.0)
    }

    /** The high point is what a write is measured against, not the last value. */
    @Test
    fun measuresAgainstHighWater() {
        val guardState = PositionGuard(highWater = 0.0)
        assertTrue(guardState.decide(0.80, derived).isAllowed)
        assertTrue(guardState.decide(0.79, derived).isAllowed)
        assertFalse(guardState.decide(0.10, derived).isAllowed)
    }

    /** A non-finite or out-of-range progression is refused whatever its origin. */
    @Test
    fun refusesNonsense() {
        for (candidate in listOf(Double.NaN, Double.POSITIVE_INFINITY, -0.5, 1.5)) {
            for (origin in PositionOrigin.entries) {
                assertFalse("$candidate $origin", PositionGuard(highWater = 0.5).decide(candidate, origin).isAllowed)
            }
        }
    }

    /** A write carrying no progression is not a claim about position. */
    @Test
    fun allowsNilProgression() {
        val guardState = PositionGuard(highWater = 0.5)
        assertTrue(guardState.decide(null, derived).isAllowed)
        assertEquals(0.5, guardState.highWater, 0.0)
    }

    // Holding a clock the app could not resume honestly

    /** A held clock refuses every derived write until the listener steers. */
    @Test
    fun aHeldGuardRefusesEveryDerivedWriteUntilTheListenerSteers() {
        val guardState = PositionGuard(highWater = 0.0, duration = 36_000.0, awaitingChoice = true)
        assertEquals(PositionGuard.Decision.AwaitChoice(candidate = 0.0001), guardState.decide(0.0001, derived))
        // Not just the small ones: nothing a clock arrives at is trustworthy
        // while the app cannot say where the listener was.
        assertFalse(guardState.decide(0.4, derived).isAllowed)
        assertEquals("a held clock's mark must not move", 0.0, guardState.highWater, 0.0)
    }

    /** A chosen write releases the hold and re-baselines. */
    @Test
    fun aChosenWriteReleasesTheHoldAndRebaselines() {
        val guardState = PositionGuard(highWater = 0.0, duration = 36_000.0, awaitingChoice = true)
        assertTrue(guardState.decide(0.45, chosen).isAllowed)
        assertEquals(false, guardState.awaitingChoice)
        assertTrue("listening on must be recordable", guardState.decide(0.46, derived).isAllowed)
        assertEquals(
            "and the ordinary rule applies again once the hold is gone",
            PositionGuard.Decision.Refuse(held = 0.46, candidate = 0.30),
            guardState.decide(0.30, derived),
        )
    }

    /** A held clock refuses a derived write with no progression. */
    @Test
    fun aHeldGuardRefusesADerivedWriteWithNoProgression() {
        val guardState = PositionGuard(highWater = 0.31, duration = 36_000.0, awaitingChoice = true)
        assertEquals(PositionGuard.Decision.AwaitChoice(candidate = null), guardState.decide(null, derived))
        assertTrue("a chosen write is the listener acting, and is never held", guardState.decide(null, chosen).isAllowed)
    }

    /** A fresh guard still admits a derived write from zero. */
    @Test
    fun aFreshGuardStillAdmitsADerivedWriteFromZero() {
        assertTrue(PositionGuard(highWater = 0.0).decide(0.0001, derived).isAllowed)
    }

    // News arriving from the other clock

    /** A clock that forgets its mark keeps the hold it was under. */
    @Test
    fun forgettingAMarkKeepsTheHold() {
        val forgotten = PositionGuard(highWater = 0.60, duration = 36_000.0, awaitingChoice = true).forgettingItsMark()
        assertEquals(0.0, forgotten.highWater, 0.0)
        assertEquals("how long the book runs is not a claim about the reader", 36_000.0, forgotten.duration)
        assertEquals(
            "a cleared mark must not become a released hold",
            PositionGuard.Decision.AwaitChoice(candidate = 0.0001),
            forgotten.decide(0.0001, derived),
        )
    }

    /** A clock that forgot its mark admits the write carrying the move, then guards again. */
    @Test
    fun forgettingAMarkAdmitsTheMoveThenGuardsAgain() {
        val forgotten = PositionGuard(highWater = 0.60).forgettingItsMark()
        assertTrue("the place the drive left the reader at has to be able to land", forgotten.decide(0.30, derived).isAllowed)
        assertEquals("and it becomes the new mark", 0.30, forgotten.highWater, 0.0)
        assertEquals(
            "after which a derived write back to chapter one is a regression again",
            PositionGuard.Decision.Refuse(held = 0.30, candidate = 0.02),
            forgotten.decide(0.02, derived),
        )
    }

    // The seconds arm

    /** Five minutes of a forty-hour audiobook is the whole tolerance. */
    @Test
    fun tightensToleranceOnLongBooks() {
        val guardState = PositionGuard(highWater = 0.5, duration = 144_000.0)
        // 0.002 of the book is ~4.8 minutes: inside.
        assertTrue(guardState.decide(0.498, derived).isAllowed)
        // 2% is nearly fifty minutes: far outside, though it would pass the
        // 5% fraction rule on its own.
        val other = PositionGuard(highWater = 0.5, duration = 144_000.0)
        assertFalse(other.decide(0.48, derived).isAllowed)
    }

    /** A short audiobook keeps the five per cent floor. */
    @Test
    fun keepsFractionFloorOnShortBooks() {
        val guardState = PositionGuard(highWater = 0.5, duration = 3600.0)
        assertTrue(guardState.decide(0.46, derived).isAllowed)
        assertFalse(guardState.decide(0.40, derived).isAllowed)
    }

    /** A book with no narration falls back to the fraction rule. */
    @Test
    fun noDurationUsesFraction() {
        val guardState = PositionGuard(highWater = 0.5, duration = null)
        assertEquals(PositionGuard.FRACTION_TOLERANCE, guardState.tolerance, 0.0)
    }
}
