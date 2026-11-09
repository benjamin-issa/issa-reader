package com.benjaminissa.issareader.core.download

import com.benjaminissa.issareader.core.IssaJson
import com.benjaminissa.issareader.core.KeyValueStore
import com.benjaminissa.issareader.core.StorageRoot
import com.benjaminissa.issareader.core.diagnostics.IssaLog
import com.benjaminissa.issareader.core.networking.Endpoint
import com.benjaminissa.issareader.core.networking.TokenProviding
import com.benjaminissa.issareader.core.networking.appendingPath
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import java.io.File
import java.io.IOException
import java.net.URI
import java.nio.file.Files
import java.util.concurrent.atomic.AtomicBoolean

/**
 * How much room is left on the volume a path is on.
 *
 * Asked of the nearest directory that exists: the root may not have been
 * created yet, and the volume it will be on is the one its parent is on.
 */
object DiskSpace {
    fun available(at: File = StorageRoot.url): Long? {
        var existing: File? = at.absoluteFile
        while (existing != null && !existing.exists()) existing = existing.parentFile
        val directory = existing ?: return null
        return runCatching { Files.getFileStore(directory.toPath()).usableSpace }.getOrNull()
    }
}

/**
 * Downloads books, and keeps downloading them when the app is not running.
 *
 * Streams to disk through a [TransferBackend] — on iOS a background
 * `URLSession` — so a download survives the app being suspended or killed,
 * and a five-hour audiobook costs no more memory than a page of text.
 *
 * Swift's `@MainActor @Observable` class. Its state — [states], the transfers
 * it tracks, what it holds for resuming — is confined to [dispatcher], which
 * the app makes its main dispatcher: call it from there, as Swift calls it on
 * the main actor. The backend's callbacks arrive on any thread; each does the
 * part that cannot wait (judging the fence, moving a finished file) where it
 * arrives and hops to [dispatcher] for the rest.
 *
 * @param preferences where "Wi-Fi only" is kept: the app's own preferences.
 * @param fenceStore where the fence is kept between launches: the app's
 *   preferences unless a caller — a test — wants it kept in memory (null) or
 *   somewhere of its own.
 * @param destinationFor where a finished job's file goes. Called on the
 *   backend's thread, the moment a transfer finishes.
 * @param makeBackend builds the backend this manager drives, handed the
 *   manager to report to. Called once, and once more if the backend ends
 *   without being asked to.
 */
