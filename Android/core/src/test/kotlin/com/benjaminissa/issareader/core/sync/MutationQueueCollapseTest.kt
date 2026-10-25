package com.benjaminissa.issareader.core.sync

import com.benjaminissa.issareader.core.IssaJson
import com.benjaminissa.issareader.core.Stub
import com.benjaminissa.issareader.core.assertThrowing
import com.benjaminissa.issareader.core.model.ReadiumLocator
import com.benjaminissa.issareader.core.networking.ApiClient
import com.benjaminissa.issareader.core.networking.TokenProviding
import com.benjaminissa.issareader.core.store.LibraryStore
import com.benjaminissa.issareader.core.stubHttp
import com.benjaminissa.issareader.core.temporaryDirectory
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.URI
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicBoolean

/** A queue on a fresh store, closed and removed afterwards. */
private fun withQueue(prefix: String, block: suspend (MutationQueue) -> Unit) = runBlocking {
    val directory = temporaryDirectory(prefix)
    try {
        LibraryStore(serverKey = "http://example.test", directory = directory).use { store ->
            MutationQueue(store).use { queue -> block(queue) }
        }
    } finally {
        directory.deleteRecursively()
    }
}

/**
 * `enqueue`'s collapse: a newer write for the same book and kind replaces the
 * queued one, and what it inherits from it. Ported from
 * `MutationQueueCollapseTests.swift`.
 */
class MutationQueueCollapseTest {
    private fun data(text: String) = text.encodeToByteArray()

    /**
     * A collapsed write inherits the failures of the one it replaces. A
     * position the server keeps refusing is re-enqueued by every page turn,
     * and each collapse once inserted a new row with no attempts, so it never
     * reached the abandon limit.
     */
    @Test
    fun collapseCarriesAttempts() = withQueue("issa-queue") { queue ->
        queue.enqueue(MutationQueue.Kind.POSITION, bookUuid = "b", payload = data("1"), supersedes = 1.0)
        val first = queue.pending().first()
        repeat(3) { assertFalse(queue.recordFailure(first.id)) }

        queue.enqueue(MutationQueue.Kind.POSITION, bookUuid = "b", payload = data("2"), supersedes = 2.0)
        val pending = queue.pending()
        assertEquals(1, pending.size)
        assertEquals(3, pending.first().attempts)
        assertArrayEquals("the newer payload still wins", data("2"), pending.first().payload)
        assertEquals("and the age of the write it replaced", first.createdAt, pending.first().createdAt)
    }

    /** The inherited count still reaches the abandon limit. */
    @Test
    fun inheritedAttemptsCanAbandon() = withQueue("issa-queue") { queue ->
        queue.enqueue(MutationQueue.Kind.POSITION, bookUuid = "b", payload = data("1"), supersedes = 1.0)
        for (round in 1..8) {
            val item = queue.pending().first()
            val abandoned = queue.recordFailure(item.id)
            assertEquals("round $round", round == 8, abandoned)
            if (!abandoned) {
                queue.enqueue(MutationQueue.Kind.POSITION, bookUuid = "b", payload = data("$round"), supersedes = (round + 1).toDouble())
            }
        }
        assertTrue(queue.pending().isEmpty())
    }

    /** An older write does not replace a newer queued one. */
    @Test
    fun olderWriteIsDropped() = withQueue("issa-queue") { queue ->
        queue.enqueue(MutationQueue.Kind.POSITION, bookUuid = "b", payload = data("new"), supersedes = 10.0)
        val recorded = queue.enqueue(MutationQueue.Kind.POSITION, bookUuid = "b", payload = data("old"), supersedes = 5.0)
        assertFalse(recorded)
        assertArrayEquals(data("new"), queue.pending().first().payload)
    }

    /** A fresh write for a book with nothing queued starts at zero. */
    @Test
    fun freshWriteStartsClean() = withQueue("issa-queue") { queue ->
        queue.enqueue(MutationQueue.Kind.STATUS, bookUuid = "b", payload = data("{}"))
        assertEquals(0, queue.pending().first().attempts)
    }

