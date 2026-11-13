package com.benjaminissa.issareader.core.download

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

private typealias PartialJob = DownloadManager.Job

private val partialEbook = BookContentService.Format.EBOOK

/**
 * A download's partial file belongs to the transfer that may resume it, and
 * goes when nothing will: the backend is told to throw it away on a cancel,
 * a removal and a sign-out, and to sweep the ones no one owns at launch.
 */
class DownloadPartialFilesTest {
    private val kept = "resume".encodeToByteArray()

    private suspend fun failedWithPartial(subject: DownloadManager, job: PartialJob) {
        subject.start(job)
        val task = FakeTransfer(DownloadManager.encode(job))
        subject.onCompleted(task, TransferError(TransferError.Kind.OTHER, "The server returned 503.", kept))
    }

    @Test
    fun `cancelling a download with a kept partial discards it`() = runTest {
        val backends = mutableListOf<FakeBackend>()
        val subject = downloadManager(backends = backends)
        val job = PartialJob("b", partialEbook)
        failedWithPartial(subject, job)
        settle { subject.hasResumeData(job) }
        assertTrue(subject.hasResumeData(job))

        subject.cancel(job)
        assertEquals(listOf("resume"), backends.single().discarded)
        subject.shutDown()
    }

    @Test
    fun `a stop discards every kept partial`() = runTest {
        val backends = mutableListOf<FakeBackend>()
        val subject = downloadManager(backends = backends)
        val first = PartialJob("a", partialEbook)
        val last = PartialJob("z", partialEbook)
        failedWithPartial(subject, first)
        failedWithPartial(subject, last)
        settle { subject.hasResumeData(first) && subject.hasResumeData(last) }

        subject.stop()
        assertEquals(listOf("resume", "resume"), backends.single().discarded)
        subject.shutDown()
    }

    @Test
    fun `a partial that is resumed is not discarded`() = runTest {
        val backends = mutableListOf<FakeBackend>()
        val subject = downloadManager(backends = backends)
        val job = PartialJob("b", partialEbook)
        failedWithPartial(subject, job)
        settle { subject.hasResumeData(job) }

        subject.start(job)
        settle()
        assertTrue(backends.single().discarded.isEmpty())
        subject.shutDown()
    }

    @Test
    fun `launch sweeps the partials, keeping the ones held for a resume`() = runTest {
        val backends = mutableListOf<FakeBackend>()
        val subject = downloadManager(backends = backends)
        val job = PartialJob("b", partialEbook)
        failedWithPartial(subject, job)
        settle { subject.hasResumeData(job) }

        subject.reattach()
        assertEquals(listOf(listOf("resume")), backends.single().swept)
        subject.shutDown()
    }
}
