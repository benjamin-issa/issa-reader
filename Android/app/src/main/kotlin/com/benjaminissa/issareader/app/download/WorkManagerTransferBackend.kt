package com.benjaminissa.issareader.app.download

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.ServiceInfo
import androidx.core.app.NotificationCompat
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.ForegroundInfo
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import kotlinx.coroutines.flow.first
import com.benjaminissa.issareader.core.IssaJson
import com.benjaminissa.issareader.core.diagnostics.IssaLog
import com.benjaminissa.issareader.core.download.Transfer
import com.benjaminissa.issareader.core.download.TransferBackend
import com.benjaminissa.issareader.core.download.TransferError
import com.benjaminissa.issareader.core.download.TransferEvents
import com.benjaminissa.issareader.core.download.TransferRequest
import com.benjaminissa.issareader.core.download.TransferResponse
import com.benjaminissa.issareader.ui.Symbols
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.File
import java.io.FileOutputStream
import java.net.URI
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Downloads that keep going while the app is away: what the iPhone gets from
 * a background `URLSession`, on WorkManager.
 *
 * Each transfer is one unique work request running [TransferWorker] as a
 * foreground data-sync job, constrained to an unmetered network when the
 * reader asked for Wi-Fi only (`allowsCellularAccess` on iOS). The worker
 * streams with OkHttp to a `.part` file and resumes it with a `Range` request
 * guarded by `If-Range`; a `200` where a `206` was asked for means the file
 * changed, and it starts again.
 *
 * It keeps URLSession's contract with [com.benjaminissa.issareader.core.download.DownloadManager]:
 * a fresh download's body arrives whatever the status, and the manager judges
 * it; a pause hands back resume data; a cancellation is always reported,
 * including of a transfer that never got to run. It goes one better than
 * URLSession in one place: a resumed download that meets an error status
 * keeps the bytes it had and reports the failure with what resuming needs,
 * rather than trading a gigabyte for an error page.
 *
 * Nothing it stores holds a credential. WorkManager keeps each request in its
 * own database, outside the Keystore, so the request is kept without its
 * `Authorization` and `Cookie` headers and the manager is asked for the
 * current ones as the transfer runs ([TransferEvents.credentials]). When Android stops a worker for its own
 * reasons — the Wi-Fi went, a quota ran out — nothing is reported: the work
 * runs again when it may, and picks the partial file up where it stopped, as a
 * background session would.
 *
 * Process-wide: the worker finds the backend the app built through [active],
 * which `IssaApplication` sets before WorkManager can run anything.
 */