    /**
     * A write replaced after a later one is sent after it. Offline: a page
     * read, "To read" chosen, then read on. The server must end on Reading,
     * as it would have online.
     */
    @Test
    fun aReplacedWriteGoesBehindTheOnesBeforeIt() = withQueue("issa-queue") { queue ->
        queue.enqueue(MutationQueue.Kind.POSITION, bookUuid = "b", payload = data("page"), supersedes = 1.0)
        queue.enqueue(MutationQueue.Kind.STATUS, bookUuid = "b", payload = data("to read"))
        queue.enqueue(MutationQueue.Kind.POSITION, bookUuid = "b", payload = data("read on"), supersedes = 3.0)

        val pending = queue.pending()
        assertEquals(
            "the status was chosen before the reader read on, so it goes first",
            listOf(MutationQueue.Kind.STATUS, MutationQueue.Kind.POSITION), pending.map { it.kind },
        )
        assertArrayEquals(data("read on"), pending.last().payload)
    }

    /**
     * A row an older build wrote is ordered by when it was queued: it has no
     * `updatedAt`, and its queued time stands in.
     */
    @Test
    fun anOlderBuildsRowKeepsItsPlace() = withQueue("issa-queue") { queue ->
        val now = System.currentTimeMillis() / 1000.0
        queue.enqueueAsOlderBuildForTesting(MutationQueue.Kind.STATUS, bookUuid = "early", payload = data("{}"), createdAt = now - 60)
        queue.enqueue(MutationQueue.Kind.STATUS, bookUuid = "current", payload = data("{}"))
        queue.enqueueAsOlderBuildForTesting(MutationQueue.Kind.STATUS, bookUuid = "late", payload = data("{}"), createdAt = now + 60)

        assertEquals(listOf("early", "current", "late"), queue.pending().map { it.bookUuid })
    }
}

/**
 * A pre-migration row still says how new it is. Ported from
 * `MutationOrderingFallbackTests` in `MutationQueueCollapseTests.swift`.
 */
class MutationOrderingFallbackTest {
    private fun payload(timestamp: Double): ByteArray = IssaJson.encodeToString(
        MutationDrain.PositionPayload.serializer(),
        MutationDrain.PositionPayload(
            locator = ReadiumLocator(
                href = "c1.xhtml", type = "application/xhtml+xml",
                locations = ReadiumLocator.Locations(progression = 0.6, totalProgression = 0.6, charOffset = 1),
            ),
            timestamp = timestamp,
        ),
    ).encodeToByteArray()

    /**
     * An older write cannot replace a queued one whose ordering column is
     * NULL — as every row written before `v4-mutation-ordering` has.
     */
    @Test
    fun nullOrderingStillProtects() = withQueue("issa-order") { queue ->
        // A row as the old build left it: a real payload, no ordering column.
        queue.enqueue(MutationQueue.Kind.POSITION, bookUuid = "b", payload = payload(2_000.0))
        queue.clearOrderingForTesting(bookUuid = "b")

        // An older write arrives. It must not win.
        val replaced = queue.enqueue(MutationQueue.Kind.POSITION, bookUuid = "b", payload = payload(1_000.0), supersedes = 1_000.0)
        assertFalse("the queued row is newer; it may be the only copy of the reader's place", replaced)

        val held = queue.pending().first()
        val decoded = IssaJson.decodeFromString(MutationDrain.PositionPayload.serializer(), held.payload.decodeToString())
        assertEquals(2_000.0, decoded.timestamp, 0.0)
    }

    /** A newer write still replaces it. */
    @Test
    fun newerStillWins() = withQueue("issa-order") { queue ->
        queue.enqueue(MutationQueue.Kind.POSITION, bookUuid = "b", payload = payload(2_000.0))
        queue.clearOrderingForTesting(bookUuid = "b")
        val replaced = queue.enqueue(MutationQueue.Kind.POSITION, bookUuid = "b", payload = payload(3_000.0), supersedes = 3_000.0)
        assertTrue(replaced)
    }
}

/**
 * Holds the first request it sees until released, so a drain can be caught
 * mid-flight — the only state in which the lock means anything. Shared state,
 * so this class's tests run one at a time, as JUnit runs them.
 */
