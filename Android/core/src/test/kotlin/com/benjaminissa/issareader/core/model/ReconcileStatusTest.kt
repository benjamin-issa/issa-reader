package com.benjaminissa.issareader.core.model

import com.benjaminissa.issareader.core.bookJson
import com.benjaminissa.issareader.core.decodeBook
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Keeping an unsent status through a refresh. Ported from
 * `ReconcileStatusTests.swift`.
 *
 * The app decides whether a status is still unsent; `reconciled(with,
 * keepingStatus)` is the one place that answer is applied. It has to act
 * before the position rule's early return: a book with no position of its own
 * can still carry a status the reader set from its detail screen.
 */
class ReconcileStatusTest {
    private fun book(status: String?, progress: Double? = null, timestamp: Double = 0.0): Book {
        val json = bookJson(uuid = "u", title = "A Book")
        json["status"] = status?.let { mapOf("uuid" to "s-$it", "name" to it) }
        if (progress != null) {
            json["position"] = mapOf(
                "locator" to mapOf("href" to "a", "type" to "t", "locations" to mapOf("totalProgression" to progress)),
                "timestamp" to timestamp,
            )
        }
        return decodeBook(json)
    }

    /** A kept status survives a refresh that says otherwise, beside a newer position. */
    @Test
    fun keptWithAPosition() {
        val mine = book(status = Status.readName, progress = 0.62, timestamp = 200.0)
        val fresh = book(status = null, progress = 0.31, timestamp = 100.0)
        val merged = mine.reconciled(with = fresh, keepingStatus = true)
        assertEquals(Status.readName, merged.status?.name)
        assertEquals("the position rule still applies", 0.62, merged.progress)
    }

    /**
     * A kept status survives on a book with no position of its own: a book
     * never opened here, filed from its detail screen.
     */
    @Test
    fun keptWithoutAPosition() {
        val mine = book(status = Status.readName)
        val fresh = book(status = null, progress = 0.4, timestamp = 100.0)
        val merged = mine.reconciled(with = fresh, keepingStatus = true)
        assertEquals("the status was dropped with no position to keep", Status.readName, merged.status?.name)
        assertEquals("the server's position is taken as given", 0.4, merged.progress)
    }

    /** Without it, the server's status is taken, position or not. */
    @Test
    fun serverStatusByDefault() {
        val fresh = book(status = Status.readingName, progress = 0.31, timestamp = 100.0)
        for (mine in listOf(book(status = Status.readName, progress = 0.62, timestamp = 200.0), book(status = Status.readName))) {
            assertEquals(Status.readingName, mine.reconciled(with = fresh).status?.name)
            assertEquals(Status.readingName, mine.reconciled(with = fresh, keepingStatus = false).status?.name)
        }
    }
}
