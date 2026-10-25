package com.benjaminissa.issareader.core.sync

import com.benjaminissa.issareader.core.Stub
import com.benjaminissa.issareader.core.networking.ApiClient
import com.benjaminissa.issareader.core.networking.Endpoint
import com.benjaminissa.issareader.core.networking.TokenProviding
import com.benjaminissa.issareader.core.stubHttp
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test
import java.net.URI

/**
 * Answers `/api/v2/user/ratings` with the rows its host names, and nothing
 * else. Stateless: the test chooses the body by choosing the host.
 */
private val ratingsHttp = stubHttp { request ->
    val bodies = mapOf(
        "absurd.ratings.test" to """
            [{"bookUuid":"huge","rating":1e300},{"bookUuid":"negative","rating":-1e300},
             {"bookUuid":"over","rating":9},{"bookUuid":"fine","rating":4},
             {"bookUuid":"unrated","rating":null},{"rating":3}]
        """.trimIndent(),
    )
    val body = if (request.url.encodedPath == Endpoint.userRatings) bodies[request.url.host] else null
    Stub.Answer(if (body == null) 404 else 200, body ?: "{}", mapOf("Content-Type" to "application/json"))
}

private class RatingTokens : TokenProviding {
    override suspend fun currentToken(): String = "test-token"
    override suspend fun invalidate() {}
}

/**
 * Ratings are put on the five-star scale where they arrive. Ported from
 * `RatingDecodeTests.swift`.
 *
 * R-07, at the boundary. A rating comes from the server as any `Double` —
 * `1e300` is valid JSON, written by any client or straight to the API — and
 * from here it is persisted, reloaded at every launch and handed to every
 * surface that draws stars. Clamped once where it enters, no surface has to
 * remember what converting `1e300` to an integer does.
 */
class RatingDecodeTest {
    /** The server's ratings are clamped to 0…5 as they are decoded. */
    @Test
    fun myRatingsAreClamped() = runBlocking {
        val client = ApiClient(baseUrl = URI("https://absurd.ratings.test"), tokens = RatingTokens(), http = ratingsHttp)

        val ratings = LibraryService(client).myRatings()

        assertEquals(mapOf("huge" to 5.0, "negative" to 0.0, "over" to 5.0, "fine" to 4.0), ratings)
    }

    /** Whole stars are safe for any number at all. */
    @Test
    fun wholeStarsNeverTrap() {
        val cases = listOf(
            Double.POSITIVE_INFINITY to 0, Double.NEGATIVE_INFINITY to 0, Double.NaN to 0,
            1e300 to 5, -1e300 to 0, 2.5 to 3, 2.49 to 2, 0.0 to 0, 5.0 to 5,
        )
        for ((rating, stars) in cases) {
            assertEquals("$rating", stars, StarRating.wholeStars(rating))
        }
    }
}
