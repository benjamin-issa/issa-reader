package com.benjaminissa.issareader.core.sync

import com.benjaminissa.issareader.core.Stub
import com.benjaminissa.issareader.core.diagnostics.IssaLog
import com.benjaminissa.issareader.core.networking.ApiClient
import com.benjaminissa.issareader.core.networking.Endpoint
import com.benjaminissa.issareader.core.networking.TokenProviding
import com.benjaminissa.issareader.core.store.LibraryStore
import com.benjaminissa.issareader.core.stubHttp
import com.benjaminissa.issareader.core.temporaryDirectory
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.net.URI
import java.net.UnknownHostException
import java.util.UUID

private class StubTokenProvider : TokenProviding {
    override suspend fun currentToken(): String = "test-token"
    override suspend fun invalidate() {}
}

/**
 * Hands out one status code per request, in the order given, then 200 for
 * anything beyond that — so a test states exactly what the server does to each
 * successive item without needing to know which item is sent first. Priming
 * [OFFLINE] in place of a status serves a transport-level failure instead of
 * an HTTP response.
 *
 * Shared state, so the suite's tests run one at a time, as JUnit runs a
 * class's tests.
 */
private object StatusQueue {
    /** Primed in place of an HTTP status to fail the request the way a dead network does. */
    const val OFFLINE = -1

    /** What `/api/v2/user` sends with its status: a user, the way Storyteller answers it. */
    const val STORYTELLER_USER = """{"id":"reader-1","username":"reader"}"""

    private val lock = Any()
    private val queue = ArrayDeque<Int>()
    private var requestCount = 0
    private var userRequestCount = 0
    private var userBody = STORYTELLER_USER

    fun prime(statuses: List<Int>, userBody: String = STORYTELLER_USER) = synchronized(lock) {
        queue.clear()
        queue.addAll(statuses)
        requestCount = 0
        userRequestCount = 0
        this.userBody = userBody
    }

    val requestsMade: Int get() = synchronized(lock) { requestCount }

    /** How many of those asked who the reader is — the drain's question of whether Storyteller itself is answering. */
    val userRequestsMade: Int get() = synchronized(lock) { userRequestCount }

    val http = stubHttp { request ->
        val asksForUser = request.url.encodedPath == Endpoint.user
        val (status, body) = synchronized(lock) {
            requestCount += 1
            if (asksForUser) userRequestCount += 1
            (queue.removeFirstOrNull() ?: 200) to userBody
        }
        if (status == OFFLINE) {
            Stub.Fail(UnknownHostException("The Internet connection appears to be offline."))
        } else {
            Stub.Answer(status, if (asksForUser) body else "{}")
        }
    }
}

/**
 * Draining the mutation queue against real HTTP responses. Ported from
 * `MutationDrainTests.swift`: `drain()` against a real [ApiClient], stubbed at
 * the transport so the status codes that drive its error handling are
 * exercised, rather than only the classification logic in isolation.
 */
class MutationDrainTest {
    private class Fixture(val drain: MutationDrain, val queue: MutationQueue, val store: LibraryStore, val directory: File) {
        fun close() {
            queue.close()
            store.close()
            directory.deleteRecursively()
        }
    }

    private fun withDrain(block: suspend (MutationDrain, MutationQueue) -> Unit) = runBlocking {
        val directory = temporaryDirectory("issa-drain")
        val store = LibraryStore(serverKey = "http://example.test", directory = directory)
        val queue = MutationQueue(store)
        StatusQueue.prime(emptyList())
        val client = ApiClient(baseUrl = URI("https://storyteller.test"), tokens = StubTokenProvider(), http = StatusQueue.http)
        val fixture = Fixture(MutationDrain(queue, client), queue, store, directory)
        try {
            block(fixture.drain, fixture.queue)
        } finally {
            fixture.close()
        }
    }

    private val reading = """{"status":"reading"}""".encodeToByteArray()

    private suspend fun enqueueThree(queue: MutationQueue) {
        for (book in listOf("a", "b", "c")) queue.enqueue(MutationQueue.Kind.STATUS, bookUuid = book, payload = reading)
    }

