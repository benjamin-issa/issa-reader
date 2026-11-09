package com.benjaminissa.issareader.core.download

import com.benjaminissa.issareader.core.InMemoryKeyValueStore
import com.benjaminissa.issareader.core.networking.TokenProviding
import com.benjaminissa.issareader.core.temporaryDirectory
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.net.URI

private typealias Job = DownloadManager.Job

private val ebook = BookContentService.Format.EBOOK
private val audiobook = BookContentService.Format.AUDIOBOOK
private val readaloud = BookContentService.Format.READALOUD

/** A transfer made by hand, stamped as given: Swift's tasks from `URLSession.shared`. */
private fun handMade(description: String?): FakeTransfer = FakeTransfer(description)

private fun cancelledError(resume: ByteArray? = null) = TransferError(TransferError.Kind.CANCELLED, "cancelled", resume)

/** Downloads. Ported from `DownloadManagerTests` in `DownloadManagerTests.swift`. */
class DownloadManagerTest {
    /** A job survives the round trip through a task description. */
    @Test
    fun jobRoundTrip() {
        for (format in listOf(ebook, audiobook, readaloud)) {
            val job = Job("0198f1c2-6f5a-7000-8000-abcdef012345", format)
            assertEquals(job, DownloadManager.decode(DownloadManager.encode(job)))
        }
    }

    /** Nonsense task descriptions decode to nothing: after a relaunch the description is all there is. */
    @Test
    fun rejectsGarbage() {
        assertNull(DownloadManager.decode(""))
        assertNull(DownloadManager.decode("no-separator"))
        assertNull(DownloadManager.decode("uuid|nonsense-format"))
        assertNull(DownloadManager.decode("a|b|c"))
    }

    /** A download larger than the disk is refused before it starts. */
    @Test
    fun refusesImpossibleDownload() {
        assertTrue(DownloadManager.hasRoom(1_000))
        // Larger than any device this will run on.
        assertFalse(DownloadManager.hasRoom(500_000_000_000_000))
    }

    /** Progress reads the same whichever state it came from. */
    @Test
    fun fractions() {
        assertEquals(0.0, DownloadManager.State.Queued.fraction, 0.0)
        assertEquals(1.0, DownloadManager.State.Finished.fraction, 0.0)
        assertEquals(0.4, DownloadManager.State.Paused(0.4).fraction, 0.0)
        assertEquals(0.25, DownloadManager.State.Downloading(0.25, 25, 100).fraction, 0.0)
        assertTrue(DownloadManager.State.Failed("no").isFailure)
        assertFalse(DownloadManager.State.Failed("no").isActive)
        assertTrue(DownloadManager.State.Queued.isActive)
    }
}

/**
 * A download that is interrupted: the states a transfer can be left in.
 * Ported from `DownloadInterruptionTests` in `DownloadManagerTests.swift`.
 *
 * A cancellation the app did not ask for used to be ignored, because the only
 * cancellation the code expected was a pause. That left the row reading
 * "downloading" forever with every control on it dead.
 */
class DownloadInterruptionTest {
    /** An active download blocks a second start, which is why a stuck state is fatal. */
    @Test
    fun activeBlocksStart() {
        assertTrue(DownloadManager.State.Downloading(0.5, 5, 10).isActive)
        // `start` guards on isActive, so anything that leaves a job in this
        // state with no live transfer can never be restarted by the user.
        assertTrue(DownloadManager.State.Queued.isActive)
        assertFalse(DownloadManager.State.Paused(0.5).isActive)
        assertFalse(DownloadManager.State.Failed("x").isActive)
        assertFalse(DownloadManager.State.Finished.isActive)
    }

    /** An unknown total is indeterminate, not zero percent. */
    @Test
    fun unknownTotal() {
        val unknown = DownloadManager.State.Downloading(0.0, 4_096, -1)
        assertTrue(unknown.isIndeterminate)
        assertEquals(0.0, unknown.fraction, 0.0)

        assertFalse(DownloadManager.State.Downloading(0.25, 25, 100).isIndeterminate)
        assertFalse(DownloadManager.State.Queued.isIndeterminate)
        assertFalse(DownloadManager.State.Finished.isIndeterminate)
    }

