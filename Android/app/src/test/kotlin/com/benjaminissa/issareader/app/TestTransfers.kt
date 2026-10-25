package com.benjaminissa.issareader.app

import com.benjaminissa.issareader.core.KeyValueStore
import com.benjaminissa.issareader.core.download.DownloadManager
import com.benjaminissa.issareader.core.download.Transfer
import com.benjaminissa.issareader.core.download.TransferBackend
import com.benjaminissa.issareader.core.download.TransferError
import com.benjaminissa.issareader.core.download.TransferEvents
import com.benjaminissa.issareader.core.download.TransferRequest
import com.benjaminissa.issareader.core.download.TransferResponse
import com.benjaminissa.issareader.core.networking.TokenProviding
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import java.io.File
import java.net.URI

/**
 * A transfer that never reaches a network: it waits, as a real transfer to an
 * unroutable address does, until a test finishes it or something cancels it.
 * Its cancellation is reported through the backend's events, a turn later, as
 * a real backend's is.
 */
class HeldTransfer(
    override var description: String?,
    override val request: TransferRequest?,
    private val events: TransferEvents,
    private val post: (() -> Unit) -> Unit,
) : Transfer {
    enum class State { RUNNING, CANCELING, COMPLETED }

    @Volatile var state = State.RUNNING
        private set

    override val bytesReceived: Long = 0
    override val bytesExpected: Long = -1
    override val fractionCompleted: Double = 0.0
    override var response: TransferResponse? = null
        private set

    override fun cancel() {
        if (state != State.RUNNING) return
        state = State.CANCELING
        post {
            events.onCompleted(this, TransferError(TransferError.Kind.CANCELLED, "cancelled"))
            state = State.COMPLETED
        }
    }

    override fun cancelProducingResumeData(onCancelled: (ByteArray?) -> Unit) {
        if (state != State.RUNNING) return
        state = State.CANCELING
        val resume = "resume".encodeToByteArray()
        post {
            onCancelled(resume)
            events.onCompleted(this, TransferError(TransferError.Kind.CANCELLED, "cancelled", resume))
            state = State.COMPLETED
        }
    }

    /** The file arriving, as the backend would hand it over, then the transfer ending. */
    fun finish(file: File, mimeType: String = "application/epub+zip") {
        if (state != State.RUNNING) return
        response = TransferResponse(200, mimeType)
        post {
            events.onFinishedDownloading(this, file)
            events.onCompleted(this, null)
            state = State.COMPLETED
        }
    }
}

/** A backend whose transfers are [HeldTransfer]s, with its callbacks posted to [queue]. */
class HeldTransfers(private val events: TransferEvents, private val queue: CoroutineScope) : TransferBackend {
    val started = mutableListOf<HeldTransfer>()
    var invalidated = false
        private set

    private fun post(block: () -> Unit) {
        queue.launch { block() }
    }

    override fun start(request: TransferRequest, description: String, resumeData: ByteArray?): Transfer =
        HeldTransfer(description, request, events, ::post).also { started.add(it) }

    override suspend fun runningTransfers(): List<Transfer> = started.filter { it.state == HeldTransfer.State.RUNNING }

    override fun invalidateAndCancel() {
        invalidated = true
        started.forEach { it.cancel() }
        post { events.onInvalidated(null) }
    }
}

/**
 * A download manager on [HeldTransfers], its state on the suites' main thread
 * and its files under [directory].
 */
fun testDownloads(
    baseUrl: URI,
    tokens: TokenProviding,
    scope: CoroutineScope,
    directory: File,
    preferences: KeyValueStore = SharedFixtures.scratchDefaults(),
    backends: MutableList<HeldTransfers>? = null,
): DownloadManager = DownloadManager(
    baseUrl = baseUrl,
    tokens = tokens,
    preferences = preferences,
    fenceStore = null,
    dispatcher = TestMain.dispatcher,
    destinationFor = { job -> File(directory, "${job.bookUuid}-${job.format.rawValue}") },
    makeBackend = { events -> HeldTransfers(events, scope).also { backends?.add(it) } },
)
