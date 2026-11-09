package com.benjaminissa.issareader.core.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** A progression is finite or it is not a progression. Ported from `UnitIntervalTests.swift`. */
class UnitIntervalTest {
    /** The hazard, before the guard: Kotlin's own clamp passes NaN through. */
    @Test
    fun kotlinsOwnClampDoesNotFilterNaN() {
        assert(Double.NaN.coerceIn(0.0, 1.0).isNaN())
    }

    @Test
    fun aNonFiniteValueHasNoHonestProgression() {
        for (value in listOf(Double.NaN, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY)) {
            assertNull("0 would be a claim about where the reader is", value.asProgression)
            assertEquals(0.0, value.clampedToUnitInterval(), 0.0)
        }
    }

    @Test
    fun everythingElseClamps() {
        for ((value, expected) in listOf(-1.0 to 0.0, 0.0 to 0.0, 0.5 to 0.5, 1.0 to 1.0, 2.0 to 1.0, -0.0001 to 0.0)) {
            assertEquals(expected, value.asProgression!!, 0.0)
        }
    }

    @Test
    fun wholeSecondsRoundHalfAwayFromZeroAndRefuseTheAbsurd() {
        assertEquals(3L, 2.5.wholeSeconds)
        assertEquals(-3L, (-2.5).wholeSeconds)
        assertEquals(2L, 2.49.wholeSeconds)
        assertNull(Double.NaN.wholeSeconds)
        assertNull(Double.POSITIVE_INFINITY.wholeSeconds)
        assertNull(1e300.wholeSeconds)
        assertNull(9.223372036854775807E18.wholeSeconds)
    }
}
