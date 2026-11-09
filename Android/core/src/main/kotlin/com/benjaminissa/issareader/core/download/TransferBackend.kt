package com.benjaminissa.issareader.core.download

import java.io.File
import java.net.URI

/**
 * What the platform's background transfer service does for [DownloadManager]:
 * the part the Swift client gets from a background `URLSession`.
 *
 * The app implements it on whatever keeps a transfer going while the app is
 * away — a foreground service, WorkManager, the system download manager — and
 * the manager keeps every rule about the transfers it carries: the fence that
 * tells a live transfer from a discarded one, pausing, failures, and judging
 * what arrived. A test implements it with transfers it drives by hand.
 *
 * Every [TransferEvents] callback may arrive on any thread, and for a transfer
 * started in an earlier launch: the backend keeps each transfer's
 * [Transfer.description] for as long as it keeps the transfer, and reports it
 * to whichever manager is listening when it finishes.
 */
interface TransferBackend {
    /**
     * Starts a transfer stamped with [description], resuming from
     * [resumeData] when there is some (what an earlier transfer of the same
     * file handed back when it was paused).
     */
    fun start(request: TransferRequest, description: String, resumeData: ByteArray?): Transfer

    /** The transfers the backend is still carrying, including any started in an earlier launch. */
    suspend fun runningTransfers(): List<Transfer>

    /**
     * Ends this backend for good, cancelling what it carries. It reports back
     * through [TransferEvents.onInvalidated], as it does when it ends unasked.
     */
    fun invalidateAndCancel()
}

/** One file transfer the backend is carrying. */
interface Transfer {
    /**
     * Which job, and which fence, this transfer was started under. Written
     * by the manager when it adopts a transfer from an earlier launch; kept
     * by the backend for as long as it keeps the transfer.
     */
    var description: String?

    /** What the transfer was started with, when the backend still knows it. */
    val request: TransferRequest?

    val bytesReceived: Long

    /** -1 or 0 when the server did not say. */
    val bytesExpected: Long

    val fractionCompleted: Double

    /** The answer, once the server has given one. */
    val response: TransferResponse?

    /** Stops the transfer. The backend reports it as [TransferError.Kind.CANCELLED]. */
    fun cancel()

    /**
     * Stops the transfer, handing back what a later one needs to resume it,
     * or null when it cannot be resumed.
     */
    fun cancelProducingResumeData(onCancelled: (ByteArray?) -> Unit)
}

/** What a transfer asks for. */
data class TransferRequest(
    val url: URI,
    val headers: Map<String, String>,
    /**
     * Whether it may use a metered network. Honoured by the backend, not
     * merely by the manager: Swift's "Wi-Fi only" is
     * `URLRequest.allowsCellularAccess`.
     */
    val allowsMeteredNetwork: Boolean,
)

/** The answer a finished transfer carried. */
data class TransferResponse(val statusCode: Int, val mimeType: String?)

/** Why a transfer ended without its file. */
class TransferError(
    val kind: Kind,
    message: String,
    /** What the backend kept for resuming, when it kept anything. */
    val resumeData: ByteArray? = null,
) : Exception(message) {
    enum class Kind {
        /** Cancelled — by the manager, or by the system reclaiming the transfer. */
        CANCELLED,

        /** The backend could not say: Swift's `NSURLErrorUnknown`. */
        UNKNOWN,

        /** Anything else, with a message worth showing. */
        OTHER,
    }
}

/**
 * The callbacks a backend makes, Swift's `URLSessionDownloadDelegate`.
 * [DownloadManager] implements them; the backend is handed the manager when
 * it is made.
 */
interface TransferEvents {
    fun onProgress(transfer: Transfer, bytesWritten: Long, totalBytesWritten: Long, totalBytesExpected: Long)

    /**
     * The file arrived at [location], which the backend deletes as soon as
     * this returns: the manager judges it and moves it before returning.
     */
    fun onFinishedDownloading(transfer: Transfer, location: File)

    /** The transfer ended; [error] is null when it finished. */
    fun onCompleted(transfer: Transfer, error: TransferError?)

    /** The backend ended — asked to by [TransferBackend.invalidateAndCancel], or not. */
    fun onInvalidated(error: Throwable?)

    /**
     * The credentials to send with a transfer as it runs: the token current
     * then, not the one it was started with. A backend that keeps its requests
     * on disk between runs keeps them without credentials and asks here, so a
     * token is never stored outside the Keystore and a download queued before
     * a sign-in does not run with the token that sign-in replaced. Same origin
     * only; none by default.
     */
    suspend fun credentials(url: URI): Map<String, String> = emptyMap()
}
