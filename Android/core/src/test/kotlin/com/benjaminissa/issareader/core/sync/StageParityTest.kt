package com.benjaminissa.issareader.core.sync

import com.benjaminissa.issareader.core.bookJson
import com.benjaminissa.issareader.core.decodeBook
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.ServerGeneration
import com.benjaminissa.issareader.core.model.Status
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The shelf agrees with the status a position files. Ported from
 * `StageParityTests.swift`.
 *
 * A book with no status is shelved by `LibraryArrangement.stage(book)`, and
 * the first position this device writes for it files it through
 * `StatusAdvance.statusToSet`. These sweep the whole range and ask both, so a
 * line moved on one side alone cannot pass.
 */
class StageParityTest {
    private val statuses = listOf(
        Status(uuid = "s-to-read", name = Status.toReadName),
        Status(uuid = "s-reading", name = Status.readingName),
        Status(uuid = "s-read", name = Status.readName, label = "Finished"),
    )

    /** `locator` null is a book with no position at all. */
    private fun book(locator: Map<String, Any?>?): Book {
        val json = bookJson(uuid = "u", title = "A Book")
        json["status"] = null
        if (locator != null) json["position"] = mapOf("locator" to locator, "timestamp" to 0)
        return decodeBook(json)
    }

    private fun book(at: Double): Book =
        book(mapOf("href" to "a", "type" to "t", "locations" to mapOf("totalProgression" to at)))

    /** Where the shelf puts the book, and where the write would file it. */
    private fun bothSides(subject: Book): Pair<LibraryArrangement.Stage, LibraryArrangement.Stage> {
        val locator = subject.position!!.locator
        val filed = StatusAdvance.statusToSet(after = locator, current = null, generation = ServerGeneration.V3, statuses = statuses)!!
        return LibraryArrangement.stage(subject) to LibraryArrangement.stage(statusNamed = filed.name)
    }

    /** Every point in the range is shelved where its own position files it. */
    @Test
    fun sweep() {
        val progressions = listOf(0.0, 0.001, 0.5, 0.979_999, 0.98, 1.0)
        val expected = listOf(
            LibraryArrangement.Stage.READING, LibraryArrangement.Stage.READING, LibraryArrangement.Stage.READING,
            LibraryArrangement.Stage.READING, LibraryArrangement.Stage.FINISHED, LibraryArrangement.Stage.FINISHED,
        )
        for ((progression, stage) in progressions.zip(expected)) {
            val (shelf, filed) = bothSides(book(at = progression))
            assertEquals("the shelf and the write disagree at $progression", filed, shelf)
            assertEquals("at $progression", stage, shelf)
        }
    }

    /**
     * A position with no progression is being read, on both sides: the server
     * reads a missing progression as the start.
     */
    @Test
    fun missingProgression() {
        for (subject in listOf(
            book(mapOf("href" to "a", "type" to "t")),
            book(mapOf("href" to "a", "type" to "t", "locations" to mapOf("progression" to 0.4))),
        )) {
            val (shelf, filed) = bothSides(subject)
            assertEquals(filed, shelf)
            assertEquals(LibraryArrangement.Stage.READING, shelf)
        }
    }

    /** A book never opened is unstarted. */
    @Test
    fun unopened() {
        assertEquals(LibraryArrangement.Stage.TO_READ, LibraryArrangement.stage(book(locator = null)))
    }

    /** A status is shelved by its name, with the edge of an empty name. */
    @Test
    fun byName() {
        assertEquals(LibraryArrangement.Stage.TO_READ, LibraryArrangement.stage(statusNamed = Status.toReadName))
        assertEquals(LibraryArrangement.Stage.READING, LibraryArrangement.stage(statusNamed = Status.readingName))
        assertEquals(LibraryArrangement.Stage.FINISHED, LibraryArrangement.stage(statusNamed = Status.readName))
        assertEquals(LibraryArrangement.Stage.READING, LibraryArrangement.stage(statusNamed = "Currently Reading"))
        assertEquals(LibraryArrangement.Stage.TO_READ, LibraryArrangement.stage(statusNamed = "Abandoned"))
        assertEquals(LibraryArrangement.Stage.TO_READ, LibraryArrangement.stage(statusNamed = ""))
    }

    /**
     * An admin's own status is shelved by what its words say: the bare word
     * "read" filed every one that contained it as finished.
     */
    @Test
    fun byWording() {
        val toRead = LibraryArrangement.Stage.TO_READ
        val reading = LibraryArrangement.Stage.READING
        val finished = LibraryArrangement.Stage.FINISHED
        val cases = listOf(
            "Read later" to toRead, "Read next" to toRead, "Not read" to toRead,
            "Never read" to toRead, "Not yet read" to toRead, "Unread" to toRead,
            "Un-read" to toRead, "Want to read" to toRead, "Up next" to toRead,
            "Not started" to toRead, "Did not finish" to toRead, "Not finished" to toRead,
            "DNF" to toRead, "Abandoned" to toRead, "Reference" to toRead,
            "Re-read" to reading, "Reread" to reading, "Re-reading" to reading,
            "Half read" to reading, "Half-read" to reading, "Partially read" to reading,
            "In progress" to reading, "Currently Reading" to reading,
            "Already read" to finished, "Finished" to finished, "Finished reading" to finished,
            "Done" to finished, "Done reading" to finished, "Completed" to finished,
        )
        for ((name, stage) in cases) {
            assertEquals("\"$name\"", stage, LibraryArrangement.stage(statusNamed = name))
        }
    }

    /** The built-in statuses stay where they are, in any case. */
    @Test
    fun builtIns() {
        val cases = listOf(
            Status.toReadName to LibraryArrangement.Stage.TO_READ,
            Status.readingName to LibraryArrangement.Stage.READING,
            Status.readName to LibraryArrangement.Stage.FINISHED,
            "TO READ" to LibraryArrangement.Stage.TO_READ,
            "reading" to LibraryArrangement.Stage.READING,
            "READ" to LibraryArrangement.Stage.FINISHED,
        )
        for ((name, stage) in cases) {
            assertEquals("\"$name\"", stage, LibraryArrangement.stage(statusNamed = name))
        }
    }
}