    /**
     * An expired token stops the drain and keeps every item queued. A 401 on
     * the first item once fell into the discard branch with no break, so one
     * expired token silently emptied the entire backlog.
     */
    @Test
    fun expiredTokenKeepsEverythingQueued() = withDrain { drain, queue ->
        enqueueThree(queue)
        assertEquals(3, queue.count())

        StatusQueue.prime(listOf(401, 200, 200))
        val sent = drain.drain()

        assertEquals("nothing should count as sent once the session is bad", 0, sent)
        assertEquals("every item, not just the one that 401ed, must survive", 3, queue.count())
        // The loop must stop at the first 401 rather than trying the rest.
        assertEquals(1, StatusQueue.requestsMade)
    }

    /** A refusal specific to one item does not block the rest of the queue. */
    @Test
    fun itemSpecificRefusalDoesNotBlockOthers() = withDrain { drain, queue ->
        queue.enqueue(MutationQueue.Kind.STATUS, bookUuid = "gone", payload = reading)
        queue.enqueue(MutationQueue.Kind.STATUS, bookUuid = "fine", payload = reading)
        assertEquals(2, queue.count())

        // 404 on one item, 200 on the other — order-independent: either way
        // the queue should end up empty.
        StatusQueue.prime(listOf(404, 200))
        val sent = drain.drain()

        assertEquals(1, sent)
        assertEquals(0, queue.count())
        assertEquals("both items should have been attempted", 2, StatusQueue.requestsMade)
    }

    /**
     * A front door refusing everything keeps the backlog. A 404 or a 403 from
     * in front of Storyteller — a stopped container behind a proxy, a changed
     * path prefix, an auth proxy — is not Storyteller saying a book is gone.
     */
    @Test
    fun aFrontDoorRefusingEverythingKeepsTheBacklog() {
        for (status in listOf(404, 403)) {
            withDrain { drain, queue ->
                enqueueThree(queue)

                // Three rows, then the question of who is answering — refused alike.
                StatusQueue.prime(listOf(status, status, status, status))
                val sent = drain.drain()

                assertEquals("$status", 0, sent)
                assertEquals("nothing proved these refusals were Storyteller's ($status)", 3, queue.count())
                assertEquals("every row, then one question about the server ($status)", 4, StatusQueue.requestsMade)
                assertEquals("$status", 1, StatusQueue.userRequestsMade)
            }
        }
    }

    /** Refusals are dropped once Storyteller is seen to answer: then a refusal is its verdict on the row. */
    @Test
    fun refusalsDropOnceStorytellerAnswers() = withDrain { drain, queue ->
        enqueueThree(queue)

        StatusQueue.prime(listOf(404, 403, 404, 200))
        val sent = drain.drain()

        assertEquals(0, sent)
        assertEquals("Storyteller answered, so the refusals were its own", 0, queue.count())
        assertEquals(1, StatusQueue.userRequestsMade)
    }

    /** A 200 that is not a user is no proof: a front door's own page says nothing about a user. */
    @Test
    fun aPageInPlaceOfAUserIsNoProof() = withDrain { drain, queue ->
        enqueueThree(queue)

        StatusQueue.prime(listOf(404, 404, 404, 200), userBody = "<html><body>Sign in</body></html>")
        drain.drain()

        assertEquals(3, queue.count())
        assertEquals(1, StatusQueue.userRequestsMade)
    }

    /** A broken connection asks nothing and drops nothing. */
    @Test
    fun aTransportBreakKeepsRefusalsWithoutAsking() = withDrain { drain, queue ->
        enqueueThree(queue)

        StatusQueue.prime(listOf(404, StatusQueue.OFFLINE))
        drain.drain()

        assertEquals("the refused row went with nothing to show who refused it", 3, queue.count())
        assertEquals("the drain has to stop at the break", 2, StatusQueue.requestsMade)
        assertEquals(0, StatusQueue.userRequestsMade)
    }