private object Blocking {
    private val lock = Any()
    private var gate = CountDownLatch(1)
    private var started = 0
    private var blockFirst = true

    fun reset() = synchronized(lock) {
        gate = CountDownLatch(1)
        started = 0
        blockFirst = true
    }

    val requestsStarted: Int get() = synchronized(lock) { started }

    fun release() = synchronized(lock) { gate }.countDown()

    val http = stubHttp {
        val (gate, shouldBlock) = synchronized(lock) {
            started += 1
            val block = blockFirst
            blockFirst = false
            gate to block
        }
        if (shouldBlock) gate.await()
        Stub.Answer(200, "{}")
    }
}

private class StubTokens : TokenProviding {
    override suspend fun currentToken(): String = "test-token"
    override suspend fun invalidate() {}
}

/**
 * Only one drain runs at a time: two drains over one queue, one of them caught
 * mid-request. Ported from `DrainExclusionTests` in
 * `MutationQueueCollapseTests.swift`.
 *
 * These go through [MutationDrain] against a request that does not return
 * until told to, which is the only way the lock's behaviours — declining for
 * an ordinary caller, waiting for the exit path, a pause that waits for the
 * request in flight and no more, a retired queue that stops mid-backlog — are
 * observable at all.
 */
class DrainExclusionTest {
    /** Somewhere for the drains under test to run while the test thread watches. */
    private val background = CoroutineScope(Dispatchers.Default)

    private fun withDrain(block: suspend (MutationDrain, MutationQueue) -> Unit) = withQueue("issa-drainlock") { queue ->
        Blocking.reset()
        val client = ApiClient(baseUrl = URI("https://storyteller.test"), tokens = StubTokens(), http = Blocking.http)
        block(MutationDrain(queue, client), queue)
    }

    /** Yields until [condition] holds or a bounded number of turns pass. */
    private suspend fun settle(condition: () -> Boolean) {
        for (turn in 0 until 200) {
            if (condition()) return
            delay(5)
        }
    }

    private val reading = """{"status":"reading"}""".encodeToByteArray()

    /** A second drain declines rather than sending the same rows again (F-5.9). */
    @Test
    fun secondDrainDeclines() = withDrain { drain, queue ->
        queue.enqueue(MutationQueue.Kind.STATUS, bookUuid = "a", payload = reading)

        val first = background.async { drain.drain() }
        settle { Blocking.requestsStarted == 1 }
        assertEquals("the first drain has to be mid-request", 1, Blocking.requestsStarted)

        val second = drain.drain()
        assertEquals("the second caller must decline, not read the same row", 0, second)
        assertEquals("the row was sent twice", 1, Blocking.requestsStarted)

        Blocking.release()
        assertEquals(1, first.await())
    }

    /**
     * R-55. A write queued while a drain runs goes with that drain: the
     * decline above is only right if the running drain sends what the
     * declining caller came with.
     */
    @Test
    fun aWriteQueuedMidDrainGoesWithIt() = withDrain { drain, queue ->
        queue.enqueue(MutationQueue.Kind.RATING, bookUuid = "a", payload = """{"rating":4}""".encodeToByteArray())

        val first = background.async { drain.drain() }
        settle { Blocking.requestsStarted == 1 }
        assertEquals("the first drain has to be mid-request", 1, Blocking.requestsStarted)

        // The second tap: the queued 4 becomes a row for 5, and the drain this
        // enqueue triggers declines.
        queue.enqueue(MutationQueue.Kind.RATING, bookUuid = "a", payload = """{"rating":5}""".encodeToByteArray())
        assertEquals(0, drain.drain())

        Blocking.release()
        assertEquals("the 5 was left for some later drain", 2, first.await())
        assertEquals(2, Blocking.requestsStarted)
        assertEquals(0, queue.count())
    }

