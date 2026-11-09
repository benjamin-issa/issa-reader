package com.benjaminissa.issareader.app.ask

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.benjaminissa.issareader.app.model.BookIndexes
import com.benjaminissa.issareader.app.model.PlaybackSettings
import com.benjaminissa.issareader.app.model.SignOutCentre
import com.benjaminissa.issareader.app.reader.ReaderModel
import com.benjaminissa.issareader.ask.AnswerModel
import com.benjaminissa.issareader.ask.AskAvailability
import com.benjaminissa.issareader.ask.AskEngine
import com.benjaminissa.issareader.ask.AskEvent
import com.benjaminissa.issareader.ask.AskFailure
import com.benjaminissa.issareader.ask.AskIndexStore
import com.benjaminissa.issareader.ask.AskSuggestions
import com.benjaminissa.issareader.ask.AskTurnstile
import com.benjaminissa.issareader.ask.BookSource
import com.benjaminissa.issareader.ask.Passage
import com.benjaminissa.issareader.ask.ReadingBoundary
import com.benjaminissa.issareader.ask.android.ModelDownload
import com.benjaminissa.issareader.core.KeyValueStore
import com.benjaminissa.issareader.core.diagnostics.IssaLog
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.launch

/**
 * Every question in flight, and the machinery that outlives the sheets.
 *
 * Owned above the reader — by `AppGraph` — because `AppModel.readerDidClose`
 * evicts the `ReaderModel` the moment the screen goes away, and a job hung off
 * the reader would die with it. The reader is a source of two values (the
 * boundary and the file); it is not the owner of the answer.
 *
 * Two things differ from the iPhone, both decided by the reader:
 *
 * - **Nothing reaches ML Kit while Ask is off.** ML Kit reports to Google
 *   from its first call, so [platform] — availability, the download, the
 *   model — is called only once the switch is on, and every way in here
 *   checks it. The switch is [setEnabled]; turning it on is what checks this
 *   phone can answer, and a phone that cannot turns it back off with the
 *   reason ([settingsState]).
 * - **Answers are generated only in the foreground.** AICore refuses a
 *   generation for an app that is not on screen. The index goes on building
 *   in the background — it is the app's own — but a question that reaches the
 *   model with the app away is held ([AskJob.isHeld]) and asked again when the
 *   app comes back ([appDidBecomeActive]), as `AskFailure.BackgroundBlocked`'s
 *   sentence promises.
 *
 * Main-thread only, as the Swift class is `@MainActor`: every member is called
 * on [scope]'s dispatcher. Observable through Compose snapshot state.
 *
 * @param platform Gemini Nano, behind the seam a test counts the calls through.
 * @param store one per process: two would open the same SQLite file twice, and
 *   the app also deletes indexes through it when a download goes.
 * @param notifier null or a counting stand-in in tests.
 * @param centre where an account's exit is announced. Injectable so a sign-out
 *   posted by one suite cannot purge another's indexes.
 */
