package com.benjaminissa.issareader.core.model

import com.benjaminissa.issareader.core.bookJson
import com.benjaminissa.issareader.core.decodeBook
import com.benjaminissa.issareader.core.instantOfEpochSeconds
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Adopting a reading position: keeping the library's copy of it in step with
 * the reader. Ported from `StoredPositionTests.swift`.
 *
 * The Continue card, the library row and the book screen all read
 * `book.progress`, and it used to move only when the book was fetched again —
 * so it could sit a whole reading session behind. The app writes the locator
 * itself, so it can simply adopt it; these are the rules for doing that
 * safely. Swift adopts in place; the Kotlin book is a value, so each test
 * keeps the book `adopting` returns.
 */
class StoredPositionTest {
    fun book(progress: Double? = null, timestamp: Double = 0.0): Book {
        val json = bookJson(uuid = "u", title = "A Book")
        if (progress != null) {
            json["position"] = mapOf(
                "uuid" to "p",
                "locator" to mapOf("href" to "a", "type" to "t", "locations" to mapOf("totalProgression" to progress)),
                "timestamp" to timestamp,
            )
        }
        return decodeBook(json)
    }

    fun locator(progression: Double): ReadiumLocator = ReadiumLocator(
        href = "a", type = "t",
        locations = ReadiumLocator.Locations(progression = progression, totalProgression = progression),
    )

    /** A book that has never been opened takes the position. */
    @Test
    fun adoptsFirstPosition() {
        val subject = book().adopting(position = locator(0.22), timestamp = 100.0)
        assertEquals(0.22, subject.progress)
    }

    /** Reading on moves the position forward. */
    @Test
    fun adoptsNewerPosition() {
        val subject = book(progress = 0.13, timestamp = 100.0).adopting(position = locator(0.22), timestamp = 200.0)
        assertEquals(0.22, subject.progress)
    }

    /**
     * A save that arrives out of order does not move the reader back. The
     * mutation queue drains asynchronously, so an earlier page can be written
     * after a later one.
     */
    @Test
    fun refusesOlderPosition() {
        val subject = book(progress = 0.22, timestamp = 200.0).adopting(position = locator(0.13), timestamp = 100.0)
        assertEquals("an older write moved the position backwards", 0.22, subject.progress)
    }

    /** An equal timestamp adopts the new locator, which matches how the server resolves the tie. */
    @Test
    fun adoptsAtEqualTimestamp() {
        val subject = book(progress = 0.22, timestamp = 200.0).adopting(position = locator(0.30), timestamp = 200.0)
        assertEquals(0.30, subject.progress)
    }

    /** Adopting keeps the server's identity for the row. */
    @Test
    fun keepsPositionUuid() {
        val subject = book(progress = 0.13, timestamp = 100.0).adopting(position = locator(0.22), timestamp = 200.0)
        assertEquals("a new uuid would create a second row on the server", "p", subject.position?.uuid)
    }

    // When it was written, and in whose units

    /**
     * A position's instant and an anchor's are a thousandfold apart until they
     * are not. `StoredPosition.timestamp` is epoch **milliseconds** and
     * `AudioAnchor.writtenAt` is epoch **seconds**: the raw doubles disagree,
     * the instants agree.
     */
    @Test
    fun aPositionsInstantAndAnAnchorsAgreeOnlyAsDates() {
        // One moment, written down by both writers in the units each uses.
        val seconds = 1_757_000_000.0
        val position = book(progress = 0.7, timestamp = seconds * 1000).position!!
        val anchor = AudioAnchor(audioHref = "ch04.mp3", offset = 12.0, writtenAt = seconds)

        assertNotEquals("the two fields are the same instant and nowhere near the same number", position.timestamp, anchor.writtenAt)
        assertEquals(1000.0, position.timestamp / anchor.writtenAt, 0.0)
        assertEquals(instantOfEpochSeconds(anchor.writtenAt), position.writtenAt)

        // And the comparison the ladder actually makes. Raw, the anchor loses
        // to every position ever stored; as instants, a second later wins.
        assertTrue("which is why the raw compare is a trap", anchor.writtenAt < position.timestamp)
        assertFalse("written together, the anchor does not win", anchor.isNewerThan(position.writtenAt))
        val later = AudioAnchor(audioHref = "ch04.mp3", offset = 12.0, writtenAt = seconds + 1)
        assertTrue(later.isNewerThan(position.writtenAt))
    }

    // Reconciling a catalogue refresh

    /** A catalogue refresh that predates our own write does not undo it. */
    @Test
    fun refreshDoesNotUndoOurWrite() {
        val mine = book(progress = 0.62, timestamp = 200.0)
        val fresh = book(progress = 0.31, timestamp = 100.0)
        assertEquals(0.62, mine.reconciled(with = fresh).progress)
    }

    /** A refresh that is ahead of us wins, because another device moved. */
    @Test
    fun refreshFromAnotherDeviceWins() {
        val mine = book(progress = 0.62, timestamp = 200.0)
        val fresh = book(progress = 0.71, timestamp = 300.0)
        assertEquals(0.71, mine.reconciled(with = fresh).progress)
    }

    /** A refresh brings everything about the book except where we are. */
    @Test
    fun refreshBringsEverythingElse() {
        val mine = book(progress = 0.62, timestamp = 200.0).copy(title = "Stale Title")
        val fresh = book(progress = 0.31, timestamp = 100.0).copy(title = "The Real Title")
        val merged = mine.reconciled(with = fresh)
        assertEquals("the catalogue is newer for everything else", "The Real Title", merged.title)
        assertEquals("except our own place in it", 0.62, merged.progress)
    }

    /** A server that has never heard of our position does not clear it. */
    @Test
    fun refreshWithNoPositionKeepsOurs() {
        val mine = book(progress = 0.62, timestamp = 200.0)
        assertEquals(0.62, mine.reconciled(with = book()).progress)
    }

    /** A book we have never opened takes whatever the refresh says. */
    @Test
    fun refreshWinsWhenWeHaveNothing() {
        assertEquals(0.4, book().reconciled(with = book(progress = 0.4, timestamp = 100.0)).progress)
    }

    /** The library agrees with the reader once the position is adopted. */
    @Test
    fun agreesWithTheReader() {
        val subject = book(progress = 0.13, timestamp = 100.0).adopting(position = locator(0.137), timestamp = 200.0)
        assertEquals("14%", ReadingProgress.percentText(subject.progress ?: 0.0))
    }
}