class WorkManagerTransferBackend(
    private val context: Context,
    private val client: OkHttpClient,
    private val events: TransferEvents,
    private val workManager: WorkManager = WorkManager.getInstance(context),
    /** Where partial files wait between runs; outside any backup. */
    private val partialDirectory: File = File(context.noBackupFilesDir, "Downloads/partial"),
) : TransferBackend {
    private val transfers = ConcurrentHashMap<UUID, WorkTransfer>()
    @Volatile private var invalidated = false

    init {
        active = this
    }

    override fun start(request: TransferRequest, description: String, resumeData: ByteArray?): Transfer {
        check(!invalidated) { "This transfer backend has been invalidated" }
        val resume = resumeData?.let { runCatching { IssaJson.decodeFromString<ResumeState>(it.decodeToString()) }.getOrNull() }
        val work = OneTimeWorkRequestBuilder<TransferWorker>()
            .setConstraints(
                Constraints.Builder()
                    .setRequiredNetworkType(if (request.allowsMeteredNetwork) NetworkType.CONNECTED else NetworkType.UNMETERED)
                    .build(),
            )
            .setInputData(inputData(request, description, resume))
            .addTag(TAG)
            // The description again, where a later process can read it back
            // without running the work: WorkInfo carries tags, not input data.
            .addTag(DESCRIPTION_TAG + description)
            .build()
        val transfer = WorkTransfer(work.id, description, request)
        transfers[work.id] = transfer
        workManager.enqueueUniqueWork(uniqueName(description), ExistingWorkPolicy.REPLACE, work)
        return transfer
    }

    internal fun inputData(request: TransferRequest, description: String, resume: ResumeState?): Data =
        Data.Builder()
            .putString(KEY_URL, request.url.toString())
            .putString(KEY_HEADERS, IssaJson.encodeToString(withoutCredentials(request.headers)))
            .putBoolean(KEY_METERED, request.allowsMeteredNetwork)
            .putString(KEY_DESCRIPTION, description)
            .putString(KEY_RESUME, resume?.let { IssaJson.encodeToString(it) })
            .build()

    override suspend fun runningTransfers(): List<Transfer> {
        val infos = workManager.getWorkInfosByTagFlow(TAG).first()
        return infos.filter { !it.state.isFinished }.map { info ->
            transfers.getOrPut(info.id) {
                // Started in an earlier launch. Its description is what the
                // manager adopts it by; without it, the transfer's events were
                // dropped and its finished file deleted unseen.
                val description = info.tags.firstOrNull { it.startsWith(DESCRIPTION_TAG) }?.removePrefix(DESCRIPTION_TAG)
                WorkTransfer(info.id, description = description, request = null)
            }
        }
    }

    override fun invalidateAndCancel() {
        invalidated = true
        for (transfer in transfers.values.toList()) transfer.cancel()
        workManager.cancelAllWorkByTag(TAG)
        if (active === this) active = null
        events.onInvalidated(null)
    }

    /** One transfer's state, shared between the manager's handle and the worker running it. */
    inner class WorkTransfer(
        val id: UUID,
        @Volatile override var description: String?,
        @Volatile override var request: TransferRequest?,
    ) : Transfer {
        @Volatile override var bytesReceived: Long = 0
        @Volatile override var bytesExpected: Long = -1
        @Volatile override var response: TransferResponse? = null
        override val fractionCompleted: Double
            get() = if (bytesExpected > 0) bytesReceived.toDouble() / bytesExpected else 0.0

        private val lock = Any()
        private var phase = Phase.PENDING
        private var cancellation: Cancellation? = null

        override fun cancel() = requestCancel(Cancellation.Plain)

        override fun cancelProducingResumeData(onCancelled: (ByteArray?) -> Unit) =
            requestCancel(Cancellation.KeepingPartial(onCancelled))

        private fun requestCancel(how: Cancellation) {
            val wasPending = synchronized(lock) {
                if (phase == Phase.DONE) return
                cancellation = how
                if (phase == Phase.PENDING) {
                    phase = Phase.DONE
                    true
                } else {
                    false
                }
            }
            workManager.cancelWorkById(id)
            // A transfer that never ran has no worker to report it, so it is
            // reported here — the manager must hear of every cancellation, or
            // the row waits at "downloading" for good.
            if (wasPending) finishCancelled(how, partialState())
        }

        /** The worker's claim to run; false when the transfer was cancelled before it started. */
        internal fun begin(): Boolean = synchronized(lock) {
            if (phase != Phase.PENDING) return false
            phase = Phase.RUNNING
            true
        }

        /**
         * The worker was stopped. A cancellation that was asked for is the
         * reason, and ends the transfer; otherwise Android stopped it, and it
         * waits to run again.
         */
        internal fun stopped(): Cancellation? = synchronized(lock) {
            val asked = cancellation
            phase = if (asked != null) Phase.DONE else Phase.PENDING
            asked
        }

        /** The worker's claim to report; the cancellation asked for, if any. */
        internal fun end(): Cancellation? = synchronized(lock) {
            phase = Phase.DONE
            cancellation
        }

        internal fun finishCancelled(how: Cancellation, partial: ResumeState?) {
            when (how) {
                Cancellation.Plain -> {
                    partial?.let { File(it.path).delete() }
                    events.onCompleted(this, TransferError(TransferError.Kind.CANCELLED, "Cancelled"))
                }
                is Cancellation.KeepingPartial -> {
                    val data = partial?.let { IssaJson.encodeToString(it).encodeToByteArray() }
                    how.onCancelled(data)
                    events.onCompleted(this, TransferError(TransferError.Kind.CANCELLED, "Cancelled", data))
                }
            }
        }

        internal fun partialState(): ResumeState? {
            val file = partialFile(id)
            return if (file.exists() && file.length() > 0) ResumeState(file.path, file.length(), validator) else null
        }

        @Volatile internal var validator: String? = null
    }

    internal enum class Phase { PENDING, RUNNING, DONE }

    internal sealed interface Cancellation {
        data object Plain : Cancellation
        class KeepingPartial(val onCancelled: (ByteArray?) -> Unit) : Cancellation
    }

    /** What resuming needs: the partial file, how much of it there is, and what it was a part of. */
    @Serializable
    internal data class ResumeState(val path: String, val length: Long, val validator: String?)

    internal fun partialFile(id: UUID): File = File(partialDirectory, "$id.part")

    internal fun transfer(id: UUID, input: Data): WorkTransfer = transfers.getOrPut(id) {
        WorkTransfer(id, input.getString(KEY_DESCRIPTION), requestFrom(input))
    }.also {
        if (it.request == null) it.request = requestFrom(input)
        if (it.description == null) it.description = input.getString(KEY_DESCRIPTION)
    }

    /** Runs one transfer, on the worker's thread. Returns false when Android stopped it and it should run again. */
    internal suspend fun run(worker: TransferWorker, transfer: WorkTransfer, input: Data): Boolean {
        val request = transfer.request ?: return true
        val resume = input.getString(KEY_RESUME)?.let { runCatching { IssaJson.decodeFromString<ResumeState>(it) }.getOrNull() }
        val partial = partialFile(transfer.id).apply { parentFile?.mkdirs() }
        // Adopt what a paused transfer kept, once.
        if (resume != null && !partial.exists()) {
            File(resume.path).takeIf { it.exists() }?.renameTo(partial)
            transfer.validator = resume.validator
        }
        return try {
            withContext(Dispatchers.IO) { download(worker, transfer, request, partial) }
            val cancellation = transfer.end()
            if (cancellation != null) {
                transfer.finishCancelled(cancellation, transfer.partialState())
            } else {
                events.onFinishedDownloading(transfer, partial)
                partial.delete()
                events.onCompleted(transfer, null)
            }
            true
        } catch (cancelled: CancellationException) {
            val cancellation = transfer.stopped()
            if (cancellation != null) {
                transfer.finishCancelled(cancellation, transfer.partialState())
                true
            } else {
                // Android stopped the worker (constraints, quota): it runs
                // again later, from the partial file, under the same handle,
                // so a pause or cancel the manager sends meanwhile still lands.
                false
            }
        } catch (error: Exception) {
            transfer.end()
            val data = transfer.partialState()?.let { IssaJson.encodeToString(it).encodeToByteArray() }
            IssaLog.warning("Download transfer failed", mapOf("error" to (error.message ?: error.javaClass.simpleName)))
            events.onCompleted(transfer, TransferError(TransferError.Kind.OTHER, error.message ?: "The download failed.", data))
            true
        }
    }

    private suspend fun download(worker: TransferWorker, transfer: WorkTransfer, request: TransferRequest, partial: File) {
        var offset = if (partial.exists()) partial.length() else 0L
        val builder = Request.Builder().url(request.url.toString())
        // The credentials current now, never the ones the request was made
        // with: a sign-in since then replaced them.
        val headers = withoutCredentials(request.headers) + events.credentials(request.url)
        headers.forEach { (name, value) -> builder.header(name, value) }
        if (offset > 0) {
            builder.header("Range", "bytes=$offset-")
            transfer.validator?.let { builder.header("If-Range", it) }
        }
        val call = client.newCall(builder.build())
        call.execute().use { response ->
            transfer.response = TransferResponse(response.code, response.body.contentType()?.let { "${it.type}/${it.subtype}" })
            // A resume that met an error — a proxy restarting, a server down —
            // keeps the partial file and its validator, and fails with what
            // resuming needs: written through, the error page replaced every
            // byte. A 416 is the one exception: the range no longer fits the
            // file, so the partial is no use, and keeping it would only meet
            // the 416 again on every retry.
            if (offset > 0 && response.code != 200 && response.code != 206) {
                if (response.code == 416) partial.delete()
                throw ResumeRefused(response.code)
            }
            transfer.validator = response.header("ETag") ?: response.header("Last-Modified")
            val append = offset > 0 && response.code == 206
            if (!append) offset = 0
            val length = response.body.contentLength()
            transfer.bytesExpected = if (length >= 0) offset + length else -1
            transfer.bytesReceived = offset
            write(worker, transfer, response, partial, append)
        }
    }

    private suspend fun write(worker: TransferWorker, transfer: WorkTransfer, response: Response, partial: File, append: Boolean) {
        val source = response.body.byteStream()
        FileOutputStream(partial, append).use { out ->
            val buffer = ByteArray(64 * 1024)
            var lastReport = 0L
            val throttle = ProgressThrottle()
            while (true) {
                if (worker.isStopped) throw CancellationException("stopped")
                val read = source.read(buffer)
                if (read < 0) break
                out.write(buffer, 0, read)
                transfer.bytesReceived += read
                val now = System.nanoTime()
                if (now - lastReport > 100_000_000L) {
                    lastReport = now
                    events.onProgress(transfer, read.toLong(), transfer.bytesReceived, transfer.bytesExpected)
                }
                // WorkManager's copy is a database write and a notification
                // re-post each time: far less often than the app's own.
                if (throttle.shouldReport(transfer.fractionCompleted, now)) worker.reportProgress(transfer.fractionCompleted)
            }
        }
        events.onProgress(transfer, 0, transfer.bytesReceived, transfer.bytesExpected)
    }

    /** An error status met by a resumed download, which keeps its partial file. */
    internal class ResumeRefused(status: Int) : java.io.IOException("The server returned $status.")

    private fun requestFrom(input: Data): TransferRequest? {
        val url = input.getString(KEY_URL) ?: return null
        val headers = input.getString(KEY_HEADERS)?.let { runCatching { IssaJson.decodeFromString<Map<String, String>>(it) }.getOrNull() }.orEmpty()
        return TransferRequest(URI(url), headers, input.getBoolean(KEY_METERED, true))
    }

    companion object {
        const val TAG = "issa-download"
        internal const val KEY_URL = "url"
        internal const val KEY_HEADERS = "headers"
        internal const val KEY_METERED = "metered"
        internal const val KEY_DESCRIPTION = "description"
        internal const val KEY_RESUME = "resume"
        internal const val DESCRIPTION_TAG = "description:"
        internal const val CHANNEL = "downloads"
        internal const val NOTIFICATION_ID = 0x15A0

        /** The backend the app built, for the worker to report to. */
        @Volatile var active: WorkManagerTransferBackend? = null
            internal set

        /**
         * One work request per book file: the description is `uuid|format|…`,
         * and a second start for the same file replaces the first, as a new
         * download task does on iOS.
         */
        internal fun uniqueName(description: String): String =
            "download:" + description.split('|').take(2).joinToString("|")

        /** A request's headers less the ones that carry a credential. */
        internal fun withoutCredentials(headers: Map<String, String>): Map<String, String> =
            headers.filterKeys { !it.equals("Authorization", ignoreCase = true) && !it.equals("Cookie", ignoreCase = true) }
    }
}

