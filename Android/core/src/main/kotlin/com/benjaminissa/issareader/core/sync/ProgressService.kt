package com.benjaminissa.issareader.core.sync

import com.benjaminissa.issareader.core.model.ReadiumLocator
import com.benjaminissa.issareader.core.model.StoredPosition
import com.benjaminissa.issareader.core.model.roundedHalfAwayFromZero
import com.benjaminissa.issareader.core.networking.ApiClient
import com.benjaminissa.issareader.core.networking.Endpoint
import com.benjaminissa.issareader.core.networking.StorytellerError
import com.benjaminissa.issareader.core.toEpochSecondsDouble
import kotlinx.serialization.Serializable
import java.time.Instant

/**
 * Reads and writes reading position.
 *
 * The server's contract has two sharp edges, both verified against a running
 * instance:
 *
 * - It rejects a write whose timestamp is older than the stored one **and**
 *   one whose timestamp is equal but whose locator differs, so timestamps are
 *   milliseconds. Second resolution causes avoidable conflicts.
 * - Writing a position silently moves the book's reading status: to "Reading"
 *   below 98% and to "Read" at or above it. Callers should not also set status
 *   by hand, and should expect it to change underneath them. The exception is
 *   a 3.x book with no status at all, which the server means to advance but
 *   cannot — its UPDATE finds no status row — so there, and only there, the
 *   client sets it; see [StatusAdvance].
 */
class ProgressService(private val client: ApiClient) {
    @Serializable
    internal data class PositionBody(val locator: ReadiumLocator, val timestamp: Double)

    suspend fun current(bookUuid: String): StoredPosition? = try {
        client.get(Endpoint.positions(bookUuid), StoredPosition.serializer())
    } catch (_: StorytellerError.NotFound) {
        // No position yet simply means the book has not been opened.
        null
    }

    /**
     * Writes a position, reconciling if the server already has a newer one.
     *
     * Returns the position that ended up winning, so the caller can jump to it
     * rather than silently continuing from a place the user has already moved
     * past on another device.
     */
    suspend fun save(locator: ReadiumLocator, bookUuid: String, timestamp: Double = now()): StoredPosition? = try {
        client.post(Endpoint.positions(bookUuid), PositionBody(locator, timestamp), PositionBody.serializer())
        StoredPosition(uuid = null, locator = locator, timestamp = timestamp)
    } catch (_: StorytellerError.PositionConflict) {
        // Another device is further along, or wrote a different locator at
        // the same instant. The server's copy wins; report it back.
        current(bookUuid)
    }

    companion object {
        /** Epoch milliseconds, matching what the server stores and compares. */
        fun now(): Double = (Instant.now().toEpochSecondsDouble() * 1000).roundedHalfAwayFromZero()
    }
}