    /**
     * The exit path waits for an in-flight drain and then sends what it left:
     * on the way out there is no next enqueue to send it.
     */
    @Test
    fun exitPathWaitsAndSends() = withDrain { drain, queue ->
        queue.enqueue(MutationQueue.Kind.STATUS, bookUuid = "a", payload = reading)

        val first = background.async { drain.drain() }
        settle { Blocking.requestsStarted == 1 }
        // Written while the first drain is blocked; its `pending()` was read
        // before this row existed, so only a drain that runs *after* it can
        // send this one.
        queue.enqueue(MutationQueue.Kind.STATUS, bookUuid = "b", payload = reading)

        val completed = AtomicBoolean(false)
        val waiting = background.async {
            val sent = drain.drain(waitingForInFlight = true)
            completed.set(true)
            sent
        }
        settle { completed.get() }
        assertFalse("the exit path declined instead of waiting", completed.get())
        assertEquals(1, Blocking.requestsStarted)

        Blocking.release()
        assertEquals(1, first.await())
        assertEquals("the row queued during the first drain was never sent", 1, waiting.await())
        assertEquals(2, Blocking.requestsStarted)
        assertEquals(0, queue.count())
    }

    /** Yields until someone is in line for the lock. */
    private suspend fun settleUntilWaiting(queue: MutationQueue) {
        for (turn in 0 until 200) {
            if (queue.shouldYield) return
            delay(5)
        }
    }

    /**
     * Finding #5: a pause waits for the request in flight, not the backlog,
     * then holds the lock — so a sign-in never swaps the bearer under a
     * running drain, and is never held for a whole backlog.
     */
    @Test
    fun pauseWaitsForTheItemInFlightThenHolds() = withDrain { drain, queue ->
        queue.enqueue(MutationQueue.Kind.STATUS, bookUuid = "a", payload = reading)
        queue.enqueue(MutationQueue.Kind.STATUS, bookUuid = "b", payload = reading)

        val first = background.async { drain.drain() }
        settle { Blocking.requestsStarted == 1 }
        assertEquals("the drain has to be mid-request", 1, Blocking.requestsStarted)

        val paused = AtomicBoolean(false)
        val pausing = background.launch {
            queue.pauseDraining()
            paused.set(true)
        }
        settleUntilWaiting(queue)
        assertTrue("the pause never got in line for the lock", queue.shouldYield)
        assertFalse("the pause took the lock from under a request in flight", paused.get())

        Blocking.release()
        pausing.join()
        assertEquals("the drain sent the rest of its backlog with a pause waiting", 1, first.await())
        assertEquals(1, Blocking.requestsStarted)

        // Held: nothing goes out until the pause is lifted.
        assertEquals("a drain started while the pause held the lock", 0, drain.drain())
        assertEquals(1, Blocking.requestsStarted)

        queue.resumeDraining()
        assertEquals("the row the pause held back was not sent after it", 1, drain.drain())
        assertEquals(2, Blocking.requestsStarted)
        assertEquals(0, queue.count())
    }

    /**
     * A retired queue refuses new rows and sends nothing more — and says so at
     * once, without waiting for the lock the drain is holding.
     */
    @Test
    fun aRetiredQueueRefusesRowsAndSendsNothing() = withDrain { drain, queue ->
        queue.enqueue(MutationQueue.Kind.STATUS, bookUuid = "a", payload = reading)
        queue.enqueue(MutationQueue.Kind.STATUS, bookUuid = "b", payload = reading)

        val first = background.async { drain.drain() }
        settle { Blocking.requestsStarted == 1 }
        assertEquals("the drain has to be mid-request", 1, Blocking.requestsStarted)

        val retired = AtomicBoolean(false)
        background.launch {
            queue.retire()
            retired.set(true)
        }
        settle { retired.get() }
        assertTrue("retiring waited for the lock a drain was holding", retired.get())
        assertThrowing<MutationQueue.Retired>("a retired queue took a row") {
            queue.enqueue(MutationQueue.Kind.STATUS, bookUuid = "c", payload = """{"status":"read"}""".encodeToByteArray())
        }

        Blocking.release()
        assertEquals("the drain went on to the next row of a retired queue", 1, first.await())
        assertEquals(0, drain.drain())
        assertEquals(0, drain.drain(waitingForInFlight = true))
        assertEquals("a retired queue sent a row", 1, Blocking.requestsStarted)
        assertEquals("retiring clears nothing; the refused row was never written", listOf("b"), queue.pending().map { it.bookUuid })
    }
}
