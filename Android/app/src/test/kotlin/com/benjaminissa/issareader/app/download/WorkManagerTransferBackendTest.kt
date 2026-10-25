package com.benjaminissa.issareader.app.download

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.work.Configuration
import androidx.work.WorkManager
import androidx.work.testing.SynchronousExecutor
import androidx.work.testing.TestListenableWorkerBuilder
import androidx.work.testing.WorkManagerTestInitHelper
import com.benjaminissa.issareader.core.download.Transfer
import com.benjaminissa.issareader.core.download.TransferError
import com.benjaminissa.issareader.core.download.TransferEvents
import com.benjaminissa.issareader.core.download.TransferRequest
import kotlinx.coroutines.runBlocking
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import okhttp3.OkHttpClient
import okio.Buffer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.File
import java.net.URI

/**
 * The WorkManager transport keeps a background URLSession's contract with the
 * download manager: the body arrives whatever the status, a pause hands back
 * what resuming needs, and every cancellation is reported.
 */
@RunWith(RobolectricTestRunner::class)
class WorkManagerTransferBackendTest {
    private val context: Context = ApplicationProvider.getApplicationContext()
    private val server = MockWebServer()
    private val events = RecordingEvents()
    private lateinit var backend: WorkManagerTransferBackend

    @Before
    fun setUp() {
        WorkManagerTestInitHelper.initializeTestWorkManager(
            context,
            Configuration.Builder().setExecutor(SynchronousExecutor()).build(),
        )
        server.start()
        backend = WorkManagerTransferBackend(
            context, OkHttpClient(), events, WorkManager.getInstance(context),
            File(context.cacheDir, "partial-${System.nanoTime()}"),
        )
    }

    @After
    fun tearDown() {
        server.close()
    }

    private fun request(path: String = "/book.epub") =
        TransferRequest(URI(server.url(path).toString()), mapOf("Authorization" to "Bearer t"), allowsMeteredNetwork = true)

    private fun runWorker(transfer: Transfer, description: String, resume: WorkManagerTransferBackend.ResumeState? = null) = runBlocking {
        val id = (transfer as WorkManagerTransferBackend.WorkTransfer).id
        TestListenableWorkerBuilder<TransferWorker>(context)
            .setId(id)
            .setInputData(backend.inputData(transfer.request!!, description, resume))
            .build()
            .doWork()
    }

    @Test
    fun `a finished transfer hands the manager the file, its status and the auth header`() {
        server.enqueue(MockResponse.Builder().code(200).body("PK\u0003\u0004 the book").build())
        val transfer = backend.start(request(), "uuid|ebook|1|1", null)
        runWorker(transfer, "uuid|ebook|1|1")

        assertEquals("PK\u0003\u0004 the book", events.finished.single().second)
        assertEquals(200, transfer.response?.statusCode)
        assertEquals(listOf<TransferError?>(null), events.completed.map { it.second })
        // The manager's token as the transfer ran, not the one it was made with.
        assertEquals("Bearer current", server.takeRequest().headers["Authorization"])
        assertEquals(listOf(URI(server.url("/book.epub").toString())), events.credentialsAskedFor)
    }

    /**
     * WorkManager keeps each request in its own database, which is neither
     * encrypted nor excluded from a device-to-device transfer: a token stored
     * there outlived a sign-out, and a sign-in that replaced it.
     */
    @Test
    fun `no credential is kept in WorkManager's database`() {
        val stored = backend.inputData(
            TransferRequest(
                URI(server.url("/book.epub").toString()),
                mapOf("Authorization" to "Bearer t", "cookie" to "session=s", "Accept" to "application/epub+zip"),
                allowsMeteredNetwork = true,
            ),
            "uuid|ebook|1|1",
            null,
        )
        val headers = stored.getString(WorkManagerTransferBackend.KEY_HEADERS)!!
        assertFalse(headers, "Bearer" in headers)
        assertFalse(headers, "session=s" in headers)
        assertTrue(headers, "application/epub+zip" in headers)
    }

