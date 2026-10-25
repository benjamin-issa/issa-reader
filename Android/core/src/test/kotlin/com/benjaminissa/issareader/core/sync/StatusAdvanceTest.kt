package com.benjaminissa.issareader.core.sync

import com.benjaminissa.issareader.core.fixtureStatuses
import com.benjaminissa.issareader.core.model.ReadiumLocator
import com.benjaminissa.issareader.core.model.ServerGeneration
import com.benjaminissa.issareader.core.model.Status
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Advancing a book with no status after a position write: the server's own
 * status rule, applied where 3.x cannot apply it. Ported from
 * `StatusAdvanceTests.swift`.
 */
class StatusAdvanceTest {
    private val toRead = Status(uuid = "s-to-read", name = Status.toReadName)
    private val reading = Status(uuid = "s-reading", name = Status.readingName)

    /** Relabelled, as the v3 capture has it: the rule matches by name. */
    private val read = Status(uuid = "s-read", name = Status.readName, label = "Finished")
    private val abandoned = Status(uuid = "s-abandoned", name = "Abandoned")

    private val statuses: List<Status> get() = listOf(toRead, reading, read, abandoned)

    private fun at(progression: Double?): ReadiumLocator = ReadiumLocator(
        href = "OEBPS/ch01.xhtml", type = "application/xhtml+xml",
        locations = ReadiumLocator.Locations(progression = progression, totalProgression = progression),
    )

    private fun next(
        after: ReadiumLocator,
        current: Status? = null,
        generation: ServerGeneration? = ServerGeneration.V3,
        statuses: List<Status> = this.statuses,
    ): Status? = StatusAdvance.statusToSet(after = after, current = current, generation = generation, statuses = statuses)

    /** Below 98% a book with no status moves to Reading. */
    @Test
    fun belowThresholdMovesToReading() {
        assertEquals(reading, next(at(0.5)))
    }

    /** At 98% or more it moves to Read, whatever the label says. */
    @Test
    fun atThresholdMovesToRead() {
        assertEquals(read, next(at(0.99)))
        assertEquals("the server's comparison is inclusive", read, next(at(0.98)))
        assertEquals(reading, next(at(0.979_999)))
    }

    /** A locator with no progression counts as the start, as the server reads it. */
    @Test
    fun missingLocations() {
        val bare = ReadiumLocator(href = "OEBPS/ch01.xhtml", type = "application/xhtml+xml")
        assertEquals(reading, next(bare))
        assertEquals(reading, next(at(null)))
    }

    /**
     * An undetected server is advanced too. The first launch after an upgrade
     * can be offline, before detection has answered — and those are exactly
     * the writes 3.x will not advance.
     */
    @Test
    fun unknownGenerationAdvances() {
        assertEquals(reading, next(at(0.4), generation = null))
    }

    /** A known 2.x server is left to advance its own books. */
    @Test
    fun v2NeverAdvances() {
        assertNull(next(at(0.4), generation = ServerGeneration.V2))
        assertNull(next(at(0.99), generation = ServerGeneration.V2))
    }

    /** A book that has any status is left alone. */
    @Test
    fun existingStatusIsLeftAlone() {
        for (current in listOf(toRead, reading, read, abandoned)) {
            assertNull("${current.name} at 50%", next(at(0.5), current = current))
            assertNull("${current.name} at 99%", next(at(0.99), current = current))
        }
    }

    /** With no status by the built-in name there is nothing to set. */
    @Test
    fun missingBuiltInStatus() {
        assertNull(next(at(0.5), statuses = listOf(toRead, read)))
        assertNull(next(at(0.99), statuses = listOf(toRead, reading)))
        assertNull("statuses not loaded yet", next(at(0.5), statuses = emptyList()))
    }

    /** The captured 3.x statuses resolve by name, not label. */
    @Test
    fun capturedStatuses() {
        val captured = fixtureStatuses("v3/statuses")
        val next = next(at(1.0), statuses = captured)!!
        assertEquals("030f4277-3fd4-4a09-a4cb-0a46812f529a", next.uuid)
        assertEquals("Finished", next.displayName)
    }
}