    /** Shutting a manager down stops it writing state. */
    @Test
    fun shutDownSilencesIt() = runTest {
        val subject = downloadManager()
        val job = Job("b", ebook)
        // A real claim first, so there is a state for a late callback to corrupt.
        subject.start(job)
        assertEquals(DownloadManager.State.Queued, subject.state(job))

        subject.shutDown()

        // Late callbacks from the superseded backend — progress, a finished
        // file, the report of the transfer it killed. None may be published.
        val task = handMade(DownloadManager.encode(job))
        subject.onProgress(task, 512, 512, 1_024)
        subject.onFinishedDownloading(task, File(System.getProperty("java.io.tmpdir"), java.util.UUID.randomUUID().toString()))
        subject.onCompleted(task, TransferError(TransferError.Kind.OTHER, "The network connection was lost."))
        settle()
        assertEquals("a shut-down manager must not overwrite state with late callbacks", DownloadManager.State.Queued, subject.state(job))
    }

    /**
     * Cancelling a dead job does not eat the next download's interruption: a
     * stale pause marker once made the next download of the same job swallow
     * a system-initiated cancellation as a pause.
     */
    @Test
    fun cancelOfDeadJobLeavesNoPauseMarker() = runTest {
        val subject = downloadManager()
        val job = Job("b", ebook)

        // Dismiss a job with no live transfer, then download the same book again.
        subject.cancel(job)
        subject.start(job)
        assertTrue(subject.hasTask(job))

        // The system reclaims the transfer: a cancellation nobody asked for,
        // stamped as the manager stamps the transfer it just started.
        val task = handMade(subject.liveTaskDescription(job))
        subject.onCompleted(task, cancelledError())
        settle()

        assertEquals(
            "an unrequested cancellation must surface as a failure, not vanish into a stale pause marker",
            true, subject.state(job)?.isFailure,
        )
        subject.shutDown()
    }

    /**
     * A stopped manager ignores the callbacks its own cancel provokes:
     * sign-out calls `stop()` and then deletes the Books folder, and a late
     * transfer used to re-create it and move the departed account's book in.
     */
    @Test
    fun stopSilencesLateCallbacks() = runTest {
        val root = temporaryDirectory("issa-stop")
        try {
            val books = File(root, "Books")
            val subject = downloadManager(destinationFor = { File(books, "${it.bookUuid}.epub") })
            val job = Job("b", ebook)
            subject.start(job)
            assertTrue(subject.hasTask(job))

            subject.stop()
            assertNull(subject.state(job))

            // A file that landed just as the cancel did, then the cancellation.
            root.mkdirs()
            val source = File(root, "arrived.tmp")
            source.writeText("book")
            val task = handMade(DownloadManager.encode(job))
            subject.onProgress(task, 512, 512, 1_024)
            subject.onFinishedDownloading(task, source)
            subject.onCompleted(task, cancelledError("resume".encodeToByteArray()))
            settle()

            assertFalse("the deleted Books folder must not come back for the account that left", books.exists())
            assertNull("no phantom Retry row for the next account", subject.state(job))
            assertTrue(subject.pending.isEmpty())

            // The same job downloaded again by the next account is a new
            // transfer, whose callbacks count — and the old transfer's,
            // arriving late, still do not.
            subject.start(job)
            assertEquals(DownloadManager.State.Queued, subject.state(job))
            subject.onCompleted(task, cancelledError())
            val fresh = handMade(DownloadManager.encode(job, generation = 1))
            subject.onProgress(fresh, 512, 512, 1_024)
            settle()
            assertEquals(true, subject.state(job)?.isActive)
            subject.shutDown()
        } finally {
            root.deleteRecursively()
        }
    }

    /**
     * Clearing a transfer forgets its row; only cancelling stops it — the bug
     * behind "I deleted it and it came back".
     */
    @Test
    fun clearIsNotCancel() = runTest {
        val subject = downloadManager()
        val job = Job("b", readaloud)
        subject.start(job)
        assertTrue(subject.hasTask(job))

        subject.clear(job)
        assertNull("the row has left the screen", subject.state(job))
        assertTrue("and the transfer behind it has not", subject.hasTask(job))

        subject.cancel(job)
        assertFalse("this is the call that stops a download", subject.hasTask(job))
        assertNull(subject.state(job))
        subject.shutDown()
    }

