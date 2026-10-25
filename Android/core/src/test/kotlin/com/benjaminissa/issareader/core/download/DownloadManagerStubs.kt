package com.benjaminissa.issareader.core.download

import com.benjaminissa.issareader.core.InMemoryKeyValueStore
import com.benjaminissa.issareader.core.KeyValueStore
import com.benjaminissa.issareader.core.Stub
import com.benjaminissa.issareader.core.networking.TokenProviding
import com.benjaminissa.issareader.core.stubHttp
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import java.io.File
import java.net.ConnectException
import java.net.URI
import java.util.UUID

/**
 * What a file server answers, by the host a request names: a zip's first
 * bytes, a sign-in page, an API's JSON, an audio file — always with a 200,
 * which is the case a download used to take at its word. Ported from
 * `DownloadManagerStubs.swift`.
 */
internal enum class DownloadAnswer(val contentType: String) {
    EPUB("application/epub+zip"),
    HTML("text/html; charset=utf-8"),
    JSON("application/json"),
    AUDIO("audio/mp4"),
    ;

    /** The type alone, as a transfer's response names it. */
    val mimeType: String get() = contentType.substringBefore(';').trim()

    val body: ByteArray
        get() = when (this) {
            EPUB -> zipHead
            HTML -> page
            JSON -> """{"message":"Not signed in"}""".encodeToByteArray()
            // The first box of an MP4: whatever an audiobook is, it is not a zip.
            AUDIO -> byteArrayOf(0x00, 0x00, 0x00, 0x20) + "ftypM4A ".encodeToByteArray()
        }

    companion object {
        /** How every EPUB begins: a zip's local file header, then the `mimetype` entry the format requires first. */
        val zipHead: ByteArray = byteArrayOf(0x50, 0x4B, 0x03, 0x04) + "mimetypeapplication/epub+zip".encodeToByteArray()

        /** What a proxy or a captive portal sends in place of the file. */
        val page: ByteArray = "<!doctype html><html><body>Sign in to continue</body></html>".encodeToByteArray()

        /** The server to point a client at for one kind of answer. */
        fun base(answer: DownloadAnswer): URI = URI("http://${answer.name.lowercase()}.download.test")

        /** A client every request of which this answers, and never the network. */
        val http = stubHttp { request ->
            val name = request.url.host.substringBefore('.')
            val answer = entries.firstOrNull { it.name.lowercase() == name }
                ?: return@stubHttp Stub.Fail(ConnectException("cannot find host"))
            Stub.Answer(200, answer.body, mapOf("Content-Type" to answer.contentType))
        }

        /**
         * A transfer that has run to completion, so it carries a real
         * response — the thing a finished transfer is judged by.
         */
        fun finishedTask(answer: DownloadAnswer): FakeTransfer =
            FakeTransfer(description = null, response = TransferResponse(200, answer.mimeType))

        /** Writes what a transfer of this kind leaves in the backend's temporary file. */
        fun arrivedFile(answer: DownloadAnswer, directory: File): File {
            directory.mkdirs()
            val file = File(directory, "arrived-${UUID.randomUUID()}.tmp")
            file.writeBytes(answer.body)
            return file
        }
    }
}

/**
 * A transfer a test holds. Made by [FakeBackend], it reports its own
 * cancellation through the backend's events, later, as a real backend does;
 * made by hand — Swift's tasks from `URLSession.shared` — it reports nothing,
 * and a test delivers its callbacks itself.
 */
internal class FakeTransfer(
    override var description: String?,
    override val request: TransferRequest? = null,
    override val response: TransferResponse? = null,
    private val events: TransferEvents? = null,
    private val post: ((() -> Unit) -> Unit)? = null,
) : Transfer {
    enum class State { RUNNING, CANCELING, COMPLETED }

    @Volatile var state = State.RUNNING
        private set

    override val bytesReceived: Long = 0
    override val bytesExpected: Long = -1
    override val fractionCompleted: Double = 0.0

    private fun deliver(block: () -> Unit) {
        val post = post
        if (post == null) state = State.COMPLETED else post(block)
    }

    override fun cancel() {
        if (state != State.RUNNING) return
        state = State.CANCELING
        deliver {
            events?.onCompleted(this, TransferError(TransferError.Kind.CANCELLED, "cancelled"))
            state = State.COMPLETED
        }
    }

    override fun cancelProducingResumeData(onCancelled: (ByteArray?) -> Unit) {
        if (state != State.RUNNING) return
        state = State.CANCELING
        val resume = "resume".encodeToByteArray()
        deliver {
            onCancelled(resume)
            events?.onCompleted(this, TransferError(TransferError.Kind.CANCELLED, "cancelled", resume))
            state = State.COMPLETED
        }
    }
}

/**
 * A backend whose transfers never reach a network: they wait, as a real
 * transfer to an unroutable address does, until a test finishes them or
 * something cancels them. Its own callbacks arrive on [queue], a turn after
 * whatever caused them — as a real backend's arrive on its own thread.
 */
internal class FakeBackend(private val events: TransferEvents, private val queue: CoroutineScope) : TransferBackend {
    val started = mutableListOf<FakeTransfer>()
    var invalidated = false
        private set

    private fun post(block: () -> Unit) {
        queue.launch { block() }
    }

    override fun start(request: TransferRequest, description: String, resumeData: ByteArray?): Transfer =
        FakeTransfer(description, request, events = events, post = ::post).also { started.add(it) }

    override suspend fun runningTransfers(): List<Transfer> = started.filter { it.state == FakeTransfer.State.RUNNING }

    override fun invalidateAndCancel() {
        invalidated = true
        started.forEach { it.cancel() }
        post { events.onInvalidated(null) }
    }
}

internal class StubTokens : TokenProviding {
    override suspend fun currentToken(): String = "test-token"
    override suspend fun invalidate() {}
}

/**
 * A server address no request reaches. TEST-NET-1 (RFC 5737) is reserved for
 * documentation and routes nowhere; here no request is ever sent, but the
 * address is the Swift suite's.
 */
internal val unreachableServer = URI("http://192.0.2.1")

/**
 * A manager on a [FakeBackend], its state and the backend's callbacks both on
 * the test's scheduler — the main actor and the delegate queue of the Swift
 * suite — so a test decides when each lands.
 */
internal fun TestScope.downloadManager(
    tokens: TokenProviding = StubTokens(),
    fenceStore: KeyValueStore? = null,
    destinationFor: (DownloadManager.Job) -> File = { File("/dev/null") },
): DownloadManager {
    val backendQueue = CoroutineScope(StandardTestDispatcher(testScheduler))
    return DownloadManager(
        baseUrl = unreachableServer,
        tokens = tokens,
        preferences = InMemoryKeyValueStore(),
        fenceStore = fenceStore,
        dispatcher = StandardTestDispatcher(testScheduler),
        destinationFor = destinationFor,
        makeBackend = { events -> FakeBackend(events, backendQueue) },
    )
}

/**
 * Lets every hop and callback that is due land, until [condition] holds: the
 * Swift suite's `settle`, and its `Task.yield()` loops.
 */
@OptIn(ExperimentalCoroutinesApi::class)
internal fun TestScope.settle(condition: () -> Boolean = { false }) {
    for (turn in 0 until 5) {
        advanceUntilIdle()
        if (condition()) return
    }
}