/**
 * When a worker tells WorkManager how far it has got: when the whole percent
 * has moved, and at most once a second. Each report is a write to
 * WorkManager's database and a re-post of the notification, which at the
 * app's own tenth-of-a-second rate ran to ten of each a second for a whole
 * download, and into the notification rate limit.
 */
internal class ProgressThrottle(private val intervalNanos: Long = 1_000_000_000L) {
    private var lastPercent = -1
    private var lastAt: Long? = null

    fun shouldReport(fraction: Double, now: Long): Boolean {
        val percent = (fraction.coerceIn(0.0, 1.0) * 100).toInt()
        if (percent == lastPercent) return false
        val last = lastAt
        if (last != null && now - last < intervalNanos) return false
        lastPercent = percent
        lastAt = now
        return true
    }
}

/** Runs one download for [WorkManagerTransferBackend], in the foreground so it can outlast the app's screen. */
class TransferWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val backend = WorkManagerTransferBackend.active ?: return Result.retry()
        val transfer = backend.transfer(id, inputData)
        if (!transfer.begin()) return Result.success()
        runCatching { setForeground(foregroundInfo(0.0)) }
        return if (backend.run(this, transfer, inputData)) Result.success() else Result.retry()
    }

    override suspend fun getForegroundInfo(): ForegroundInfo = foregroundInfo(0.0)

    internal suspend fun reportProgress(fraction: Double) {
        setProgress(Data.Builder().putDouble("fraction", fraction).build())
        runCatching { setForeground(foregroundInfo(fraction)) }
    }

    private fun foregroundInfo(fraction: Double): ForegroundInfo {
        val manager = applicationContext.getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(WorkManagerTransferBackend.CHANNEL) == null) {
            manager.createNotificationChannel(
                NotificationChannel(WorkManagerTransferBackend.CHANNEL, "Downloads", NotificationManager.IMPORTANCE_LOW),
            )
        }
        val notification = NotificationCompat.Builder(applicationContext, WorkManagerTransferBackend.CHANNEL)
            .setSmallIcon(Symbols.arrowDownCircle)
            .setContentTitle("Downloading")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setProgress(100, (fraction * 100).toInt(), fraction <= 0.0)
            .build()
        return ForegroundInfo(WorkManagerTransferBackend.NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
    }
}