    /**
     * A completion already in flight cannot land after its job was cancelled.
     * Asserted on the file and on `onFinished`, the two things that actually
     * reached the reader.
     */
    @Test
    fun cancelFencesTheCompletionInFlight() = runTest {
        val root = temporaryDirectory("issa-cancel")
        root.mkdirs()
        try {
            val books = File(root, "Books")
            val subject = downloadManager(destinationFor = { File(books, "${it.bookUuid}.epub") })
            val job = Job("b", readaloud)
            subject.start(job)
            // The stamp the real transfer carries — taken before the cancel,
            // exactly the position a callback already in flight is in.
            val inFlight = subject.liveTaskDescription(job)

            val finished = mutableListOf<Job>()
            subject.onFinished = { finished.add(it) }

            subject.cancel(job)

            val arrived = File(root, "arrived.tmp")
            arrived.writeText("book")
            subject.onFinishedDownloading(handMade(inFlight), arrived)
            settle()

            assertFalse("the cancelled transfer moved its file into place anyway", books.exists())
            assertTrue("onFinished would have put the book back on the shelf", finished.isEmpty())
            assertNull("no row for a transfer the reader stopped", subject.state(job))
            subject.shutDown()
        } finally {
            root.deleteRecursively()
        }
    }

    /** Cancelling one download leaves the others' callbacks live: the fence is per job. */
    @Test
    fun cancelDoesNotFenceOtherJobs() = runTest {
        val subject = downloadManager()
        val cancelled = Job("b", ebook)
        val other = Job("c", readaloud)
        subject.start(cancelled)
        subject.start(other)
        val othersStamp = subject.liveTaskDescription(other)

        subject.cancel(cancelled)

        subject.onProgress(handMade(othersStamp), 512, 512, 1_024)
        settle()

        assertEquals("the other transfer was fenced out by a cancel that was not its own", true, subject.state(other)?.isActive)
        subject.shutDown()
    }

    /** Restarting a cancelled job makes its own callbacks live again: why the fence is a counter. */
    @Test
    fun restartingAfterCancelIsLive() = runTest {
        val subject = downloadManager()
        val job = Job("b", ebook)
        subject.start(job)
        val stale = subject.liveTaskDescription(job)

        subject.cancel(job)
        subject.start(job)
        val fresh = subject.liveTaskDescription(job)
        assertNotEquals("the two transfers have to be tellable apart", stale, fresh)

        subject.onProgress(handMade(stale), 512, 512, 1_024)
        settle()
        assertEquals("the cancelled transfer still reported progress", DownloadManager.State.Queued, subject.state(job))

        subject.onProgress(handMade(fresh), 512, 512, 1_024)
        settle()
        assertEquals(true, subject.state(job)?.isActive)
        subject.shutDown()
    }

    /** A stamped task description still decodes to its job. */
    @Test
    fun stampedDescriptionsDecode() {
        val job = Job("b", readaloud)
        val stamped = DownloadManager.encode(job, generation = 7)
        assertEquals(job, DownloadManager.decode(stamped))
        assertEquals(7, DownloadManager.decodeStamped(stamped)?.generation)
        assertEquals(0, DownloadManager.decodeStamped(stamped)?.epoch)
        assertEquals(0, DownloadManager.decodeStamped(DownloadManager.encode(job))?.generation)
        assertNull(DownloadManager.decode("b|readaloud|x"))

        // Both numbers, and a description from a build that knew of neither.
        val fenced = DownloadManager.encode(job, generation = 7, epoch = 3)
        assertEquals(job, DownloadManager.decode(fenced))
        assertEquals(7, DownloadManager.decodeStamped(fenced)?.generation)
        assertEquals(3, DownloadManager.decodeStamped(fenced)?.epoch)
        assertEquals(
            "a task started by an older build still has to be reattachable",
            0, DownloadManager.decodeStamped("b|readaloud")?.epoch,
        )
        assertNull(DownloadManager.decode("b|readaloud|1|x"))
    }
}

