package com.benjaminissa.issareader.core.sync

import com.benjaminissa.issareader.core.assertThrowing
import com.benjaminissa.issareader.core.store.LibraryStore
import com.benjaminissa.issareader.core.store.SqliteDatabase
import com.benjaminissa.issareader.core.temporaryDirectory
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/**
 * [MutationQueue] and [LibraryStore] open two independent connections to the
 * same SQLite file. Proving the busy-timeout fix means proving both halves of
 * it: that real lock contention between those two connections actually
 * happens, and that the queue's connection now waits it out instead of
 * throwing the instant it collides. Ported from
 * `MutationQueueLockingTests.swift`.
 */
class MutationQueueLockingTest {
    /**
     * Holds a real write transaction open on a further connection to the file
     * until told to let go, so a test can race something against it with no
     * timing guesswork: [lockAcquired] only counts down once the lock is
     * genuinely held, [holderFinished] once the transaction has closed.
     */
    private fun holdLock(path: String, lockAcquired: CountDownLatch, releaseLock: CountDownLatch, holderFinished: CountDownLatch) {
        thread {
            try {
                SqliteDatabase(path).use { contender ->
                    contender.write { db ->
                        db.execute("CREATE TABLE IF NOT EXISTS lock_probe(x INTEGER)")
                        db.execute("INSERT INTO lock_probe (x) VALUES (1)")
                        lockAcquired.countDown()
                        releaseLock.await()
                    }
                }
            } catch (_: Throwable) {
                lockAcquired.countDown()
            }
            holderFinished.countDown()
        }
    }

    /**
     * A bare second connection with no busy timeout fails immediately.
     * Establishes that the harness creates real contention, and that SQLite's
     * own default fails the way the bug report described — immediately, not
     * after a wait. Without this, a passing test below would not distinguish
     * "waited and succeeded" from "there was never any contention".
     */
    @Test
    fun bareConnectionFailsImmediately() {
        val directory = temporaryDirectory("issa-lock")
        try {
            LibraryStore(serverKey = "http://example.test", directory = directory).use { store ->
                val path = store.url.path

                val lockAcquired = CountDownLatch(1)
                val releaseLock = CountDownLatch(1)
                val holderFinished = CountDownLatch(1)
                holdLock(path, lockAcquired, releaseLock, holderFinished)
                assertTrue(lockAcquired.await(10, TimeUnit.SECONDS))

                SqliteDatabase(path).use { bare ->
                    assertThrowing<Exception>("SQLite's default is not to wait at all") {
                        bare.write { db -> db.execute("CREATE TABLE IF NOT EXISTS other(x INTEGER)") }
                    }
                }

                releaseLock.countDown()
                assertTrue(holderFinished.await(10, TimeUnit.SECONDS))
            }
        } finally {
            directory.deleteRecursively()
        }
    }

    /**
     * The queue waits out the same contention instead of failing immediately.
     * Without its busy timeout, this is exactly the call above, on exactly the
     * same file, and it throws the same way — silently, because every caller
     * wraps `enqueue` in a `runCatching`.
     */
    @Test
    fun mutationQueueWaitsRatherThanFailing() = runBlocking {
        val directory = temporaryDirectory("issa-lock")
        try {
            LibraryStore(serverKey = "http://example.test", directory = directory).use { store ->
                MutationQueue(store).use { queue ->
                    val path = store.url.path

                    val lockAcquired = CountDownLatch(1)
                    val releaseLock = CountDownLatch(1)
                    val holderFinished = CountDownLatch(1)
                    holdLock(path, lockAcquired, releaseLock, holderFinished)
                    assertTrue(lockAcquired.await(10, TimeUnit.SECONDS))

                    // Released from a timer well inside the 5s timeout, so the
                    // write below must sit and wait for it rather than failing.
                    thread {
                        Thread.sleep(300)
                        releaseLock.countDown()
                    }

                    val recorded = queue.enqueue(MutationQueue.Kind.STATUS, bookUuid = "x", payload = "{}".encodeToByteArray())
                    assertTrue(recorded)
                    val pending = queue.pending()
                    assertEquals("the write must have actually reached the database, not merely not thrown", 1, pending.size)

                    assertTrue(holderFinished.await(10, TimeUnit.SECONDS))
                }
            }
        } finally {
            directory.deleteRecursively()
        }
    }

