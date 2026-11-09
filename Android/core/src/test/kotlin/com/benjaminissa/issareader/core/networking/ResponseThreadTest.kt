package com.benjaminissa.issareader.core.networking

import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import okhttp3.MediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody
import okio.Buffer
import okio.BufferedSource
import okio.ForwardingSource
import okio.buffer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.net.URI
import java.nio.file.Files
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * No response is closed on the thread that asked for it.
 *
 * Closing a response with its body unread reads the rest of it off the socket,
 * and if the caller is on Android's main thread that is a
 * `NetworkOnMainThreadException`, which kills the app: leaving a book's page
 * while its requests were landing did, and did it more readily in E-Ink mode,
 * where a screen goes at once rather than 300 ms later. The JVM has no such
 * check, so here [CALLER] stands in for the main thread and each body records
 * who closed it.
 */
class ResponseThreadTest {
    private val caller = Executors.newSingleThreadExecutor { Thread(it, CALLER) }
    private val onCaller = caller.asCoroutineDispatcher()
    private val closedOn = Collections.synchronizedList(ArrayList<String>())
    private val closed = CountDownLatch(1)

    @After
    fun tearDown() {
        caller.shutdownNow()
    }

    private inner class WatchedBody : ResponseBody() {
        private val text = Buffer().writeUtf8("{}")
        private val watched = object : ForwardingSource(text) {
            override fun close() {
                closedOn += Thread.currentThread().name
                closed.countDown()
                super.close()
            }
        }.buffer()

        override fun contentType(): MediaType? = null

        override fun contentLength(): Long = -1

        override fun source(): BufferedSource = watched
    }

    private fun client(status: Int = 200, location: String? = null, beforeAnswering: () -> Unit = {}): OkHttpClient =
        OkHttpClient.Builder().addInterceptor { chain ->
            beforeAnswering()
            Response.Builder()
                .request(chain.request())
                .protocol(Protocol.HTTP_1_1)
                .code(if (chain.request().url.encodedPath.endsWith("after")) 200 else status)
                .message("")
                .apply { if (location != null) header("Location", location) }
                .body(WatchedBody())
                .build()
        }.build()

    private fun api(http: OkHttpClient) = ApiClient(URI("https://books.test"), NoToken, http)

    private fun assertOffTheCaller() {
        assertTrue("nothing closed the response", closed.await(5, TimeUnit.SECONDS))
        // A prefix: coroutines' debug mode adds the coroutine to a thread's name.
        for (thread in closedOn) assertFalse("closed on $thread", thread.startsWith(CALLER))
    }

    @Test
    fun `a request's response`() = runBlocking {
        withContext(onCaller) { api(client()).probeStatus("api/v2/user") }
        assertOffTheCaller()
    }

    @Test
    fun `a body that was never read, from a refused download`() = runBlocking {
        val destination = File(Files.createTempDirectory("response-thread").toFile(), "book.epub")
        val refused = runCatching { withContext(onCaller) { api(client(status = 500)).download("api/v2/books", destination = destination) } }
        assertTrue("it should have been refused: $refused", refused.exceptionOrNull() is StorytellerError)
        assertOffTheCaller()
    }

    @Test
    fun `a redirect's own response, which is dropped unread`() = runBlocking {
        val status = withContext(onCaller) { api(client(status = 302, location = "/after")).probeStatus("before") }
        assertEquals(200, status)
        assertEquals("the redirect and the answer it led to", 2, closedOn.size)
        assertOffTheCaller()
    }

    /** The crash itself: the caller goes away while the answer is on its way. */
    @Test
    fun `an answer landing after the caller has gone`() = runBlocking {
        val asked = CountDownLatch(1)
        val release = CountDownLatch(1)
        val http = client {
            asked.countDown()
            release.await(5, TimeUnit.SECONDS)
        }
        val caller = launch(onCaller, start = CoroutineStart.UNDISPATCHED) { api(http).probeStatus("api/v2/user") }
        assertTrue(asked.await(5, TimeUnit.SECONDS))
        caller.cancelAndJoin()
        release.countDown()
        assertOffTheCaller()
    }

    private object NoToken : TokenProviding {
        override suspend fun currentToken(): String? = null

        override suspend fun invalidate() = Unit
    }

    private companion object {
        const val CALLER = "the caller"
    }
}
