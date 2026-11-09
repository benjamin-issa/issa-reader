package com.benjaminissa.issareader.playback

import com.benjaminissa.issareader.epub.EpubArchive
import com.benjaminissa.issareader.epub.EpubPackage
import com.benjaminissa.issareader.epub.SmilEntry
import com.benjaminissa.issareader.epub.SmilTimeline
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.concurrent.CancellationException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.thread
import kotlin.concurrent.withLock

// Ported from `AudioExtractionTests.swift`.

/**
 * An extraction that has been revoked has to stop, and stop having happened.
 *
 * The reader and the car can both be extracting one book's narration at the
 * moment the reader deletes it, and `removeExtractedAudio` deletes the very
 * directory `extractAudio` writes into. Serialising the two is only half a fix:
 * it turns a torn directory into an all-or-nothing one, and the losing run
 * still wins, because `extract` opens by creating the directory and then writes
 * every chunk into it. A book deleted mid-extraction came straight back, in
 * full, and stayed — uncounted by the storage screen and unreachable from the
 * interface.
 *
 * Nothing here asserts on the lock itself. Two threads arriving in a chosen
 * order is a race dressed up as an assertion; what can be stated is what an
 * extraction does once it has been told to stand down, which is the half that
 * decides the outcome either way.
 */
class AudioExtractionTest {
    private fun scratch(): File = scratchDirectory("issa-revoke")

    /**
     * A long read-along is a hundred and seventy-six files and several hundred
     * megabytes. An extraction revoked at chunk three must not go on to write
     * the remaining hundred and seventy-three.
     *
     * `after = 2` is the two questions asked before the second chunk: one before
     * the directory is created, one at the top of the first file. So exactly one
     * file is written and the second is where it gives up.
     */
    @Test
    fun revokedBetweenChunksStopsWriting() {
        val (timeline, epubPackage) = readalongTimeline()
        check(timeline.entries.map { it.audioHref }.toSet().size > 1) { "one track cannot show a stop between two" }
        val directory = scratch()
        try {
            val revoked = Revoked(after = 2)

            assertThrows(CancellationException::class.java) {
                AudioExtraction.extractAudio(epubPackage, timeline, "book", directory) { revoked.isCancelled }
            }

            val written = checkNotNull(directory.list())
            assertEquals("it carried on through a book it had been told to drop", 1, written.size)
        } finally {
            directory.deleteRecursively()
        }
    }

    /**
     * The line that used to undo a removal outright.
     *
     * `extract` opens by creating the directory, so an extraction that had been
     * waiting behind a removal woke up and re-made the folder the removal had
     * just deleted — and then filled it. Asked before anything is created, the
     * revoked run leaves the disk exactly as the removal left it.
     */
    @Test
    fun revokedBeforeStartingCreatesNothing() {
        val (timeline, epubPackage) = readalongTimeline()
        val root = scratch()
        try {
            val directory = AudioExtraction.defaultDirectory("book", root)
            // A book already extracted, which is what a removal finds.
            directory.mkdirs()
            File(directory, "already.mp3").writeText("narration")

            AudioExtraction.removeExtractedAudio("book", root)
            check(!directory.exists()) { "the removal has to have happened for this to mean anything" }

            val revoked = Revoked(after = 0)
            assertThrows(CancellationException::class.java) {
                AudioExtraction.extractAudio(epubPackage, timeline, "book", directory) { revoked.isCancelled }
            }

            assertFalse("the extraction put back the directory the removal had just deleted", directory.exists())
        } finally {
            root.deleteRecursively()
        }
    }

    /**
     * One book's removal and another book's extraction share nothing on disk, so
     * they must not share a lock either.
     *
     * The lock was process-wide, and the removal takes it synchronously on the
     * main thread: removing book Y from Downloads while book X's narration was
     * being inflated froze the app for the rest of X's extraction, and the only
     * cancellations that could cut that short were for X itself.
     *
     * X is held inside its lock — `isCancelled` is asked under it — for up to
     * eight seconds, released on a timer so a regression fails rather than
     * hangs.
     */
    @Test
    fun removingOneBookDoesNotWaitForAnother() {
        val (timeline, epubPackage) = readalongTimeline()
        val root = scratch()
        val gate = Gate()
        try {
            thread(isDaemon = true) {
                Thread.sleep(8_000)
                gate.release()
            }
            val finished = CountDownLatch(1)
            thread(isDaemon = true) {
                runCatching {
                    AudioExtraction.extractAudio(
                        epubPackage, timeline, "book-x", AudioExtraction.defaultDirectory("book-x", root),
                    ) {
                        gate.holdOnce()
                        false
                    }
                }
                finished.countDown()
            }
            check(gate.waitUntilHeld(5_000)) { "book X's extraction never reached its lock" }

            val started = System.nanoTime()
            AudioExtraction.removeExtractedAudio("book-y", root)
            val waited = (System.nanoTime() - started) / 1e9
            gate.release()

            assertTrue("removing book Y waited $waited s on book X's extraction", waited < 1)
            assertTrue("book X's extraction never finished", finished.await(10, TimeUnit.SECONDS))
        } finally {
            gate.release()
            root.deleteRecursively()
        }
    }

