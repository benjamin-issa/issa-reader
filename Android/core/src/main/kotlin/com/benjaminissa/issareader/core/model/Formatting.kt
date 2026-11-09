package com.benjaminissa.issareader.core.model

import com.benjaminissa.issareader.core.sync.SeriesGroup
import java.math.RoundingMode
import java.text.DecimalFormat
import java.text.DecimalFormatSymbols
import java.text.NumberFormat
import java.time.Instant
import java.time.ZoneOffset
import java.util.Locale
import kotlin.math.abs
import kotlin.math.pow

/**
 * A length of audio as a reader sees it: "2h 18m", "45m".
 *
 * One copy. There were three — the detail screen's, the widget snapshot's
 * and CarPlay's — and only CarPlay's guarded against a non-finite value, so a
 * server-supplied duration of NaN trapped on the book screen while the car
 * showed "0m".
 */
object DurationText {
    fun text(seconds: Double): String {
        // `wholeSeconds`, not `isFinite` plus a conversion. The guard was there
        // and was not enough: `1e300` is finite, and converting it traps.
        if (!(seconds > 0)) return "0m"
        val total = seconds.wholeSeconds ?: return "0m"
        val hours = total / 3600
        val minutes = (total % 3600) / 60
        return if (hours > 0) "${hours}h ${minutes}m" else "${minutes}m"
    }
}

/**
 * The year a book was published, as a reader sees it: "1994".
 *
 * Read in UTC. Both server generations store a bare year as that year's first
 * midnight in UTC, so read in the device's own zone a reader west of
 * Greenwich saw the year before. One copy, for the book page's Published row
 * and the More by page's caption: each had its own, and they had already
 * disagreed once.
 */
object PublishedYearText {
    fun text(date: Instant): String = date.atZone(ZoneOffset.UTC).year.toString()
}

/**
 * A byte count as a reader sees it: "146.2 MB".
 *
 * Foundation's `ByteCountFormatter` in its `.file` style, which the Swift
 * client prints: decimal units, whole kilobytes, one decimal for megabytes and
 * two above, trailing zeros dropped, "Zero KB" for nothing — so both clients
 * name a download's size the same way.
 */
object ByteCountText {
    private val units = listOf("KB" to 0, "MB" to 1, "GB" to 2, "TB" to 2, "PB" to 2, "EB" to 2)

    fun text(bytes: Long): String {
        if (bytes == 0L) return "Zero KB"
        if (abs(bytes) < 1000) return if (abs(bytes) == 1L) "$bytes byte" else "$bytes bytes"
        var value = bytes / 1000.0
        var index = 0
        while (true) {
            val (unit, digits) = units[index]
            val scale = 10.0.pow(digits)
            val rounded = Math.round(value * scale) / scale
            if (abs(rounded) < 1000 || index == units.lastIndex) return "${number(digits).format(rounded)} $unit"
            value /= 1000.0
            index += 1
        }
    }

    private fun number(fractionDigits: Int): NumberFormat =
        NumberFormat.getNumberInstance(Locale.getDefault()).apply {
            minimumFractionDigits = 0
            maximumFractionDigits = fractionDigits
        }
}

/**
 * Where a book sits in a series, as a reader sees it: "2", "Book 1.5",
 * "Gothic Horror · Book 2 of 3".
 *
 * One copy, because the same three words are wanted in four places at three
 * lengths — a badge on a cover has room for a numeral, a caption under it has
 * room for the series name, and the book screen has room to say how many
 * there are. Splitting them here keeps the phrasing identical wherever the
 * reader meets it.
 */
object SeriesText {
    /**
     * The position on its own, for a mark too small for a word.
     *
     * Formatted rather than interpolated. A position is a `Double` and a
     * novella legitimately sits at 1.5, so `"$position"` prints "2.0" for the
     * ordinary case and can print "1.5000001" for the fractional one.
     *
     * A fixed locale, not the reader's. "Book" and "of" around this numeral
     * are hard-coded English, so a device set to German would have produced
     * "Book 1,5 of 3" — half-translated — and a four-figure series would have
     * grown a grouping separator the rest of the app never shows.
     */
    fun ordinal(position: Double): String =
        DecimalFormat("0.##", DecimalFormatSymbols(Locale.US)).apply {
            roundingMode = RoundingMode.HALF_EVEN
            isGroupingUsed = false
        }.format(position)

    /** The position as a phrase: "Book 2", "Book 1.5". */
    fun position(position: Double): String = "Book ${ordinal(position)}"

    /**
     * The whole line: the series, where in it, and how long it is.
     *
     * "of 1" is never said: a series of one is a book, and the count only
     * adds anything once there is somewhere else to go.
     *
     * @param count how many books of the series the *library holds*, which is
     *   not how long the series is — the server numbers a book within its
     *   series and never says how many there are. So "of N" is said only when
     *   it can be true: own books 1 and 3 of five and the third is "Book 3",
     *   not "Book 3 of 2".
     */
    fun label(name: String, position: Double?, count: Int?): String {
        if (position == null) return name
        var text = "$name · ${position(position)}"
        if (count != null && count > 1 && count.toDouble() >= position) text += " of $count"
        return text
    }

    /**
     * The book screen's line for one of a book's series, counted from the
     * part of that series the library holds, if it holds more than the book.
     *
     * The count is the group's `statedCount`, not how many books it holds:
     * passing that number said "Book 2 of 2" beside a "Book 3" the library
     * also holds.
     */
    fun label(membership: SeriesMembership, group: SeriesGroup?): String =
        label(name = membership.name, position = membership.position, count = group?.statedCount)
}
