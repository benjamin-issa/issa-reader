package com.benjaminissa.issareader.core.model

import kotlin.math.floor

/**
 * This many seconds as a whole number, or `null` when there is no honest
 * answer: a NaN, an infinity, or a magnitude no clock can show.
 *
 * Rounds half away from zero, as Swift's `rounded()` does, so both clients
 * print the same clock for the same duration. Every duration this is asked
 * about comes from a server response or an audio file's own metadata, so
 * neither a NaN nor an absurd magnitude is hypothetical.
 */
val Double.wholeSeconds: Long?
    get() {
        if (!isFinite()) return null
        val rounded = if (this >= 0) floor(this + 0.5) else -floor(-this + 0.5)
        // Long's exact range as doubles: [-2^63, 2^63).
        return if (rounded >= -9.223372036854775807E18 && rounded < 9.223372036854775807E18) rounded.toLong() else null
    }
