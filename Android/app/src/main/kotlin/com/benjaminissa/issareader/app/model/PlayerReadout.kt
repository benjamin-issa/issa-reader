package com.benjaminissa.issareader.app.model

import com.benjaminissa.issareader.core.model.DurationText
import com.benjaminissa.issareader.core.model.wholeSeconds
import java.util.Locale

/**
 * How the player says where it is and how much of a book is left: the line
 * under the scrubber (`4h 12m left in book · 42%`) and the clock above it.
 * Swift's `PlayerView` statics, here so the player screen and the media
 * session read the same words.
 */
object PlayerReadout {
    /**
     * A length, in units rather than as a clock: a colon-separated figure
     * reads as a position in the book rather than an amount of it left.
     * Rounded to the nearest minute, and "0m" for anything that is not a
     * sensible length — `1e300` included, which is finite.
     */
    fun durationText(seconds: Double): String {
        if (!(seconds > 0)) return "0m"
        val whole = seconds.wholeSeconds ?: return "0m"
        return DurationText.text(minutesRounding(whole) * 60.0)
    }

    /** The same length for TalkBack, which must not be handed `4h 12m`. */
    fun spokenDuration(seconds: Double): String {
        if (!(seconds > 0)) return "no time"
        val whole = seconds.wholeSeconds ?: return "no time"
        val minutes = minutesRounding(whole)
        val hours = minutes / 60
        val mins = minutes % 60
        val hourPart = if (hours == 1L) "1 hour" else "$hours hours"
        val minutePart = if (mins == 1L) "1 minute" else "$mins minutes"
        if (hours == 0L) return minutePart
        return if (mins == 0L) hourPart else "$hourPart $minutePart"
    }

    /**
     * A position on the clock, under the scrubber: `4:12:00` or `47:31`, the
     * hour dropped under one. "0:00" for a nonsense position rather than a
     * crash as the player draws.
     */
    fun timeText(seconds: Double): String {
        if (!(seconds > 0)) return "0:00"
        val total = seconds.wholeSeconds ?: return "0:00"
        val hours = total / 3600
        val minutes = (total % 3600) / 60
        val secs = total % 60
        return if (hours > 0) {
            String.format(Locale.ROOT, "%d:%02d:%02d", hours, minutes, secs)
        } else {
            String.format(Locale.ROOT, "%d:%02d", minutes, secs)
        }
    }

    /** Whole seconds as whole minutes, rounded rather than floored: fifty seconds left is not "0m". */
    private fun minutesRounding(whole: Long): Long = whole / 60 + if (whole % 60 >= 30) 1 else 0
}
