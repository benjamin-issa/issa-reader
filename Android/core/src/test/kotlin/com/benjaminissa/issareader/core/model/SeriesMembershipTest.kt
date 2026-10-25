package com.benjaminissa.issareader.core.model

import com.benjaminissa.issareader.core.bookJson
import com.benjaminissa.issareader.core.decodeBook
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Which number a book wears on a screen about one series, and which tags it
 * shows once. Ported from `SeriesMembershipTests.swift`.
 */
class SeriesMembershipTest {
    private fun book(
        series: List<Pair<String, Double?>> = emptyList(),
        tags: List<Pair<String, String>> = emptyList(),
    ): Book {
        val json = bookJson(uuid = "u", title = "A Book")
        json["tags"] = tags.map { (uuid, name) -> mapOf("uuid" to uuid, "name" to name) }
        json["series"] = series.map { (name, position) ->
            val row = mutableMapOf<String, Any?>("uuid" to name, "name" to name)
            if (position != null) row["position"] = position
            row
        }
        return decodeBook(json)
    }

    /** An omnibus listed first and numbered there still shows its place in the rail's series. */
    @Test
    fun omnibusShowsTheRailsNumber() {
        val omnibus = book(series = listOf("Omnibus" to 1.0, "Gothic Horror" to 2.0))
        assertEquals(2.0, omnibus.membership(inSeries = "Gothic Horror")?.position)
        // The badge's own pick would have said 1.
        assertEquals(1.0, omnibus.primarySeries?.position)
    }

    /** An unnumbered membership is found, and has no number to draw. */
    @Test
    fun unnumberedHasNoPosition() {
        val shelved = book(series = listOf("Gothic Horror" to null))
        assertNotNull(shelved.membership(inSeries = "Gothic Horror"))
        assertNull(shelved.membership(inSeries = "Gothic Horror")?.position)
    }

    /** A book outside the series has no membership in it. */
    @Test
    fun outsideTheSeries() {
        assertNull(book(series = listOf("Other" to 1.0)).membership(inSeries = "Gothic Horror"))
        assertNull(book().membership(inSeries = "Gothic Horror"))
    }

    /** A tag named twice is shown once, the first of it, in the server's order. */
    @Test
    fun distinctTags() {
        val tagged = book(
            tags = listOf("1" to "Gothic", "2" to "Horror", "3" to "Gothic", "2" to "Horror"),
        )
        assertEquals(listOf("Gothic", "Horror"), tagged.distinctTags.map { it.name })
        assertEquals(listOf("1", "2"), tagged.distinctTags.map { it.uuid })
    }
}