    /**
     * A transfer a new process adopts carries its description, which is what
     * the manager knows it by. Without it the manager dropped every event of
     * the download it had been waiting for, and deleted the finished file.
     */
    @Test
    fun `a transfer adopted after a restart keeps its description`() = runBlocking {
        val transfer = backend.start(request(), "uuid|ebook|1|4", null)
        // The next process: a backend that has never seen the transfer, over
        // the same WorkManager.
        val adopting = WorkManagerTransferBackend(
            context, OkHttpClient(), RecordingEvents(), WorkManager.getInstance(context),
            File(context.cacheDir, "partial-${System.nanoTime()}"),
        )
        val adopted = adopting.runningTransfers().single { (it as WorkManagerTransferBackend.WorkTransfer).id == (transfer as WorkManagerTransferBackend.WorkTransfer).id }
        assertEquals("uuid|ebook|1|4", adopted.description)
    }

    @Test
    fun `an error status still delivers its body, for the manager to judge`() {
        server.enqueue(MockResponse.Builder().code(404).body("{\"message\":\"gone\"}").build())
        val transfer = backend.start(request(), "uuid|ebook|1|1", null)
        runWorker(transfer, "uuid|ebook|1|1")

        assertEquals(404, transfer.response?.statusCode)
        assertEquals("{\"message\":\"gone\"}", events.finished.single().second)
    }

    @Test
    fun `a transfer cancelled before it ran is reported, once, and never downloads`() {
        val transfer = backend.start(request(), "uuid|ebook|1|1", null)
        transfer.cancel()
        runWorker(transfer, "uuid|ebook|1|1")

        assertEquals(TransferError.Kind.CANCELLED, events.completed.single().second?.kind)
        assertTrue(events.finished.isEmpty())
        assertEquals(0, server.requestCount)
    }

    @Test
    fun `a paused transfer resumes with a range request and appends`() {
        val partial = File(context.cacheDir, "kept.part").apply { writeText("first half ") }
        val resume = WorkManagerTransferBackend.ResumeState(partial.path, partial.length(), "\"etag-1\"")
        server.enqueue(MockResponse.Builder().code(206).body("second half").build())
        val data = kotlinx.serialization.json.Json.encodeToString(WorkManagerTransferBackend.ResumeState.serializer(), resume).encodeToByteArray()
        val transfer = backend.start(request(), "uuid|ebook|1|2", data)
        runWorker(transfer, "uuid|ebook|1|2", resume)

        val recorded = server.takeRequest()
        assertEquals("bytes=11-", recorded.headers["Range"])
        assertEquals("\"etag-1\"", recorded.headers["If-Range"])
        assertEquals("first half second half", events.finished.single().second)
    }

    @Test
    fun `a 200 where a range was asked for starts the file again`() {
        val partial = File(context.cacheDir, "stale.part").apply { writeText("old bytes ") }
        val resume = WorkManagerTransferBackend.ResumeState(partial.path, partial.length(), "\"etag-0\"")
        server.enqueue(MockResponse.Builder().code(200).body("whole new file").build())
        val data = kotlinx.serialization.json.Json.encodeToString(WorkManagerTransferBackend.ResumeState.serializer(), resume).encodeToByteArray()
        val transfer = backend.start(request(), "uuid|ebook|1|3", data)
        runWorker(transfer, "uuid|ebook|1|3", resume)

        assertEquals("whole new file", events.finished.single().second)
    }

    @Test
    fun `invalidating ends the backend and says so`() {
        backend.invalidateAndCancel()
        assertTrue(events.invalidated)
        assertNull(WorkManagerTransferBackend.active)
    }

    private class RecordingEvents : TransferEvents {
        val finished = mutableListOf<Pair<Transfer, String>>()
        val completed = mutableListOf<Pair<Transfer, TransferError?>>()
        val credentialsAskedFor = mutableListOf<URI>()
        var invalidated = false

        override suspend fun credentials(url: URI): Map<String, String> {
            credentialsAskedFor += url
            return mapOf("Authorization" to "Bearer current")
        }

        override fun onProgress(transfer: Transfer, bytesWritten: Long, totalBytesWritten: Long, totalBytesExpected: Long) = Unit

        override fun onFinishedDownloading(transfer: Transfer, location: File) {
            finished += transfer to location.readText()
        }

        override fun onCompleted(transfer: Transfer, error: TransferError?) {
            completed += transfer to error
        }

        override fun onInvalidated(error: Throwable?) {
            invalidated = true
        }
    }
}