class DownloadManager(
    baseUrl: URI,
    tokens: TokenProviding,
    private val preferences: KeyValueStore,
    private val fenceStore: KeyValueStore? = preferences,
    private val dispatcher: CoroutineDispatcher,
    private val destinationFor: (Job) -> File,
    private val makeBackend: (TransferEvents) -> TransferBackend,
) : TransferEvents {
    sealed interface State {
        data object Queued : State
        data class Downloading(val fractionCompleted: Double, val bytesWritten: Long, val totalBytes: Long) : State
        data class Paused(val fractionCompleted: Double) : State
        data object Finished : State
        data class Failed(val reason: String) : State

        val fraction: Double
            get() = when (this) {
                Queued -> 0.0
                is Downloading -> fractionCompleted
                is Paused -> fractionCompleted
                Finished -> 1.0
                is Failed -> 0.0
            }

        val isFailure: Boolean get() = this is Failed

        /**
         * True when the total size is unknown, so a bar should be
         * indeterminate rather than sitting at zero — which is indisputably
         * what a stalled download also looks like.
         */
        val isIndeterminate: Boolean get() = this is Downloading && totalBytes <= 0

        val isActive: Boolean get() = this == Queued || this is Downloading
    }

    /** Identifies one download: a book in one edition. */
    data class Job(val bookUuid: String, val format: BookContentService.Format)

    private val mutableStates = MutableStateFlow<Map<Job, State>>(emptyMap())

    /** Every job with a state, for the screens that draw them. */
    val states: StateFlow<Map<Job, State>> = mutableStates.asStateFlow()

    /** Only download over Wi-Fi. Honoured by the backend, not merely by us, and set per request. */
    var wifiOnly: Boolean = preferences.getBoolean(WIFI_ONLY_KEY)
        set(value) {
            field = value
            preferences.putBoolean(WIFI_ONLY_KEY, value)
        }

    var onFinished: ((Job) -> Unit)? = null

    @Volatile private var baseUrl: URI = baseUrl

    @Volatile private var tokens: TokenProviding = tokens

    /**
     * How many times the backend has been rebuilt after it ended unasked.
     * Once: a repeat means it is being fought over, and rebuilding again would
     * only feed the fight.
     */
    private var rebuilds = 0

    private val scope = CoroutineScope(SupervisorJob() + dispatcher)
    private var backend: TransferBackend
    private val tasks = mutableMapOf<Job, Transfer>()
    private val resumeData = mutableMapOf<Job, ByteArray>()

    /**
     * Jobs the app itself paused. A pause cancels the transfer, and a
     * cancellation is otherwise indistinguishable from the system killing one
     * — so without this every cancellation had to be ignored, which left a
     * killed download showing "downloading" forever with every button dead.
     */
    private val pausing = mutableSetOf<Job>()

    /**
     * How many pauses' own callbacks — the resume data a paused transfer
     * hands back — have reached [dispatcher], fenced or not. For the tests
     * that have to know a callback has come and gone.
     */
    internal var pauseCallbacksDelivered = 0
        private set

    /**
     * Set when the backend has been torn down, so late callbacks from it
     * cannot write state the app is no longer showing. Atomic because the
     * finished-file callback consults it on the backend's thread, before a
     * move that cannot wait for a hop.
     */
    private val shutDownFlag = AtomicBoolean(false)
    private val isShutDown: Boolean get() = shutDownFlag.get()

    /**
     * Which [stop] and which [cancel] a transfer belongs after: stamped into
     * every transfer's description, and judged on the backend's thread before
     * anything a callback does.
     *
     * A generation rather than a set of discarded jobs, because the next
     * account may start the very same job before the old transfer's
     * cancellation has reported back. Per job as well, because one cancel must
     * not strand every other live transfer, which all carry the global number;
     * a restart of a job takes the new number, so the old transfer and the new
     * one are still told apart. Kept across launches in [fenceStore], because
     * a transfer stamped in one process can finish — and be reported — in the
     * next.
     */
    private val fenceLock = Any()
    private var fence = Fence()

    /** Which [stop] and which [cancel] a transfer belongs after. */
    internal data class Fence(
        val global: Int = 0,
        val perJob: Map<Job, Int> = emptyMap(),
        /**
         * Whether a stamp is judged at all. Armed once the numbers are known:
         * loaded from the fence store, or after this process's first [stop]
         * or [cancel]. Before that — the first launch after upgrading from a
         * build that kept no fence — no stamp can be shown stale, and any that
         * decodes is taken: throwing away a finished book is the worse of the
         * two mistakes.
         */
        val armed: Boolean = false,
    ) {
        fun epoch(job: Job): Int = perJob[job] ?: 0

        /** Whether a transfer stamped this way is one this manager still wants. */
        fun admits(job: Job, generation: Int, epoch: Int): Boolean =
            !armed || (global == generation && epoch(job) == epoch)
    }

    /** A transfer's stamp: the fence it was started under. */
    internal data class Stamp(val generation: Int, val epoch: Int)

    /** A decoded description. */
    internal data class Stamped(val job: Job, val generation: Int, val epoch: Int)

    /** The fence as it is kept: its two counters, each job named by its unstamped description. */
    @Serializable
    private data class StoredFence(val global: Int, val perJob: Map<String, Int>)

    /**
     * A job cancelled while [start] was still awaiting a token, before its
     * transfer existed to be cancelled. Without it the transfer was started
     * regardless once the await returned, completed, and fired [onFinished]
     * as though nobody had touched it.
     */
    private val cancelledBeforeStart = mutableSetOf<Job>()

    init {
        // Before the backend exists: building it is what has it replay what
        // finished while the app was away, and each of those callbacks is
        // judged by this.
        loadFence(fenceStore)?.let { kept -> synchronized(fenceLock) { fence = kept } }
        backend = makeBackend(this)
    }

    private fun currentFence(): Fence = synchronized(fenceLock) { fence }

    private fun setState(job: Job, state: State?) {
        val current = mutableStates.value
        mutableStates.value = if (state == null) current - job else current + (job to state)
    }

    /** Runs [block] on [dispatcher], where this manager's state lives. */
    private fun hop(block: () -> Unit) {
        scope.launch { block() }
    }

    /** Writes the fence down, so a transfer stamped from here on is judged by the same numbers next launch. */
    private fun keepFence() = saveFence(currentFence(), fenceStore)

    /** The stamp a transfer started now should carry. */
    private fun currentStamp(job: Job): Stamp = currentFence().let { Stamp(it.global, it.epoch(job)) }

    /** The job a callback is for, or null when the transfer was discarded. */
    private fun liveJob(transfer: Transfer): Job? {
        val description = transfer.description ?: return null
        val stamped = decodeStamped(description) ?: return null
        return if (currentFence().admits(stamped.job, stamped.generation, stamped.epoch)) stamped.job else null
    }

    /**
     * Points a live manager at a different server or credential. The backend
     * is kept; requests read these at the moment they are built, so a
     * transfer already in flight is unaffected.
     */
    fun reconfigure(baseUrl: URI, tokens: TokenProviding) {
        this.baseUrl = baseUrl
        this.tokens = tokens
    }

    fun state(job: Job): State? = mutableStates.value[job]

    /** Whether a live transfer is tracked for this job: what makes the cancel-during-start race verifiable. */
    internal fun hasTask(job: Job): Boolean = tasks[job] != null

    /** Whether resume data is held for this job. */
    internal fun hasResumeData(job: Job): Boolean = resumeData[job] != null

    /** The request a live transfer was built with. */
    internal fun request(job: Job): TransferRequest? = tasks[job]?.request

    /**
     * The description a transfer started right now would carry, for tests
     * that stand in for the backend's own callbacks.
     */
    internal fun liveTaskDescription(job: Job): String {
        val stamp = currentStamp(job)
        return encode(job, stamp.generation, stamp.epoch)
    }

    /** Everything not yet finished, for the Downloads screen. */
    val pending: List<Pair<Job, State>>
        get() = mutableStates.value.filterValues { it != State.Finished }.toList().sortedBy { it.first.bookUuid }

    /** Forgets a finished or failed download so its row leaves the screen. It does not stop one: [cancel] does. */
    fun clear(job: Job) = setState(job, null)

    /** Starts, or resumes, a download. */
    suspend fun start(job: Job, expectedBytes: Long? = null) {
        if (state(job)?.isActive == true) return

        if (expectedBytes != null && !hasRoom(expectedBytes)) {
            setState(job, State.Failed("Not enough space on this device."))
            return
        }

        // Claimed before the first suspension: two callers arriving together
        // would otherwise both pass the guard above while the token was being
        // fetched, and start two transfers for one file.
        setState(job, State.Queued)
        cancelledBeforeStart.remove(job)

        // The fence as this call began, taken before the suspension below: a
        // `stop()` or `cancel()` that lands while the token is fetched moves
        // it, and stamping afterwards would admit the transfer as live for an
        // account that has gone.
        val stamp = currentStamp(job)

        val base = baseUrl
        val path = base.appendingPath(Endpoint.files(job.bookUuid))
        val url = URI(path.toString() + (if (path.rawQuery == null) "?" else "&") + "format=${job.format.rawValue}")
        val headers = linkedMapOf<String, String>()
        tokens.currentToken()?.let { headers["Authorization"] = "Bearer $it" }
        headers["Origin"] = base.toString()
        val request = TransferRequest(url, headers, allowsMeteredNetwork = !wifiOnly)

        // A cancel that arrived during the suspension above had no transfer to
        // act on. Honour it here, before one is started.
        if (cancelledBeforeStart.remove(job)) return

        // A `stop()` clears that marker along with everything else, so it
        // leaves nothing to find above. The fence is what it moved.
        if (currentStamp(job) != stamp) return

        // The backend may have gone while the token was fetched.
        if (isShutDown) {
            setState(job, State.Failed("Downloads are stopped. Tap to try again."))
            return
        }

        // Resuming from a partial transfer beats starting a 79 MB file again.
        val data = resumeData.remove(job)
        tasks[job] = backend.start(request, encode(job, stamp.generation, stamp.epoch), data)
    }

    fun pause(job: Job) {
        val task = tasks[job]
        if (task == null) {
            // A job is queued from the moment it is asked for until its first
            // byte arrives — which for a request that 404s is never. With no
            // transfer to cancel, the button offering to pause a waiting
            // download did nothing at all.
            if (state(job)?.isActive == true) setState(job, State.Paused(0.0))
            return
        }
        pausing.add(job)
        val fraction = state(job)?.fraction ?: 0.0
        // The callback arrives whenever the backend gets to it. A cancel (or a
        // sign-out's stop) in the meantime advances this stamp, and what the
        // callback would write is then for a download already thrown away:
        // written anyway, a cancelled row came back as "Paused".
        val stamp = currentStamp(job)
        task.cancelProducingResumeData { data ->
            hop {
                pauseCallbacksDelivered += 1
                if (currentStamp(job) != stamp) return@hop
                if (data != null) resumeData[job] = data
                setState(job, State.Paused(fraction))
                tasks.remove(job)
            }
        }
    }

    fun cancel(job: Job) {
        // Advanced before the cancel, on the lock the callbacks read, so a
        // completion already in flight finds itself stale however soon it
        // comes: the finished-file callback moves the file before it hops,
        // and this is all that stands between a cancelled transfer and its
        // file landing where a removal has just emptied. Per job, not global:
        // every other live transfer carries the global number.
        synchronized(fenceLock) {
            fence = fence.copy(perJob = fence.perJob + (job to fence.epoch(job) + 1), armed = true)
        }
        keepFence()
        // No pause marker, and none left by a pause this cancel overtakes: the
        // epoch advanced above fences out the transfer's own cancellation, so
        // nothing would ever consume one, and the next download of the job
        // would take a cancellation it did not ask for as a pause.
        pausing.remove(job)
        val task = tasks.remove(job)
        if (task != null) {
            task.cancel()
        } else {
            // `start` may be mid-flight, still awaiting a token, with no
            // transfer yet. Marked so it stops when the token arrives.
            cancelledBeforeStart.add(job)
        }
        resumeData.remove(job)
        setState(job, null)
    }

    /**
     * Ends this manager's backend for good, cancelling what is in flight. The
     * callers are sign-out paths where nothing in flight belongs to anyone
     * any more.
     */
    fun shutDown() {
        shutDownFlag.set(true)
        backend.invalidateAndCancel()
    }

    /**
     * Stops everything in flight and forgets it, keeping the backend.
     *
     * Sign-out's teardown: the transfers belong to the account that just
     * left, so they are cancelled and their rows cleared. The manager is kept
     * and pointed at the next account by [reconfigure].
     */
    fun stop() {
        // Advanced before the cancel, so the callbacks the cancel provokes
        // find themselves stale. The per-job epochs go with it: every stamp is
        // stale on the global number alone.
        synchronized(fenceLock) { fence = Fence(global = fence.global + 1, perJob = emptyMap(), armed = true) }
        keepFence()
        for (task in tasks.values) task.cancel()
        tasks.clear()
        resumeData.clear()
        pausing.clear()
        cancelledBeforeStart.clear()
        mutableStates.value = emptyMap()
    }

    /**
     * The backend ended unasked. Everything it carried died with it. Rebuilt
     * once, so the next tap on a row works; a second time means it is being
     * contested and this manager stays down rather than joining in.
     */
    private fun backendDidBecomeInvalid(error: Throwable?) {
        for (job in tasks.keys) setState(job, State.Failed("The download was interrupted. Tap to try again."))
        tasks.clear()
        val described = error?.toString() ?: "none"
        if (rebuilds != 0) {
            IssaLog.warning("download session invalidated again; staying down", mapOf("error" to described))
            return
        }
        rebuilds += 1
        IssaLog.warning("download session invalidated; rebuilt", mapOf("error" to described))
        backend = makeBackend(this)
        shutDownFlag.set(false)
    }

    /** Reattaches to whatever the backend carried on with while the app was away. */
    suspend fun reattach() {
        adopt(backend.runningTransfers())
    }

    /**
     * Takes on the transfers the backend carried on with, and stops the ones
     * this manager has let go of since they started.
     *
     * Armed, a transfer's stamp is judged like any callback's: one stamped
     * before a [stop] or a [cancel] this manager knows of is cancelled, not
     * adopted. Unarmed, no stamp can be judged, so every transfer is
     * re-stamped as this launch's own; arming later then leaves it live.
     */
    internal fun adopt(running: List<Transfer>) {
        val fence = currentFence()
        for (task in running) {
            val description = task.description ?: continue
            val stamped = decodeStamped(description) ?: continue
            val job = stamped.job
            if (fence.armed) {
                if (!fence.admits(job, stamped.generation, stamped.epoch)) {
                    // Its callbacks are stale already; this stops the transfer.
                    task.cancel()
                    continue
                }
            } else {
                task.description = encode(job, fence.global, fence.epoch(job))
            }
            tasks[job] = task
            setState(job, State.Downloading(task.fractionCompleted, task.bytesReceived, task.bytesExpected))
        }
    }

    // Callbacks from the backend

    override fun onInvalidated(error: Throwable?) {
        // Flagged first, here: from now on nothing may be started on it,
        // whoever ended it. `shutDown` set the flag already; an end it did not
        // ask for is handled on the dispatcher.
        val deliberate = shutDownFlag.getAndSet(true)
        if (deliberate) return
        hop { backendDidBecomeInvalid(error) }
    }

    /**
     * The bearer for the server this manager is pointed at, as it is now: the
     * same header [start] builds, read again when a transfer runs. Nothing for
     * another origin, so a token never leaves for a host it was not issued by.
     */
    override suspend fun credentials(url: URI): Map<String, String> {
        val base = baseUrl
        val sameOrigin = url.scheme.equals(base.scheme, ignoreCase = true) &&
            url.host.equals(base.host, ignoreCase = true) &&
            effectivePort(url) == effectivePort(base)
        if (!sameOrigin) return emptyMap()
        val token = tokens.currentToken() ?: return emptyMap()
        return mapOf("Authorization" to "Bearer $token")
    }

    private fun effectivePort(url: URI): Int = when {
        url.port != -1 -> url.port
        url.scheme.equals("https", ignoreCase = true) -> 443
        else -> 80
    }

    override fun onProgress(transfer: Transfer, bytesWritten: Long, totalBytesWritten: Long, totalBytesExpected: Long) {
        val job = liveJob(transfer) ?: return
        val fraction = if (totalBytesExpected > 0) totalBytesWritten.toDouble() / totalBytesExpected.toDouble() else 0.0
        hop {
            if (isShutDown) return@hop
            setState(job, State.Downloading(fraction, totalBytesWritten, totalBytesExpected))
        }
    }

    override fun onFinishedDownloading(transfer: Transfer, location: File) {
        // Checked here, synchronously, not only after the hop: "sign out and
        // delete downloads" removes the Books folder right after stop()
        // returns, and a transfer that outlived it would otherwise re-create
        // the folder and move the signed-out account's book into it.
        val job = liveJob(transfer) ?: return
        if (isShutDown) return
        finishDownload(job, location, transfer.response)
    }

    /**
     * Moves a finished transfer into place, or records why it was not.
     *
     * Judged and moved here and now, before the hop, because the backend
     * deletes the temporary file the moment its callback returns. A 2xx is not
     * enough: a proxy whose session lapsed, or a captive portal, answers the
     * file route with a page and a 200, and [BookContentService.validateDownloadedFile]
     * has the last word. A file it refuses is left where it arrived, for the
     * backend to delete.
     */
    internal fun finishDownload(job: Job, location: File, response: TransferResponse?) {
        val status = response?.statusCode ?: 0
        var moveError: String? = null
        if (status !in 200..299) {
            moveError = "The server returned $status."
        } else {
            val refusal = BookContentService.validateDownloadedFile(location, job.format, response?.mimeType)
            if (refusal != null) {
                IssaLog.warning(
                    "downloaded file refused",
                    mapOf("book" to job.bookUuid, "format" to job.format.rawValue, "type" to (response?.mimeType ?: "none")),
                )
                moveError = refusal
            } else {
                val destination = destinationFor(job)
                try {
                    destination.parentFile?.let { parent ->
                        if (!parent.isDirectory && !parent.mkdirs()) {
                            throw IOException("Couldn't create the folder “${parent.name}”.")
                        }
                    }
                    destination.delete()
                    Files.move(location.toPath(), destination.toPath())
                } catch (e: Exception) {
                    IssaLog.failure("move downloaded file", e, mapOf("to" to destination.name))
                    moveError = e.message ?: "The download could not be saved."
                }
            }
        }

        val failure = moveError
        hop {
            if (isShutDown) return@hop
            tasks.remove(job)
            pausing.remove(job)
            if (failure != null) {
                setState(job, State.Failed(failure))
            } else {
                setState(job, State.Finished)
                onFinished?.invoke(job)
            }
        }
    }

    override fun onCompleted(transfer: Transfer, error: TransferError?) {
        if (error == null) return
        val job = liveJob(transfer) ?: return
        val resume = error.resumeData
        val message = readableReason(error)
        val cancelled = error.kind == TransferError.Kind.CANCELLED

        hop {
            if (isShutDown) return@hop
            tasks.remove(job)
            if (cancelled) {
                // Only a cancellation we asked for is not a failure. Anything
                // else — the system reclaiming the transfer — has to be
                // reported, or the row sits at "downloading" forever.
                if (pausing.remove(job)) return@hop
                if (resume != null) resumeData[job] = resume
                setState(job, State.Failed("The download was interrupted. Tap to try again."))
                return@hop
            }
            if (resume != null) resumeData[job] = resume
            setState(job, State.Failed(message))
        }
    }

    companion object {
        private const val WIFI_ONLY_KEY = "issa.downloads.wifiOnly"
        internal const val FENCE_KEY = "issa.downloads.fence"

        /** The fence a previous launch left, armed; null when none was kept. */
        internal fun loadFence(store: KeyValueStore?): Fence? {
            val text = store?.getString(FENCE_KEY) ?: return null
            val stored = runCatching { IssaJson.decodeFromString(StoredFence.serializer(), text) }.getOrNull() ?: return null
            val perJob = mutableMapOf<Job, Int>()
            for ((description, epoch) in stored.perJob) {
                val job = decode(description) ?: continue
                perJob[job] = epoch
            }
            return Fence(global = stored.global, perJob = perJob, armed = true)
        }

        internal fun saveFence(fence: Fence, store: KeyValueStore?) {
            store ?: return
            val stored = StoredFence(fence.global, fence.perJob.mapKeys { encode(it.key) })
            store.putString(FENCE_KEY, IssaJson.encodeToString(StoredFence.serializer(), stored))
        }

        /**
         * A sentence worth showing someone. "unknown error" is a dead end
         * printed on screen rather than a hint.
         */
        internal fun readableReason(error: Throwable): String {
            val described = error.message ?: ""
            val unknown = error is TransferError && error.kind == TransferError.Kind.UNKNOWN
            if (!unknown && described.isNotEmpty()) return described
            return "The download could not start. Tap to try again."
        }

        /**
         * Refuses a download that plainly will not fit, with a real number
         * rather than a failure part-way through. Leaves headroom: filling the
         * disk exactly is its own failure.
         */
        internal fun hasRoom(bytes: Long): Boolean {
            val available = DiskSpace.available() ?: return true
            return available > bytes + 200_000_000
        }

        /**
         * The description, with the [stop] generation and the [cancel] epoch
         * it was started in. Both are omitted when zero, which is where every
         * process starts — so a description a build that knew nothing of
         * either wrote still decodes, which [reattach] depends on across an
         * upgrade. The same spelling as the Swift client's.
         */
        internal fun encode(job: Job, generation: Int = 0, epoch: Int = 0): String {
            val base = "${job.bookUuid}|${job.format.rawValue}"
            if (epoch != 0) return "$base|$generation|$epoch"
            return if (generation == 0) base else "$base|$generation"
        }

        internal fun decode(description: String): Job? = decodeStamped(description)?.job

        internal fun decodeStamped(description: String): Stamped? {
            // As Swift's `split`, which drops empty pieces.
            val parts = description.split('|').filter { it.isNotEmpty() }
            if (parts.size !in 2..4) return null
            val format = BookContentService.Format.fromRawValue(parts[1]) ?: return null
            var generation = 0
            var epoch = 0
            if (parts.size >= 3) generation = parts[2].toIntOrNull() ?: return null
            if (parts.size == 4) epoch = parts[3].toIntOrNull() ?: return null
            return Stamped(Job(parts[0], format), generation, epoch)
        }
    }
}
