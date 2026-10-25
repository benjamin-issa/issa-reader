package com.benjaminissa.issareader.playback

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread
import kotlin.concurrent.withLock

// Ported from `RemovalWaitTests.swift`.

/**
 * What a removal of extracted narration may wait for, and what may put it back.
 *
 * The removal runs on the main thread — a local book's undo window closing, a
 * download removed — and took the extraction's lock synchronously. Cancelling
 * the extraction first is only noticed between archive members, and a member
 * is streamed whole however large it is, so the interface froze for the rest
 * of one member: several seconds for a narration cut into a couple of
 * gigabyte-sized files. And the chunk-duration cache, written at the end of a
 * first listen, re-created the folder a removal had just deleted.
 */
class RemovalWaitTest {
    private fun scratch(): File = scratchDirectory("issa-removal-wait")

    private fun contents(directory: File): List<String> = directory.list()?.toList() ?: emptyList()

    /**
     * R-53. The extraction is inside one member's write, holding the lock, for
     * up to eight seconds — released on a timer, so a regression fails rather
     * than hangs.
     */
    @Test
    fun removalDoesNotWaitForAMember() {
        val root = scratch().apply { mkdirs() }
        val directory = File(root, "Audio")
        val gate = AudioExtractionTest.Gate()
        try {
            thread(isDaemon = true) {
                Thread.sleep(8_000)
                gate.release()
            }
            val finished = CountDownLatch(1)
            thread(isDaemon = true) {
                // The production lock around the production loop, with a write
                // that stands in for `EpubArchive.extract`: it is mid-member until
                // the gate opens, then writes where its destination says — which
                // fails, as the real one's rename does, once the folder has gone.
                runCatching {
                    AudioExtraction.locks.lock(directory).withLock {
                        AudioExtraction.extract(
                            listOf("OEBPS/Audio/one.mp3", "OEBPS/Audio/two.mp3"),
                            { _, destination ->
                                gate.holdOnce()
                                destination.writeText("narration")
                            },
                            directory,
                        ) { false }
                    }
                }
                finished.countDown()
            }
            check(gate.waitUntilHeld(5_000)) { "the extraction never reached its first member" }
            check(directory.exists())

            val started = System.nanoTime()
            AudioExtraction.removeExtractedAudio(directory, root)
            val waited = (System.nanoTime() - started) / 1e9
            gate.release()

            assertTrue("the removal waited $waited s for the member being written", waited < 1)
            assertFalse("the removal did not happen", directory.exists())
            assertTrue("the extraction never finished", finished.await(10, TimeUnit.SECONDS))
            assertFalse("the extraction finishing put back the folder the removal took", directory.exists())
            // And what was set aside is deleted, off the caller's thread.
            val deadline = System.nanoTime() + 5_000_000_000L
            var leftovers = contents(root)
            while (leftovers.isNotEmpty() && System.nanoTime() < deadline) {
                Thread.sleep(50)
                leftovers = contents(root)
            }
            assertTrue("set-aside narration was left on disk: $leftovers", leftovers.isEmpty())
        } finally {
            gate.release()
            root.deleteRecursively()
        }
    }

    /** A removal with nothing extracting is the same removal it always was: done by the time it returns. */
    @Test
    fun anIdleRemovalIsImmediate() {
        val root = scratch()
        try {
            val directory = File(root, "Audio").apply { mkdirs() }
            File(directory, "one.mp3").writeText("narration")

            AudioExtraction.removeExtractedAudio(directory)

            assertTrue(contents(root).isEmpty())
        } finally {
            root.deleteRecursively()
        }
    }

    // The duration cache

    /**
     * R-54. A read-along removed during its first listen: the measurement ran
     * on, and its save made the folder again to write `durations.json` into — a
     * cache the next extraction of that book would trust without checking.
     */
    @Test
    fun aSaveDoesNotRecreateTheFolder() = runBlocking {
        val root = scratch()
        try {
            val directory = AudioExtraction.defaultDirectory("book", root)

            runCatching { ChunkDurations.save(mapOf("OEBPS/Audio/one.mp3" to 12.0), "book", root) }

            assertFalse("the cache re-made the folder of a removed book", directory.exists())
        } finally {
            root.deleteRecursively()
        }
    }

    /**
     * The other half: a measurement that was cancelled — its book removed, its
     * listen stopped — writes nothing, even into a folder still there.
     */
    @Test
    fun aCancelledSaveWritesNothing() = runBlocking {
        val root = scratch()
        try {
            val directory = AudioExtraction.defaultDirectory("book", root)
            directory.mkdirs()

            // Started at once, as a Swift task always runs its body: a coroutine
            // cancelled before it ran would never reach the save, and prove nothing.
            val job = launch(Dispatchers.Default, start = CoroutineStart.UNDISPATCHED) {
                try {
                    delay(30_000)
                } catch (_: CancellationException) {
                    // Swallowed, as the Swift test's `try?` swallows the sleep's
                    // cancellation: what is under test is the save's own check.
                }
                runCatching { ChunkDurations.save(mapOf("OEBPS/Audio/one.mp3" to 12.0), "book", root) }
            }
            job.cancel()
            job.join()

            assertFalse(
                "a cancelled measurement wrote its partial answer",
                ChunkDurations.cacheFile("book", root).exists(),
            )
        } finally {
            root.deleteRecursively()
        }
    }
}
