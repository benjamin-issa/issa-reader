package com.benjaminissa.issareader.core.sync

import com.benjaminissa.issareader.core.networking.ApiClient
import com.benjaminissa.issareader.core.networking.Endpoint
import com.benjaminissa.issareader.core.networking.StorytellerError
import kotlinx.serialization.Serializable

/**
 * Writes the per-user state a reader actually changes: reading status and
 * their own rating.
 *
 * Both are per-user rather than per-book — two people sharing a server keep
 * separate shelves and separate ratings.
 */
class LibraryMutationService(private val client: ApiClient) {
    // Reading status

    @Serializable
    internal data class StatusBody(val status: String)

    @Serializable
    internal data class BulkStatusBody(val books: List<String>, val status: String)

    /**
     * Moves a book to a status.
     *
     * Worth knowing: the server also moves status on its own whenever a reading
     * position is written — to "Reading" below 98% and "Read" at or above it.
     * A manual choice can therefore be overwritten by simply continuing to
     * read, which is usually what someone wants but is surprising if they have
     * just marked something "To read". 3.x skips a book with *no* status — its
     * update has no row to change — so the client makes that one move itself
     * ([StatusAdvance]), and not through this call: the app applies the
     * status it chose to the book and queues the write in [MutationQueue], and
     * [MutationDrain] sends it, as the same PUT this call makes, which inserts
     * the missing row.
     */
    suspend fun setStatus(statusUuid: String, bookUuid: String) {
        client.put(Endpoint.status(bookUuid), StatusBody(statusUuid), StatusBody.serializer())
    }

    /** Moves several books at once, for multi-select in the library. */
    suspend fun setStatus(statusUuid: String, bookUuids: List<String>) {
        if (bookUuids.isEmpty()) return
        client.put(Endpoint.bulkStatus, BulkStatusBody(bookUuids, statusUuid), BulkStatusBody.serializer())
    }

    // Rating

    @Serializable
    data class Rating(
        /** 0...5. The server rejects anything outside that range. */
        val rating: Double? = null,
        val review: String? = null,
    )

    suspend fun rating(bookUuid: String): Rating? = try {
        client.get(Endpoint.rating(bookUuid), Rating.serializer())
    } catch (_: StorytellerError.NotFound) {
        // Unrated, which is not an error.
        null
    }

    /**
     * Sets this user's rating.
     *
     * The server answers 405 — not 400 — for an out-of-range value or an empty
     * body, so the range is enforced here and an empty write is turned into a
     * delete rather than sent.
     */
    suspend fun setRating(value: Double?, review: String? = null, bookUuid: String) {
        if (value == null && review == null) {
            clearRating(bookUuid)
            return
        }
        val clamped = value?.let { minOf(maxOf(it, 0.0), 5.0) }
        client.put(Endpoint.rating(bookUuid), Rating(rating = clamped, review = review), Rating.serializer())
    }

    suspend fun clearRating(bookUuid: String) {
        client.delete(Endpoint.rating(bookUuid))
    }
}