/** Reporting a failed download. Ported from `DownloadReasonTests` in `DownloadManagerTests.swift`. */
class DownloadReasonTest {
    /** A server's own explanation is passed through. */
    @Test
    fun realReasonSurvives() {
        val error = TransferError(TransferError.Kind.OTHER, "The request timed out.")
        assertEquals("The request timed out.", DownloadManager.readableReason(error))
    }

    /** The system's "unknown error" is replaced with something actionable. */
    @Test
    fun unknownBecomesActionable() {
        val reason = DownloadManager.readableReason(TransferError(TransferError.Kind.UNKNOWN, "unknown error"))
        assertFalse(reason.lowercase().contains("unknown error"))
        assertTrue(reason.contains("try again"))
    }
}

/**
 * Holds `currentToken()` — the only suspension between claiming a job and
 * starting its transfer — until released, so the race is deterministic.
 */
private class GatedTokens : TokenProviding {
    private val entered = CompletableDeferred<Unit>()
    private val released = CompletableDeferred<Unit>()

    override suspend fun currentToken(): String {
        entered.complete(Unit)
        released.await()
        return "test-token"
    }

    /** Suspends until `currentToken()` has been entered, so the race is real rather than assumed. */
    suspend fun waitUntilEntered() = entered.await()

    fun release() {
        released.complete(Unit)
    }

    override suspend fun invalidate() {}
}

/**
 * Cancelling before a download's transfer exists. Ported from
 * `CancelBeforeStartTests` in `DownloadManagerTests.swift`.
 */
class CancelBeforeStartTest {
    /**
     * A cancel that lands before the transfer exists is honoured once it
     * would: it once did nothing, and the transfer completed for a download
     * the caller had already asked to stop.
     */
    @Test
    fun cancelDuringTokenFetchStopsTheTask() = runTest {
        val tokens = GatedTokens()
        val manager = downloadManager(tokens = tokens)
        val job = Job("b", ebook)

        val starting = launch { manager.start(job) }
        tokens.waitUntilEntered()
        // `start` is now genuinely suspended inside `currentToken()`.
        assertEquals(DownloadManager.State.Queued, manager.state(job))

        manager.cancel(job)
        assertNull("cancel should clear the state immediately", manager.state(job))

        tokens.release()
        starting.join()

        assertFalse("the task must never be created for a job already cancelled", manager.hasTask(job))
        assertNull("start resuming after the cancel must not resurrect the job", manager.state(job))
        manager.shutDown()
    }

    /** A stop that lands during the token fetch is not undone by the start that resumes. */
    @Test
    fun stopDuringTokenFetchStopsTheTask() = runTest {
        val tokens = GatedTokens()
        val manager = downloadManager(tokens = tokens)
        val job = Job("b", ebook)

        val starting = launch { manager.start(job) }
        tokens.waitUntilEntered()
        assertEquals(DownloadManager.State.Queued, manager.state(job))

        manager.stop()

        tokens.release()
        starting.join()

        assertFalse("the departed account's download must not start", manager.hasTask(job))
        assertNull("and must not leave a row for the next account", manager.state(job))

        // The manager is still usable afterwards: a later start takes the new fence.
        manager.reconfigure(unreachableServer, StubTokens())
        manager.start(job)
        assertTrue(manager.hasTask(job))
        manager.shutDown()
    }

    /** A shutdown that lands before the transfer exists fails the job instead of starting one. */
    @Test
    fun shutDownDuringTokenFetchDoesNotCreateATask() = runTest {
        val tokens = GatedTokens()
        val manager = downloadManager(tokens = tokens)
        val job = Job("b", ebook)

        val starting = launch { manager.start(job) }
        tokens.waitUntilEntered()
        manager.shutDown()
        tokens.release()
        starting.join()

        assertFalse("no transfer may be started on an ended backend", manager.hasTask(job))
        assertEquals("the row must say why, not sit at queued forever", true, manager.state(job)?.isFailure)
    }

