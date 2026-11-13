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
import okhttp3.ResponseBody.Companion.asResponseBody
import okio.Buffer
import okio.buffer
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
 * download manager: a fresh download's body arrives whatever the status, a
 * pause hands back what resuming needs, and every cancellation is reported.
 */
@RunWith(RobolectricTestRunner::class)
class WorkManagerTransferBackendTest {
    private val context: Context = ApplicationProvider.getApplicationContext()
    private val server = MockWebServer()
    private val events = RecordingEvents()
    private lateinit var backend: WorkManagerTransferBackend
    private val partials = File(context.cacheDir, "partial-${System.nanoTime()}")

    @Before
    fun setUp() {
        WorkManagerTestInitHelper.initializeTestWorkManager(
            context,
            Configuration.Builder().setExecutor(SynchronousExecutor()).build(),
        )
        server.start()
        backend = WorkManagerTransferBackend(
            context, OkHttpClient(), events, WorkManager.getInstance(context),
            partials,
        )
    }

    @After
    fun tearDown() {
        server.close()
    }

    private fun request(path: String = "/book.epub") =
        TransferRequest(URI(server.url(path).toString()), mapOf("Authorization" to "Bearer t"), allowsMeteredNetwork = true)

    private fun runWorker(transfer: Transfer, description: String, resume: WorkManagerTransferBackend.ResumeState? = null, backend: WorkManagerTransferBackend = this.backend) = runBlocking {
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
    fun `a resume that meets an error keeps every byte it had, and what resuming needs`() {
        val partial = File(context.cacheDir, "kept-${System.nanoTime()}.part").apply { writeText("first half ") }
        val resume = WorkManagerTransferBackend.ResumeState(partial.path, partial.length(), "\"etag-1\"")
        server.enqueue(MockResponse.Builder().code(503).body("<html>try again later</html>").build())
        val data = kotlinx.serialization.json.Json.encodeToString(WorkManagerTransferBackend.ResumeState.serializer(), resume).encodeToByteArray()
        val transfer = backend.start(request(), "uuid|ebook|1|5", data)
        runWorker(transfer, "uuid|ebook|1|5", resume)

        assertTrue("an error page is never handed over as the book", events.finished.isEmpty())
        val error = events.completed.single().second!!
        assertEquals(TransferError.Kind.OTHER, error.kind)
        assertEquals("The server returned 503.", error.message)
        val kept = kotlinx.serialization.json.Json.decodeFromString(
            WorkManagerTransferBackend.ResumeState.serializer(), error.resumeData!!.decodeToString(),
        )
        assertEquals("first half ", File(kept.path).readText())
        assertEquals(11L, kept.length)
        assertEquals("\"etag-1\"", kept.validator)
    }

    @Test
    fun `a resume refused as out of range starts again from nothing`() {
        val partial = File(context.cacheDir, "whole-${System.nanoTime()}.part").apply { writeText("all of it") }
        val resume = WorkManagerTransferBackend.ResumeState(partial.path, partial.length(), "\"etag-1\"")
        server.enqueue(MockResponse.Builder().code(416).build())
        val data = kotlinx.serialization.json.Json.encodeToString(WorkManagerTransferBackend.ResumeState.serializer(), resume).encodeToByteArray()
        val transfer = backend.start(request(), "uuid|ebook|1|6", data)
        runWorker(transfer, "uuid|ebook|1|6", resume)

        val error = events.completed.single().second!!
        assertEquals("The server returned 416.", error.message)
        assertNull("a range the file no longer has would meet the 416 again", error.resumeData)
    }

    @Test
    fun `WorkManager hears of progress when the percent moves, at most once a second`() {
        val throttle = ProgressThrottle()
        val second = 1_000_000_000L
        assertTrue(throttle.shouldReport(0.0, 0))
        // Ten reports a second, as the app's own run: the same percent, or
        // inside the second, are dropped.
        assertFalse(throttle.shouldReport(0.001, second / 10))
        assertFalse(throttle.shouldReport(0.05, second / 2))
        assertTrue(throttle.shouldReport(0.05, second))
        assertFalse(throttle.shouldReport(0.059, 3 * second))
        assertTrue(throttle.shouldReport(0.06, 3 * second))

        // A hundred-second download at the app's rate of ten a second: about
        // one report a second (a percent that rounds down lands a tick late),
        // where every tick was one.
        val fresh = ProgressThrottle()
        val reports = (0..1_000).count { tick -> fresh.shouldReport(tick / 1_000.0, tick * second / 10) }
        assertTrue("$reports reports", reports in 90..101)
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

    /**
     * A pause cannot interrupt a read blocked on the socket, so the read ends
     * later, in an I/O error. That is the pause landing, not a failed download:
     * the manager must hear a cancellation, with what resuming needs.
     */
    @Test
    fun `a read that fails after a pause was asked for is the pause, not a failure`() {
        // A body that gives its first chunk and then breaks, as a dead socket does.
        val breaking = OkHttpClient.Builder().addInterceptor { chain ->
            val chunk = ByteArray(1024) { 1 }
            val source = object : okio.Source {
                var gave = false
                override fun read(sink: Buffer, byteCount: Long): Long {
                    if (gave) throw java.io.IOException("unexpected end of stream")
                    gave = true
                    sink.write(chunk)
                    return chunk.size.toLong()
                }
                override fun timeout() = okio.Timeout.NONE
                override fun close() = Unit
            }
            okhttp3.Response.Builder().request(chain.request()).protocol(okhttp3.Protocol.HTTP_1_1).code(200).message("OK")
                .body(source.buffer().asResponseBody(null, -1)).build()
        }.build()
        val backend = WorkManagerTransferBackend(context, breaking, events, WorkManager.getInstance(context), partials)
        var kept: ByteArray? = null
        var asked = false
        val transfer = backend.start(request(), "uuid|ebook|1|9", null)
        events.onProgressHook = { running ->
            if (!asked) {
                asked = true
                running.cancelProducingResumeData { kept = it }
            }
        }
        runWorker(transfer, "uuid|ebook|1|9", backend = backend)

        val error = events.completed.single().second!!
        assertEquals(TransferError.Kind.CANCELLED, error.kind)
        assertTrue("the partial is handed back for the resume", error.resumeData != null)
        assertTrue(kept != null)
        assertTrue(events.finished.isEmpty())
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

    private fun resumeData(file: File) = kotlinx.serialization.json.Json.encodeToString(
        WorkManagerTransferBackend.ResumeState.serializer(),
        WorkManagerTransferBackend.ResumeState(file.path, file.length(), null),
    ).encodeToByteArray()

    private fun orphan(name: String = "${java.util.UUID.randomUUID()}.part") =
        File(partials, name).apply { parentFile!!.mkdirs(); writeText("half a book") }

    @Test
    fun `a partial handed back and then cancelled is deleted`() {
        val file = orphan()
        backend.discardResumeData(resumeData(file))
        assertFalse(file.exists())
    }

    @Test
    fun `discarding never reaches a file outside the partial directory`() {
        val elsewhere = File(context.cacheDir, "elsewhere-${System.nanoTime()}.part").apply { writeText("x") }
        backend.discardResumeData(resumeData(elsewhere))
        assertTrue(elsewhere.exists())
    }

    @Test
    fun `a transfer resumed from a kept partial owns it under its own id`() {
        val kept = orphan()
        val transfer = backend.start(request(), "uuid|ebook|1|7", resumeData(kept)) as WorkManagerTransferBackend.WorkTransfer
        assertFalse(kept.exists())
        assertEquals("half a book", backend.partialFile(transfer.id).readText())
    }

    @Test
    fun `the launch sweep deletes partials no one owns and keeps the owned ones`() = runBlocking {
        val stranded = orphan()
        val held = orphan()
        val queued = backend.start(request(), "uuid|ebook|1|8", resumeData(orphan())) as WorkManagerTransferBackend.WorkTransfer
        val queuedFile = backend.partialFile(queued.id)

        backend.sweepPartials(listOf(resumeData(held)))

        assertFalse("a partial nothing owns is the space the user lost", stranded.exists())
        assertTrue("a paused download that will resume keeps its partial", held.exists())
        assertTrue("work waiting to run keeps the partial it will resume", queuedFile.exists())
    }

    /** A backend that has never seen the work, over the same WorkManager and the same partials: the next launch. */
    private fun nextProcess() = WorkManagerTransferBackend(
        context, OkHttpClient(), RecordingEvents(), WorkManager.getInstance(context), partials,
    )

    /**
     * Work a 1.7.0 install queued for a paused download it resumed: its bytes
     * are at the old id's name, which only its input data says. The first
     * launch of the next release must not take them for an orphan's.
     */
    @Test
    fun `the launch sweep of a new process keeps the partial queued work from an older release names`() = runBlocking {
        val named = orphan()
        val stranded = orphan()
        val work = androidx.work.OneTimeWorkRequestBuilder<TransferWorker>()
            .setConstraints(androidx.work.Constraints.Builder().setRequiredNetworkType(androidx.work.NetworkType.CONNECTED).build())
            .setInputData(
                backend.inputData(
                    request(), "uuid|ebook|1|9",
                    WorkManagerTransferBackend.ResumeState(named.path, named.length(), null),
                ),
            )
            .addTag(WorkManagerTransferBackend.TAG)
            .addTag(WorkManagerTransferBackend.DESCRIPTION_TAG + "uuid|ebook|1|9")
            .build()
        WorkManager.getInstance(context).enqueue(work).result.get()

        nextProcess().sweepPartials(emptyList())

        assertTrue("the partial the queued work will resume was deleted", named.exists())
    }

    /** The same for work this release queued: the sweep of a new process sees the partial by what the work says. */
    @Test
    fun `the launch sweep of a new process keeps the partial work from this release names`() = runBlocking {
        val kept = orphan()
        val stranded = orphan()
        val transfer = backend.start(request(), "uuid|ebook|1|10", resumeData(kept)) as WorkManagerTransferBackend.WorkTransfer

        nextProcess().sweepPartials(emptyList())

        assertTrue(backend.partialFile(transfer.id).exists())
        assertFalse("a partial nothing owns survived", stranded.exists())
    }

    /** A worker's failure ends the transfer in the same step that decides it: a pause after that is no cancellation. */
    @Test
    fun `a failed transfer is over, so a later cancel reports nothing`() {
        val transfer = backend.start(request(), "uuid|ebook|1|11", null) as WorkManagerTransferBackend.WorkTransfer
        assertTrue(transfer.begin())

        assertEquals(WorkManagerTransferBackend.Settlement.Failed, transfer.settleError(androidStopped = false))
        transfer.cancel()

        assertTrue("a cancel after the failure was reported as one", events.completed.isEmpty())
    }

    /** Android stopping the worker leaves the transfer to run again, and a cancel meanwhile still lands. */
    @Test
    fun `a worker Android stopped waits to run again`() {
        val transfer = backend.start(request(), "uuid|ebook|1|12", null) as WorkManagerTransferBackend.WorkTransfer
        assertTrue(transfer.begin())

        assertEquals(WorkManagerTransferBackend.Settlement.RunAgain, transfer.settleError(androidStopped = true))
        assertTrue("it could not run again", transfer.begin())
    }

    /** A cancellation asked for before the error is the reason, whatever else happened. */
    @Test
    fun `an error after a cancel is that cancel`() {
        val transfer = backend.start(request(), "uuid|ebook|1|13", null) as WorkManagerTransferBackend.WorkTransfer
        assertTrue(transfer.begin())
        transfer.cancel()

        val settled = transfer.settleError(androidStopped = true)

        assertTrue(settled is WorkManagerTransferBackend.Settlement.Cancelled)
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

        var onProgressHook: ((Transfer) -> Unit)? = null

        override fun onProgress(transfer: Transfer, bytesWritten: Long, totalBytesWritten: Long, totalBytesExpected: Long) {
            onProgressHook?.invoke(transfer)
        }

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