class AskCoordinator(
    private val settings: PlaybackSettings,
    private val platform: AskPlatform,
    private val defaults: KeyValueStore,
    private val scope: CoroutineScope,
    val store: AskIndexStore = AskIndexStore(),
    private val notifier: AskNotifying? = null,
    centre: SignOutCentre = SignOutCentre.default,
) : BookIndexes {
    /**
     * One job per book. A second question about the same book replaces the
     * first, which is what "Ask another" means; a question about a different
     * book is a different job.
     */
    private val jobsState = mutableStateMapOf<String, AskJob>()
    val jobs: Map<String, AskJob> get() = jobsState

    /**
     * A book whose answer a notification tap asked to be reopened. Cleared by
     * whichever reader picks it up ([takeReopenRequest]).
     */
    var reopenRequest: String? by mutableStateOf(null)

    /**
     * The model, made the first time a question or a warm-up needs it — never
     * before the switch is on, because making it is a call into ML Kit.
     */
    private val answerModel: AnswerModel by lazy { platform.makeModel() }

    /**
     * One turn at the on-device model, for the whole app. Held here because
     * this is the only object that outlives a question; it is passed to
     * **both** construction sites below.
     */
    private val turnstile = AskTurnstile()

    /** For index building, prewarming and chips — everything that has no boundary of its own. */
    private val preparer: AskEngine by lazy { AskEngine(model = answerModel, store = store, turnstile = turnstile) }

    /** Books whose index has been built and whose model has been warmed this session. */
    private val prepared = mutableSetOf<String>()
    private val preparing = mutableMapOf<String, Job>()

    private val signOutObservation: AutoCloseable = centre.observe { kept ->
        // The indexes are per book and the books are per account, so an
        // account leaving takes its indexes with it. The device's own books
        // keep theirs: they are not the account's.
        purgeAll(keeping = kept)
    }

    /** Stops listening for sign-outs. */
    fun close() = signOutObservation.close()

    fun job(bookUuid: String): AskJob? = jobsState[bookUuid]

    // Whether this phone can answer

    /**
     * What ML Kit last said about this phone, or null when it has not been
     * asked — which is always the case while Ask is off.
     */
    var availability: AskAvailability? by mutableStateOf(null)
        private set

    /** The app's own download of the model, while it runs: null until ML Kit has said how much there is. */
    private var download: DownloadProgress? by mutableStateOf(null)

    private data class DownloadProgress(val fraction: Double?)

    /** Why the switch last went back off by itself, for the sentence under it. */
    private var turnedOff: AskSettingsState? by mutableStateOf(null)

    private var checking: Job? = null
    private var downloading: Job? = null

    /** Whether the reader has Ask on. */
    val isEnabled: Boolean get() = settings.askEnabled

    /**
     * Whether the reader offers to answer questions — what the sparkle in the
     * reader's bar is shown for.
     *
     * The setting *and* the hardware. A model still coming down still shows
     * it: it comes right without the reader touching this app again, and a
     * control that vanishes and reappears is harder to find than one that
     * explains itself when tapped. Not yet checked counts as offered: the
     * check runs as the app comes forward, and is almost always "available".
     */
    val isOffered: Boolean
        get() = settings.askEnabled && when (availability) {
            null, AskAvailability.AVAILABLE, AskAvailability.MODEL_DOWNLOADING, AskAvailability.MODEL_DOWNLOADABLE -> true
            AskAvailability.NEEDS_SYSTEM_UPDATE, AskAvailability.UNSUPPORTED_DEVICE,
            AskAvailability.APPLE_INTELLIGENCE_OFF, AskAvailability.UNSUPPORTED_ON_THIS_PLATFORM,
            -> false
        }

    /** Whether a question can be asked right now. */
    val isReady: Boolean get() = settings.askEnabled && availability == AskAvailability.AVAILABLE

    /** The Settings section's switch and sentence. */
    val settingsState: AskSettingsState
        get() {
            if (!settings.askEnabled) return turnedOff ?: AskSettingsState.Off
            download?.let { return AskSettingsState.Downloading(it.fraction) }
            return when (availability) {
                AskAvailability.MODEL_DOWNLOADING -> AskSettingsState.SystemDownloading
                AskAvailability.MODEL_DOWNLOADABLE -> AskSettingsState.Downloading(null)
                else -> AskSettingsState.On
            }
        }

    /**
     * What the sheet says instead of a question field, or null when it can
     * take a question. Not yet checked takes one: the check is in flight as
     * the sheet opens, and the field is what the reader came for.
     */
    val sheetNotice: String?
        get() {
            if (!settings.askEnabled) return turnedOff?.footer() ?: AskCopy.TURNED_OFF
            return when (availability) {
                null, AskAvailability.AVAILABLE -> null
                AskAvailability.MODEL_DOWNLOADING, AskAvailability.MODEL_DOWNLOADABLE -> AskCopy.sheetStillDownloading()
                AskAvailability.NEEDS_SYSTEM_UPDATE -> AskCopy.sheetNeedsSystemUpdate()
                AskAvailability.UNSUPPORTED_DEVICE, AskAvailability.APPLE_INTELLIGENCE_OFF,
                AskAvailability.UNSUPPORTED_ON_THIS_PLATFORM,
                -> AskCopy.unsupported()
            }
        }

    /**
     * The Settings switch.
     *
     * On is where this phone is first asked whether it can answer: available
     * stays on; a model that can be downloaded is downloaded, with its
     * progress under the switch; one the system is downloading already is
     * waited for; and a phone that needs a system update, or will never run
     * the model, turns the switch back off with the reason. Off stops asking
     * ML Kit anything at all, including the download's progress.
     */
    fun setEnabled(on: Boolean) {
        turnedOff = null
        if (!on) {
            settings.askEnabled = false
            checking?.cancel()
            checking = null
            downloading?.cancel()
            downloading = null
            download = null
            availability = null
            return
        }
        settings.askEnabled = true
        checkAvailability()
    }

    /**
     * Reads this phone's availability again — only while Ask is on, and
     * never while Ask is off. Called as the app comes forward and as the sheet
     * opens: the model may have finished downloading, or the system updated,
     * since it was last read.
     *
     * @return the check, for a caller that wants to wait on it; null when Ask is off.
     */
    fun checkAvailability(): Job? {
        if (!settings.askEnabled) return null
        checking?.takeIf { it.isActive }?.let { return it }
        val check = scope.launch {
            val result = platform.availability()
            // The reader may have turned it off while ML Kit was answering.
            if (settings.askEnabled) apply(result)
        }
        checking = check
        return check
    }

    private fun apply(result: AskAvailability) {
        availability = result
        when (result) {
            AskAvailability.AVAILABLE -> download = null
            AskAvailability.MODEL_DOWNLOADING -> Unit
            AskAvailability.MODEL_DOWNLOADABLE -> startDownload()
            AskAvailability.NEEDS_SYSTEM_UPDATE -> turnBackOff(AskSettingsState.NeedsSystemUpdate)
            AskAvailability.UNSUPPORTED_DEVICE, AskAvailability.APPLE_INTELLIGENCE_OFF,
            AskAvailability.UNSUPPORTED_ON_THIS_PLATFORM,
            -> turnBackOff(AskSettingsState.Unsupported)
        }
    }

    /** The switch goes back off by itself, saying why — so the reader finds it, and the reason, where they left it. */
    private fun turnBackOff(reason: AskSettingsState) {
        IssaLog.info("ask turned back off", mapOf("reason" to reason.javaClass.simpleName))
        settings.askEnabled = false
        downloading?.cancel()
        downloading = null
        download = null
        availability = null
        turnedOff = reason
    }

    /** Downloads the model, which nothing downloads on its own, showing how far it has got. */
    private fun startDownload() {
        if (downloading?.isActive == true) return
        download = DownloadProgress(null)
        downloading = scope.launch {
            platform.download().collect { event ->
                when (event) {
                    is ModelDownload.Started -> download = DownloadProgress(0.0)
                    is ModelDownload.Progress -> download = DownloadProgress(event.fraction ?: download?.fraction)
                    ModelDownload.Completed -> {
                        download = null
                        availability = AskAvailability.AVAILABLE
                        IssaLog.info("ask model downloaded")
                    }
                    is ModelDownload.Failed -> turnBackOff(AskSettingsState.DownloadFailed(event.failure))
                }
            }
            if (download != null) download = null
        }
    }

    // Getting ready

    /**
     * Builds this book's index and warms the model, once.
     *
     * Called when the sheet opens, so the work happens while the reader is
     * still reading the chips and typing. On a long illustrated book the index
     * build is the larger half of the first question's latency.
     */
    fun prepare(model: ReaderModel) {
        prepare(model.askBookSource() ?: return)
    }

    fun prepare(source: BookSource) {
        if (!settings.askEnabled) return
        val uuid = source.bookUuid
        if (uuid in prepared || preparing.containsKey(uuid)) return
        preparing[uuid] = scope.launch {
            val warmUp = currentCoroutineContext()[Job]
            // Failures are not surfaced: nothing has been asked yet, and a
            // sheet that opens onto an error before the reader has typed a
            // word is worse than one that quietly retries when they do. The
            // question itself builds the index again and reports properly.
            val built = try {
                preparer.prepareIndex(source)
                true
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Throwable) {
                false
            }
            preparer.prewarm()
            if (preparing[uuid] === warmUp) preparing.remove(uuid)
            // Only a warm-up that worked is remembered: a failed one turned
            // every later opening of the sheet away for the rest of the
            // session, and each question paid for the whole build itself.
            if (built) prepared.add(uuid)
        }
    }

    /** The warm-up in flight for this book, if there is one — for a test to wait on. */
    fun warmUp(bookUuid: String): Job? = preparing[bookUuid]

    /**
     * The reader is looking at this book's answer again, so the notification
     * that was standing in for it has done its job. Called when the sheet
     * opens rather than when a notification is tapped: a tap is only one of
     * the ways here.
     */
    fun reopened(bookUuid: String) {
        notifier?.removeDelivered(bookUuid)
    }

    /**
     * Whether this book's reader should open its sheet for a tapped
     * notification, and consumes the request when it should. For the reader,
     * on appearing and whenever [reopenRequest] changes.
     */
    fun takeReopenRequest(bookUuid: String): Boolean {
        if (reopenRequest != bookUuid) return false
        reopenRequest = null
        return true
    }

    /**
     * The chips under the field.
     *
     * Waits for the index build it just started, because otherwise it never
     * sees one: the chip naming the book's own most-mentioned character could
     * only ever appear on a *second* visit to the sheet. The caller draws the
     * generic pair meanwhile and replaces it when this answers.
     */
    suspend fun suggestions(model: ReaderModel): List<String> {
        val source = model.askBookSource()
        val boundary = model.askBoundary()
        if (!settings.askEnabled || source == null || boundary == null) return AskSuggestions.chips(emptyList())
        preparing[source.bookUuid]?.join()
        return preparer.suggestions(source, boundary)
    }

    // Asking

    /**
     * Starts a question about the book on screen.
     *
     * The boundary and the file are read *here*, synchronously, before
     * anything suspends: they are main-thread state the reader is free to
     * change the moment this returns.
     *
     * @return the job, or null when there is nothing to ask yet — the book
     *   still laying out, an empty question, or Ask off.
     */
    fun ask(question: String, model: ReaderModel): AskJob? {
        val trimmed = question.trim()
        if (trimmed.isEmpty()) return null
        val source = model.askBookSource() ?: return null
        val boundary = model.askBoundary() ?: return null
        return ask(trimmed, source, boundary)
    }

    fun ask(question: String, source: BookSource, boundary: ReadingBoundary): AskJob? {
        if (!settings.askEnabled) return null
        // The first question is the moment the reader has something to be
        // told about later: the one time the permission is asked for.
        requestNotificationsOnce()
        return start(question, source, boundary, resumption = false, owesNotification = false)
    }

    private fun start(
        question: String,
        source: BookSource,
        boundary: ReadingBoundary,
        resumption: Boolean,
        owesNotification: Boolean,
    ): AskJob {
        val uuid = source.bookUuid
        // A second question replaces the first, and the first is cancelled
        // rather than left to finish into a job nothing is showing.
        jobsState[uuid]?.task?.cancel()
        val job = AskJob(
            bookUuid = uuid,
            question = question,
            boundary = boundary,
            bookTitle = source.epubPackage.metadata.title,
        )
        job.source = source
        job.isResumption = resumption
        job.owesNotification = owesNotification
        jobsState[uuid] = job

        // The build the sheet started when it opened, if it is still running:
        // awaited rather than raced, and not claimed as finished here.
        val preparation = preparing[uuid]

        // Per question: the one factory the regression run asks the real
        // model through too.
        val engine = AskEngine.forQuestion(answerModel, store, uuid, boundary, turnstile)

        job.task = scope.launch {
            preparation?.join()
            var answered = false
            try {
                engine.ask(question, source, boundary).collect { event ->
                    when (event) {
                        is AskEvent.Phase -> job.state = AskJob.State.Working(event.phase)
                        is AskEvent.Partial -> job.partial = event.text
                        is AskEvent.Answered -> {
                            answered = true
                            job.state = AskJob.State.Answered(event.answer)
                        }
                    }
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                val failure = failure(error)
                if (failure == AskFailure.BackgroundBlocked) {
                    hold(job)
                    return@launch
                }
                job.state = AskJob.State.Failed(failure)
                finished(job)
                return@launch
            }
            // A stream that ends without an answer is a cancellation from
            // below — a model that stopped — and leaves nothing to show.
            if (!answered) {
                if (jobsState[uuid] === job) jobsState.remove(uuid)
                return@launch
            }
            finished(job)
        }
        return job
    }

    /**
     * Gemini Nano would not answer because the app was not on screen.
     *
     * The question is kept, said so, and asked again when the app comes back.
     * If the app is already back — the failure landed after the return — it
     * is asked again now, once; a re-asked question blocked again with the app
     * in front waits for the next return instead, so the two can never chase
     * each other.
     */
    private fun hold(job: AskJob) {
        job.state = AskJob.State.Failed(AskFailure.BackgroundBlocked)
        job.isHeld = true
        IssaLog.info("ask question held for the foreground")
        if (isForeground && !job.isResumption) {
            resume(job)
            return
        }
        // The index is built and the book read: what is left needs the
        // reader back, and a reader who left mid-question was promised word.
        if (!isForeground && job.owesNotification) notifier?.postReadyToAnswer(job)
    }

    /** Asks a held question again, with the boundary and file it was first asked with. */
    private fun resume(held: AskJob) {
        val source = held.source ?: return
        if (jobsState[held.bookUuid] !== held || !settings.askEnabled) return
        // The reader is back; a "ready to answer" banner has done its job.
        notifier?.removeDelivered(held.bookUuid)
        start(held.question, source, held.boundary, resumption = true, owesNotification = held.owesNotification)
    }

    /** Stops a job and forgets it. What Cancel does. */
    fun cancel(bookUuid: String) {
        jobsState.remove(bookUuid)?.task?.cancel()
    }

    /**
     * Throws the answer away. What Done and "Ask another" do — nothing about a
     * question or an answer is ever persisted.
     */
    fun discard(bookUuid: String) {
        cancel(bookUuid)
    }

    /** The sheet closed. A working — or held — job carries on. */
    fun sheetDismissed(bookUuid: String) {
        val job = jobsState[bookUuid] ?: return
        if (!job.isPending) {
            // An answer nobody is looking at is not worth keeping: it exists
            // only to be read, and the next open should start on a blank field.
            discard(bookUuid)
            return
        }
        job.owesNotification = true
    }

    /** Leaves for the excerpt a source cites, in a task the closing sheet does not own. */
    fun openInTheBook(model: ReaderModel, passage: Passage) {
        scope.launch { model.go(passage) }
    }

    /**
     * Asks for notification permission the first time — and only the first
     * time — a question is asked.
     *
     * Contextual on purpose: a permission prompt at launch, for a feature that
     * is off by default, is the prompt everybody denies. This one arrives at
     * the moment the reader has something to be told about later.
     */
    private fun requestNotificationsOnce() {
        if (defaults.getBoolean(ASKED_FOR_NOTIFICATIONS_KEY)) return
        defaults.putBoolean(ASKED_FOR_NOTIFICATIONS_KEY, true)
        notifier?.requestAuthorizationIfNeeded()
    }

    /** Whether the sheet should put the system's notification question now. */
    val wantsNotificationPermission: Boolean get() = notifier?.wantsPermission ?: false

    /** The sheet has put it. */
    fun notificationPermissionAsked() {
        notifier?.permissionAsked()
    }

    /** A job that has stopped: post the notification if one is owed. */
    private fun finished(job: AskJob) {
        val notifier = notifier ?: return
        if (job.owesNotification && job.state.isAnswered) {
            notifier.postAnswerReady(job)
        } else {
            // The other half of the notifier's own log line, so the two
            // together say why nothing arrived. Never the question.
            IssaLog.info(
                "ask job finished quietly",
                mapOf("owed" to job.owesNotification.toString(), "answered" to job.state.isAnswered.toString()),
            )
        }
    }

    // Leaving and coming back

    /** Whether the app is in front. Pushed in by the process lifecycle. */
    var isForeground: Boolean = true
        private set

    val hasWorkingJob: Boolean get() = jobsState.values.any { it.isPending }

    /**
     * The app has gone to the background. A question still working owes the
     * reader a notification — leaving the app mid-question is exactly who it
     * is for — whether it finishes in the time Android gives it, or is held
     * because Gemini Nano will not answer for an app that is not on screen.
     */
    fun appDidEnterBackground() {
        isForeground = false
        for (job in jobsState.values) if (job.state.isWorking) job.owesNotification = true
    }

    /**
     * The app is in front again: held questions are asked now, and — only
     * while Ask is on — this phone's availability is read again, since the
     * reader may have just been to the system's settings or the model may
     * have finished downloading.
     */
    fun appDidBecomeActive() {
        isForeground = true
        for (job in jobsState.values.filter { it.isHeld }) resume(job)
        checkAvailability()
    }

    // Deletion

    /** One book's index, when its download goes. */
    override fun remove(bookUuid: String) {
        cancel(bookUuid)
        prepared.remove(bookUuid)
        preparing.remove(bookUuid)?.cancel()
        scope.launch { store.remove(bookUuid) }
    }

    /**
     * Every index but those of [keeping], on sign-out or when downloads are
     * deleted with the account: [keeping] is the books the reader added from
     * their own files, which belong to the device and outlive the account.
     * Their jobs, warm-ups and delivered answers are left as they are.
     */
    fun purgeAll(keeping: Set<String>) {
        for ((uuid, job) in jobsState.toMap()) {
            if (uuid in keeping) continue
            job.task?.cancel()
            jobsState.remove(uuid)
        }
        prepared.retainAll(keeping)
        for ((uuid, task) in preparing.toMap()) {
            if (uuid in keeping) continue
            task.cancel()
            preparing.remove(uuid)
        }
        reopenRequest?.let { if (it !in keeping) reopenRequest = null }
        // Including anything already in the shade: the account's data is
        // going, and a notification about one of its answers is that data.
        notifier?.removeAllDelivered(keeping)
        scope.launch { store.removeAll(keeping) }
    }

    companion object {
        /** Remembers that the reader has been asked about notifications once, so they are never asked twice. */
        const val ASKED_FOR_NOTIFICATIONS_KEY = "issa.askNotificationsAsked"

        /** Everything the engine can throw, as something the sheet can say. */
        fun failure(error: Throwable): AskFailure =
            error as? AskFailure ?: AskFailure.Other("Something went wrong answering that. Try again.")
    }
}