    /** Reconfiguring a manager keeps it usable, with the new server. */
    @Test
    fun reconfigureKeepsTheManager() = runTest {
        val manager = downloadManager()
        manager.reconfigure(URI("http://192.0.2.2"), StubTokens())
        val job = Job("b", ebook)
        manager.start(job)
        assertEquals(DownloadManager.State.Queued, manager.state(job))
        assertEquals("192.0.2.2", manager.request(job)?.url?.host)
        manager.shutDown()
    }

    /** Stopping for a sign-out leaves the manager able to download again. */
    @Test
    fun stopThenReconfigureStillDownloads() = runTest {
        val manager = downloadManager()
        val job = Job("b", ebook)
        manager.start(job)
        assertTrue(manager.hasTask(job))

        // Sign out: the transfer and its row go.
        manager.stop()
        assertFalse(manager.hasTask(job))
        assertNull(manager.state(job))
        assertTrue(manager.pending.isEmpty())

        // Sign in as someone else: same manager, same backend, new server.
        manager.reconfigure(URI("http://192.0.2.2"), StubTokens())
        manager.start(job)
        assertEquals(DownloadManager.State.Queued, manager.state(job))
        assertEquals("192.0.2.2", manager.request(job)?.url?.host)
        manager.shutDown()
    }

    /** A cancel after the transfer exists still cancels it directly. */
    @Test
    fun cancelAfterTaskExistsIsUnaffected() = runTest {
        val tokens = GatedTokens()
        val manager = downloadManager(tokens = tokens)
        val job = Job("b", ebook)

        tokens.release()
        manager.start(job)
        assertTrue(manager.hasTask(job))

        manager.cancel(job)
        assertFalse(manager.hasTask(job))
        assertNull(manager.state(job))
        manager.shutDown()
    }

    /** Cancelling a job that never started does not affect a later start of it. */
    @Test
    fun cancelWithoutStartLeavesNoResidue() = runTest {
        val tokens = GatedTokens()
        tokens.release()
        val manager = downloadManager(tokens = tokens)
        val job = Job("b", ebook)

        manager.cancel(job)
        manager.start(job)
        assertTrue("a later, real start must not be swallowed by a stale cancel marker", manager.hasTask(job))
        manager.shutDown()
    }
}

/**
 * The download fence across a relaunch. Ported from `DownloadFenceTests` in
 * `DownloadManagerTests.swift`.
 *
 * A transfer's stamp is kept by the backend, but the numbers it is checked
 * against once lived only in the process: a transfer stamped after a sign-out
 * or a cancel-and-restart, finished while the app was away, was thrown out.
 */
class DownloadFenceTest {
    private fun TestScope.manager(books: File, fenceStore: InMemoryKeyValueStore? = null): DownloadManager =
        downloadManager(fenceStore = fenceStore, destinationFor = { BookContentService.localUrl(books, it.bookUuid, it.format) })

    /** What the backend replays as it is built: a transfer that finished while the app was away. */
    private fun deliverFinished(description: String, subject: DownloadManager, root: File) {
        val task = DownloadAnswer.finishedTask(DownloadAnswer.EPUB)
        task.description = description
        subject.onFinishedDownloading(task, DownloadAnswer.arrivedFile(DownloadAnswer.EPUB, root))
    }

    /** A fence kept by the last launch lets its transfers finish, and still refuses what it stopped. */
    @Test
    fun aKeptFenceJudgesTheLastLaunchesTransfers() = runTest {
        val root = temporaryDirectory("issa-fence")
        val store = InMemoryKeyValueStore()
        try {
            val books = File(root, "Books")
            val restarted = Job("r", ebook)

            // The last launch: a sign-out, then a download cancelled.
            val last = manager(books, store)
            last.stop()
            last.cancel(restarted)
            last.shutDown()

            val subject = manager(books, store)
            val finished = mutableListOf<Job>()
            subject.onFinished = { finished.add(it) }
            val afterSignOut = Job("b", readaloud)
            val beforeSignOut = Job("c", readaloud)

            // The stale ones first: let through, they would publish ahead of
            // the live ones, which the exact comparison below would catch.
            deliverFinished(DownloadManager.encode(beforeSignOut), subject, root)
            deliverFinished(DownloadManager.encode(restarted, generation = 1), subject, root)
            deliverFinished(DownloadManager.encode(afterSignOut, generation = 1), subject, root)
            deliverFinished(DownloadManager.encode(restarted, generation = 1, epoch = 1), subject, root)
            settle { finished.size >= 2 }

            assertEquals("only the transfers started after the sign-out and the cancel are wanted", listOf(afterSignOut, restarted), finished)
            assertEquals(DownloadManager.State.Finished, subject.state(afterSignOut))
            assertEquals(DownloadManager.State.Finished, subject.state(restarted))
            assertNull("the sign-out stopped this one", subject.state(beforeSignOut))
            assertFalse(BookContentService.localUrl(books, "c", readaloud).exists())
            subject.shutDown()
        } finally {
            root.deleteRecursively()
        }
    }