    /**
     * Narration was read into memory whole and then written out, and the
     * archive's whole-in-memory read refuses any member that inflates past
     * 256 MB — so a long book cut into few, large audio files lost its narration
     * outright. Streamed to disk a slice at a time, a member of any honest size
     * extracts.
     *
     * 257 MB of silence, which deflates to a few hundred kilobytes: past the
     * in-memory cap, and cheap to build.
     */
    @Test
    fun aMemberPastTheInMemoryCapExtracts() {
        val size = 257L * 1024 * 1024
        val data = InTestEpub.readalong(InTestEpub.deflatedZeros("OEBPS/Audio/big.mp3", size))
        val epubPackage = EpubPackage.open(EpubArchive(data))
        val timeline = SmilTimeline(listOf(SmilEntry("s0", "OEBPS/ch01.xhtml", "OEBPS/Audio/big.mp3", 0.0, 5.0, 5.0)))
        val directory = scratch()
        try {
            val files = AudioExtraction.extractAudio(epubPackage, timeline, "big", directory)

            val file = checkNotNull(files["OEBPS/Audio/big.mp3"])
            assertEquals(size, file.length())
        } finally {
            directory.deleteRecursively()
        }
    }

    /**
     * The default, and every caller in the app relies on it: nothing passes a
     * function of its own. An extraction on a live, uninterrupted thread must
     * extract.
     */
    @Test
    fun anUnrevokedExtractionWritesEverything() {
        val (timeline, epubPackage) = readalongTimeline()
        val directory = scratch()
        try {
            val files = AudioExtraction.extractAudio(epubPackage, timeline, "book", directory)

            assertEquals(timeline.entries.map { it.audioHref }.toSet().size, files.size)
            for (file in files.values) assertTrue(file.exists())
        } finally {
            directory.deleteRecursively()
        }
    }

    /**
     * The coroutine-friendly cancellation, Android's own: the default question
     * is whether the thread doing the work has been interrupted, which is what
     * `runInterruptible` does to it when its coroutine is cancelled.
     */
    @Test
    fun anInterruptedThreadStandsDown() {
        val (timeline, epubPackage) = readalongTimeline()
        val directory = scratch()
        try {
            var failure: Throwable? = null
            val worker = thread {
                Thread.currentThread().interrupt()
                failure = runCatching { AudioExtraction.extractAudio(epubPackage, timeline, "book", directory) }
                    .exceptionOrNull()
            }
            worker.join()
            assertTrue("an interrupted extraction carried on: $failure", failure is CancellationException)
            assertFalse(directory.exists())
        } finally {
            directory.deleteRecursively()
        }
    }

    /**
     * Holds the first thread that reaches it until released, and lets another
     * thread wait — with a deadline — for that to have happened.
     */
    internal class Gate {
        private val lock = ReentrantLock()
        private val changed = lock.newCondition()
        private var held = false
        private var released = false

        /** Blocks the first caller until [release]; every later call passes. */
        fun holdOnce() = lock.withLock {
            if (held) return@withLock
            held = true
            changed.signalAll()
            while (!released) changed.await()
        }

        fun waitUntilHeld(timeoutMillis: Long): Boolean = lock.withLock {
            val deadline = System.nanoTime() + timeoutMillis * 1_000_000
            while (!held) {
                val left = deadline - System.nanoTime()
                if (left <= 0) return@withLock held
                changed.awaitNanos(left)
            }
            true
        }

        fun release() = lock.withLock {
            released = true
            changed.signalAll()
        }
    }

    /**
     * A cancellation that arrives at a named moment: false until it has been
     * asked [after] times, true from then on.
     *
     * A counter rather than a real cancellation, because what is under test is
     * where the question is asked — before the directory exists, and again
     * between chunks — and a cancelled coroutine cannot say which of those it
     * reached.
     */
    private class Revoked(private val after: Int) {
        private var asked = 0

        val isCancelled: Boolean
            @Synchronized get() {
                asked += 1
                return asked > after
            }
    }
}