    /** A genuine transport failure stops the drain but keeps the item for retry. */
    @Test
    fun transportFailureStopsAndKeeps() = withDrain { drain, queue ->
        queue.enqueue(MutationQueue.Kind.STATUS, bookUuid = "a", payload = reading)
        queue.enqueue(MutationQueue.Kind.STATUS, bookUuid = "b", payload = reading)

        // 500 is retryable: it records a failure and breaks — asserted so a
        // future change to the 401 handling cannot merge the two.
        StatusQueue.prime(listOf(500, 200))
        val sent = drain.drain()

        assertEquals(0, sent)
        assertEquals("a retryable failure must not discard anything", 2, queue.count())
        assertEquals(1, StatusQueue.requestsMade)
    }

    /**
     * A superseded write is dropped, and the rest of the queue still goes: 409
     * means the server already holds something newer.
     */
    @Test
    fun supersededWriteIsDroppedWithoutBlocking() = withDrain { drain, queue ->
        queue.enqueue(MutationQueue.Kind.STATUS, bookUuid = "stale", payload = reading)
        queue.enqueue(MutationQueue.Kind.STATUS, bookUuid = "fresh", payload = reading)

        StatusQueue.prime(listOf(409, 200))
        val sent = drain.drain()

        assertEquals("the 409 is not a send", 1, sent)
        assertEquals("an obsolete write must not be kept forever", 0, queue.count())
        assertEquals("409 must not stop the drain", 2, StatusQueue.requestsMade)
    }

    /**
     * Offline drains never count toward abandoning a write. A request that
     * never reached the server says nothing about the item, no matter how many
     * times it happens.
     */
    @Test
    fun offlineDrainsNeverAbandon() = withDrain { drain, queue ->
        queue.enqueue(MutationQueue.Kind.STATUS, bookUuid = "kept", payload = reading)

        // Comfortably past the abandon limit of 8.
        repeat(12) {
            StatusQueue.prime(listOf(StatusQueue.OFFLINE))
            assertEquals(0, drain.drain())
        }

        val pending = queue.pending()
        assertEquals("an unreachable server must never cost a queued write", 1, pending.size)
        assertEquals("a transport failure is no evidence against the item, so it must not even count", 0, pending.first().attempts)
    }

    /**
     * R-06. A proxy's 502, 503 or 504 never counts toward abandoning a write:
     * that is the front door saying nothing is behind it.
     */
    @Test
    fun gatewayFailuresNeverAbandon() {
        for (status in listOf(502, 503, 504)) {
            withDrain { drain, queue ->
                queue.enqueue(MutationQueue.Kind.STATUS, bookUuid = "kept", payload = """{"status":"read"}""".encodeToByteArray())

                // Comfortably past the abandon limit of 8, each a drain of its own.
                repeat(12) {
                    StatusQueue.prime(listOf(status))
                    assertEquals("$status", 0, drain.drain())
                }

                val pending = queue.pending()
                assertEquals("an outage behind a proxy must never cost a queued write ($status)", 1, pending.size)
                assertEquals("a gateway's answer is no evidence against the write ($status)", 0, pending.first().attempts)
            }
        }
    }

    /** A write the server keeps choking on is abandoned at the limit, and logged. */
    @Test
    fun poisonedWriteIsAbandonedAndLogged() = withDrain { drain, queue ->
        // Unique, so the log assertion cannot match a line left over from an
        // earlier run: the log store is real and keeps six hours.
        val book = "poisoned-${UUID.randomUUID()}"
        queue.enqueue(MutationQueue.Kind.STATUS, bookUuid = book, payload = reading)

        // Eight separate drains, exactly as real ones arrive — each gets one
        // 500 and stops.
        for (attempt in 1..8) {
            StatusQueue.prime(listOf(500))
            drain.drain()
            if (attempt < 8) {
                assertEquals("attempt $attempt is short of the limit and must not abandon yet", 1, queue.count())
            }
        }

        assertEquals("the eighth refusal must abandon the write", 0, queue.count())
        val logged = IssaLog.export().split("\n").any { it.contains("sync mutation abandoned") && it.contains(book) }
        assertTrue("a write thrown away by the abandon limit must say so in the log", logged)
    }
}