    /** Every stop and cancel writes the fence down, so a launch that ends without warning has kept it. */
    @Test
    fun theFenceIsKeptAsItMoves() = runTest {
        val store = InMemoryKeyValueStore()
        val subject = manager(temporaryDirectory("issa-fence"), store)
        val job = Job("b", ebook)
        assertNull("nothing to keep before anything moved it", DownloadManager.loadFence(store))

        subject.cancel(job)
        assertEquals(DownloadManager.Fence(global = 0, perJob = mapOf(job to 1), armed = true), DownloadManager.loadFence(store))
        subject.stop()
        assertEquals(DownloadManager.Fence(global = 1, perJob = emptyMap(), armed = true), DownloadManager.loadFence(store))
        subject.shutDown()
    }

    /**
     * A job cancelled before the system's transfers are reattached stays
     * cancelled, rather than being re-stamped and adopted back into life.
     */
    @Test
    fun aCancelledJobIsNotAdoptedBack() = runTest {
        val subject = manager(temporaryDirectory("issa-fence"))
        val cancelled = Job("b", readaloud)
        val untouched = Job("c", ebook)
        subject.cancel(cancelled)

        val stale = handMade(DownloadManager.encode(cancelled))
        val carried = handMade(DownloadManager.encode(untouched))
        subject.adopt(listOf(stale, carried))

        assertFalse("the cancelled job was adopted back into life", subject.hasTask(cancelled))
        assertNull(subject.state(cancelled))
        assertTrue(
            "and its transfer has to stop",
            stale.state == FakeTransfer.State.CANCELING || stale.state == FakeTransfer.State.COMPLETED,
        )
        assertTrue("a transfer nobody cancelled is still taken on", subject.hasTask(untouched))
        assertEquals(true, subject.state(untouched)?.isActive)
        subject.shutDown()
    }

    /**
     * Unarmed, a transfer the system carried on with is taken on as this
     * launch's own, and stays live once the fence arms for another job.
     */
    @Test
    fun unarmedAdoptionRestamps() = runTest {
        val root = temporaryDirectory("issa-fence")
        try {
            val books = File(root, "Books")
            val subject = manager(books)
            val job = Job("b", readaloud)
            val finished = mutableListOf<Job>()
            subject.onFinished = { finished.add(it) }

            val carried = DownloadAnswer.finishedTask(DownloadAnswer.EPUB)
            carried.description = DownloadManager.encode(job, generation = 4, epoch = 2)
            subject.adopt(listOf(carried))
            assertTrue(subject.hasTask(job))
            assertEquals(DownloadManager.encode(job), carried.description)

            subject.cancel(Job("other", ebook))
            subject.onFinishedDownloading(carried, DownloadAnswer.arrivedFile(DownloadAnswer.EPUB, root))
            settle { finished.isNotEmpty() }

            assertEquals("arming for another job stranded an adopted transfer", listOf(job), finished)
            assertEquals(DownloadManager.State.Finished, subject.state(job))
            subject.shutDown()
        } finally {
            root.deleteRecursively()
        }
    }

