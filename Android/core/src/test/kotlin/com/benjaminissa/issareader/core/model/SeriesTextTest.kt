package com.benjaminissa.issareader.core.model

import com.benjaminissa.issareader.core.bookJson
import com.benjaminissa.issareader.core.decodeBook
import com.benjaminissa.issareader.core.sync.SeriesGroup
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * How a series is worded, and which membership a screen with one line shows.
 * Ported from `SeriesTextTests.swift`.
 *
 * The phrasing is pinned here because three screens draw it — the badge on a
 * cover of the series screen, that screen's caption, and the book screen's
 * hero — and the point of one formatter is that they cannot drift apart.
 */
class SeriesTextTest {
    fun book(title: String, series: List<Pair<String, Double?>>): Book {
        val json = bookJson(uuid = title, title = title)
        json["series"] = series.map { (name, position) ->
            val row = mutableMapOf<String, Any?>("uuid" to name, "name" to name)
            if (position != null) row["position"] = position
            row
        }
        return decodeBook(json)
    }

    /** A whole position loses its decimal point. */
    @Test
    fun wholePosition() {
        assertEquals("2", SeriesText.ordinal(2.0))
        assertEquals("Book 2", SeriesText.position(2.0))
    }

    /** A novella keeps its fraction and nothing else: not "2.0", not "1.5000001". */
    @Test
    fun fractionalPosition() {
        assertEquals("1.5", SeriesText.ordinal(1.5))
        assertEquals("Book 1.5", SeriesText.position(1.5))
    }

    /** A label names the series, the book and how many there are. */
    @Test
    fun fullLabel() {
        assertEquals("Gothic Horror · Book 2 of 3", SeriesText.label(name = "Gothic Horror", position = 2.0, count = 3))
        assertEquals("Gothic Horror · Book 1.5 of 3", SeriesText.label(name = "Gothic Horror", position = 1.5, count = 3))
    }

    /** A series with no position is just its name: there is no "book 1" to name. */
    @Test
    fun unpositioned() {
        assertEquals("Gothic Horror", SeriesText.label(name = "Gothic Horror", position = null, count = 4))
    }

    /** The count is said only when there is more than one book: "of 1" says a series of one, which is a book. */
    @Test
    fun countOnlyWhenItMeansSomething() {
        assertEquals("Solo · Book 1", SeriesText.label(name = "Solo", position = 1.0, count = null))
        assertEquals("Solo · Book 1", SeriesText.label(name = "Solo", position = 1.0, count = 1))
        assertEquals("Pair · Book 1 of 2", SeriesText.label(name = "Pair", position = 1.0, count = 2))
    }

    /**
     * A book in two series shows the numbered one where there is room for one,
     * while the book screen still names both.
     */
    @Test
    fun twoSeries() {
        val omnibus = book("Collected", series = listOf("Publisher's Library" to null, "Gothic Horror" to 3.0))
        assertEquals("Gothic Horror", omnibus.primarySeries?.name)

        val labels = omnibus.series.map { SeriesText.label(name = it.name, position = it.position, count = null) }
        assertEquals(listOf("Publisher's Library", "Gothic Horror · Book 3"), labels)
    }

    /** An unnumbered book still has a series to name. */
    @Test
    fun noPositionAnywhere() {
        val book = book("Alone", series = listOf("Gothic Horror" to null))
        assertEquals("Gothic Horror", book.primarySeries?.name)
        assertNull(book.primarySeries?.position)
    }

    /** A book in no series has none to name. */
    @Test
    fun noSeries() {
        assertNull(book("Alone", series = emptyList()).primarySeries)
    }

    /** A series never claims more books than it can hold. */
    @Test
    fun theCountMustContainThePosition() {
        // `count` is what the library holds, not how long the series is: own
        // books one and three of five and the third used to read "Book 3 of 2".
        assertEquals("Gothic Horror · Book 3", SeriesText.label(name = "Gothic Horror", position = 3.0, count = 2))
        assertEquals("Gothic Horror · Book 4", SeriesText.label(name = "Gothic Horror", position = 4.0, count = 3))
        // The honest cases still say it.
        assertEquals("Gothic Horror · Book 2 of 3", SeriesText.label(name = "Gothic Horror", position = 2.0, count = 3))
        assertEquals("Gothic Horror · Book 3 of 3", SeriesText.label(name = "Gothic Horror", position = 3.0, count = 3))
        assertEquals("Gothic Horror · Book 1.5 of 2", SeriesText.label(name = "Gothic Horror", position = 1.5, count = 2))
    }

    /** A series the library holds part of, books at these positions. */
    private fun held(name: String, positions: List<Double?>): SeriesGroup =
        SeriesGroup(name = name, books = positions.mapIndexed { index, position -> book("$name $index", series = listOf(name to position)) })

    /** A series states its length only when the books held are exactly the first N. */
    @Test
    fun statedCountNeedsTheWholeRun() {
        assertEquals(2, held("Gothic", listOf(1.0, 2.0)).statedCount)
        assertEquals("in any order", 3, held("Gothic", listOf(3.0, 1.0, 2.0)).statedCount)
        assertNull("no book 1", held("Gothic", listOf(2.0, 3.0)).statedCount)
        assertNull("a gap", held("Gothic", listOf(1.0, 2.0, 5.0)).statedCount)
        assertNull("a novella is not a numbered book", held("Gothic", listOf(1.0, 1.5, 2.0)).statedCount)
        assertNull("two at one place", held("Gothic", listOf(1.0, 1.0)).statedCount)
        assertNull("an unnumbered book", held("Gothic", listOf(1.0, null)).statedCount)
    }

    /** The book screen says "of N" only beside the run it holds from one. */
    @Test
    fun bookScreenLabel() {
        val cases = listOf(
            listOf(2.0, 3.0) to emptyList(),
            listOf(1.0, 2.0) to listOf("Gothic Horror · Book 1 of 2", "Gothic Horror · Book 2 of 2"),
            listOf(1.0, 2.0, 5.0) to emptyList<String>(),
        )
        for ((positions, wholeRun) in cases) {
            val group = held("Gothic Horror", positions)
            val labels = group.books.map { SeriesText.label(it.series[0], group) }
            if (wholeRun.isEmpty()) {
                assertTrue("$labels", labels.all { !it.contains(" of ") })
                assertEquals("Gothic Horror · Book ${SeriesText.ordinal(positions[0])}", labels.first())
            } else {
                assertEquals(wholeRun, labels)
            }
        }
    }

    /** A book with no group is labelled without a count. */
    @Test
    fun noGroup() {
        val alone = book("Alone", series = listOf("Gothic Horror" to 2.0))
        assertEquals("Gothic Horror · Book 2", SeriesText.label(alone.series[0], null))
    }

    /** The numeral does not follow the device's locale. */
    @Test
    fun theNumeralIsFixed() {
        // The words around it are English; a comma decimal among them would be
        // half a translation.
        assertEquals("1.5", SeriesText.ordinal(1.5))
        assertEquals("1200", SeriesText.ordinal(1200.0))
    }
}