    /**
     * Starts an enqueue that has to wait out [holdLock]'s write lock, and
     * returns once it is genuinely waiting, with what it ends in.
     */
    private fun waitingEnqueue(queue: MutationQueue): Pair<Thread, () -> Result<Boolean>> {
        var outcome: Result<Boolean>? = null
        val writer = thread {
            outcome = runCatching {
                runBlocking { queue.enqueue(MutationQueue.Kind.STATUS, bookUuid = "x", payload = "{}".encodeToByteArray()) }
            }
        }
        // Long enough to be inside SQLite's busy wait, well short of its five seconds.
        Thread.sleep(300)
        return writer to { outcome!! }
    }

    /**
     * The drain's controls never wait behind a write that is waiting on
     * SQLite. They run on the main thread — the drain's claim and hand-over,
     * the yield check before each row, an account's retirement — and the
     * queue used to hold one JVM lock across both its bookkeeping and every
     * database call, so a write sitting in the five-second busy wait froze the
     * main thread for as long: long enough for Android to call the app
     * unresponsive.
     */
    @Test
    fun theDrainControlsNeverWaitBehindAWaitingWrite() {
        val directory = temporaryDirectory("issa-lock")
        try {
            LibraryStore(serverKey = "http://example.test", directory = directory).use { store ->
                MutationQueue(store).use { queue ->
                    val lockAcquired = CountDownLatch(1)
                    val releaseLock = CountDownLatch(1)
                    val holderFinished = CountDownLatch(1)
                    holdLock(store.url.path, lockAcquired, releaseLock, holderFinished)
                    assertTrue(lockAcquired.await(10, TimeUnit.SECONDS))
                    val (writer, _) = waitingEnqueue(queue)

                    val started = System.nanoTime()
                    assertTrue(queue.beginDraining())
                    queue.shouldYield
                    queue.endDraining()
                    val tookMillis = (System.nanoTime() - started) / 1_000_000
                    assertTrue("the drain's controls took $tookMillis ms behind a waiting write", tookMillis < 100)

                    releaseLock.countDown()
                    writer.join(10_000)
                    assertTrue(holderFinished.await(10, TimeUnit.SECONDS))
                }
            }
        } finally {
            directory.deleteRecursively()
        }
    }

    /**
     * Retiring a queue does not wait for a write that is waiting on SQLite,
     * and that write is then refused: retirement's promise — nothing lands
     * after the caller's DELETE — now rests on the write checking the flag
     * inside its own transaction, which the DELETE has to wait for.
     */
    @Test
    fun retiringDoesNotWaitAndTheWaitingWriteIsRefused() = runBlocking {
        val directory = temporaryDirectory("issa-lock")
        try {
            LibraryStore(serverKey = "http://example.test", directory = directory).use { store ->
                MutationQueue(store).use { queue ->
                    val lockAcquired = CountDownLatch(1)
                    val releaseLock = CountDownLatch(1)
                    val holderFinished = CountDownLatch(1)
                    holdLock(store.url.path, lockAcquired, releaseLock, holderFinished)
                    assertTrue(lockAcquired.await(10, TimeUnit.SECONDS))
                    val (writer, outcome) = waitingEnqueue(queue)

                    val started = System.nanoTime()
                    queue.retire()
                    val tookMillis = (System.nanoTime() - started) / 1_000_000
                    assertTrue("retire() took $tookMillis ms behind a waiting write", tookMillis < 100)

                    releaseLock.countDown()
                    writer.join(10_000)
                    assertTrue(holderFinished.await(10, TimeUnit.SECONDS))
                    assertTrue(
                        "a write still waiting when the queue retired must be refused",
                        outcome().exceptionOrNull() is MutationQueue.Retired,
                    )
                    assertEquals(0, queue.count())
                }
            }
        } finally {
            directory.deleteRecursively()
        }
    }
}