    /**
     * A transfer finished while the app was away is kept on the first launch
     * after upgrading: no stamp can be judged, and throwing a finished book
     * away is the worse of the two mistakes.
     */
    @Test
    fun anUpgradeKeepsWhatFinishedWhileAway() {
        for ((generation, epoch) in listOf(1 to 0, 0 to 1, 3 to 2)) {
            runTest {
                val root = temporaryDirectory("issa-fence")
                try {
                    val books = File(root, "Books")
                    val subject = manager(books)
                    val finished = mutableListOf<Job>()
                    subject.onFinished = { finished.add(it) }
                    val job = Job("b", readaloud)

                    val task = DownloadAnswer.finishedTask(DownloadAnswer.EPUB)
                    task.description = DownloadManager.encode(job, generation = generation, epoch = epoch)
                    subject.onFinishedDownloading(task, DownloadAnswer.arrivedFile(DownloadAnswer.EPUB, root))
                    settle { subject.state(job) != null }

                    assertEquals("the finished transfer was thrown away ($generation, $epoch)", DownloadManager.State.Finished, subject.state(job))
                    assertTrue(BookContentService.localUrl(books, "b", readaloud).exists())
                    assertEquals(listOf(job), finished)
                    subject.shutDown()
                } finally {
                    root.deleteRecursively()
                }
            }
        }
    }

    /**
     * A download cancelled and started again still reports an interruption it
     * did not ask for, rather than swallowing it as a pause.
     */
    @Test
    fun aRestartAfterCancelStillReportsInterruption() = runTest {
        val subject = manager(temporaryDirectory("issa-fence"))
        val job = Job("b", ebook)
        subject.start(job)
        assertTrue("the cancel has to find a live task", subject.hasTask(job))

        subject.cancel(job)
        subject.start(job)
        val restarted = handMade(subject.liveTaskDescription(job))
        subject.onProgress(restarted, 512, 512, 1_024)
        settle { subject.state(job)?.fraction == 0.5 }
        assertEquals("the restarted transfer is under way", 0.5, subject.state(job)?.fraction)

        // The system reclaims it: a cancellation nobody here asked for.
        subject.onCompleted(restarted, cancelledError())
        settle { subject.state(job)?.isFailure == true }

        assertEquals("swallowed as a pause, the row stays at downloading with nothing behind it", true, subject.state(job)?.isFailure)
        assertFalse(subject.hasTask(job))
        subject.shutDown()
    }

    /** R-56. A pause's late callback does not bring back a download cancelled after it. */
    @Test
    fun aCancelAfterAPauseStaysCancelled() = runTest {
        val subject = manager(temporaryDirectory("issa-fence"))
        val job = Job("b", ebook)
        subject.start(job)
        assertTrue("the pause has to find a live task", subject.hasTask(job))

        subject.pause(job)
        subject.cancel(job)
        assertNull(subject.state(job))

        // The real transfer's cancellation callback, whenever the backend sends it.
        settle { subject.pauseCallbacksDelivered > 0 }
        assertEquals("the pause's callback never came", 1, subject.pauseCallbacksDelivered)

        assertNull("the cancelled download came back as ${subject.state(job)}", subject.state(job))
        assertFalse(subject.hasResumeData(job))
        subject.shutDown()
    }

    /**
     * R-57. A download paused, cancelled and started again still reports an
     * interruption it did not ask for.
     */
    @Test
    fun aRestartAfterPauseAndCancelStillReportsInterruption() = runTest {
        val subject = manager(temporaryDirectory("issa-fence"))
        val job = Job("b", ebook)
        subject.start(job)
        assertTrue("the pause has to find a live task", subject.hasTask(job))

        subject.pause(job)
        subject.cancel(job)
        settle { subject.pauseCallbacksDelivered > 0 }

        subject.start(job)
        val restarted = handMade(subject.liveTaskDescription(job))
        subject.onProgress(restarted, 512, 512, 1_024)
        settle { subject.state(job)?.fraction == 0.5 }
        assertEquals("the restarted transfer is under way", 0.5, subject.state(job)?.fraction)

        // The system reclaims it: a cancellation nobody here asked for.
        subject.onCompleted(restarted, cancelledError())
        settle { subject.state(job)?.isFailure == true }

        assertEquals("swallowed as the old pause, the row stays at downloading with nothing behind it", true, subject.state(job)?.isFailure)
        subject.shutDown()
    }
}
