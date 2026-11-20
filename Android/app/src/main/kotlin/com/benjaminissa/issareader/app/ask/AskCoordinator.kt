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
import com.benjaminissa.issareader.ask.AskAnswerer
import com.benjaminissa.issareader.ask.AskAvailability
import com.benjaminissa.issareader.ask.AskEngine
import com.benjaminissa.issareader.ask.AskEvent
import com.benjaminissa.issareader.ask.AskFailure
import com.benjaminissa.issareader.ask.AskGenerationOptions
import com.benjaminissa.issareader.ask.AskIndexStore
import com.benjaminissa.issareader.ask.AskProfile
import com.benjaminissa.issareader.ask.AskPromptBuilder
import com.benjaminissa.issareader.ask.AskSuggestions
import com.benjaminissa.issareader.ask.AskTool
import com.benjaminissa.issareader.ask.AskTurnstile
import com.benjaminissa.issareader.ask.BookSource
import com.benjaminissa.issareader.ask.Passage
import com.benjaminissa.issareader.ask.ProviderAnswerModel
import com.benjaminissa.issareader.ask.ProviderCatalog
import com.benjaminissa.issareader.ask.ProviderKind
import com.benjaminissa.issareader.ask.ProviderModel
import com.benjaminissa.issareader.ask.ReadingBoundary
import com.benjaminissa.issareader.ask.android.ModelDownload
import com.benjaminissa.issareader.core.KeyValueStore
import com.benjaminissa.issareader.core.diagnostics.IssaLog
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.launch
import kotlinx.coroutines.plus
import kotlinx.coroutines.withContext

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
 * A reader's own AI key ([keys]) changes one thing about the switch: with a
 * key, a phone that cannot run Gemini Nano — no AICore, ML Kit saying never,
 * or two checks that never came back — keeps Ask on, and only Gemini Nano is
 * set aside. The key is what answers there. Nothing is sent to a provider
 * until the reader asks it something: getting ready never builds a provider's
 * model, and the two-check breaker and the AICore gate are about ML Kit alone.
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
    scope: CoroutineScope,
    val store: AskIndexStore = AskIndexStore(),
    private val notifier: AskNotifying? = null,
    centre: SignOutCentre = SignOutCentre.default,
    /**
     * State that belongs to this install, in a store the backup rules leave
     * out: a restored phone has not been asked about notifications, whatever
     * the old one was.
     */
    private val installState: KeyValueStore = defaults,
    /**
     * Whether this process is an app updated in place, not one installed afresh.
     * Only an in-place update inherits the old store's answer: a fresh install
     * has restored the backed-up preferences, whose answer belongs to the old
     * phone.
     */
    private val isInPlaceUpgrade: () -> Boolean = { false },
    /**
     * The reader's own AI keys, from Settings › Advanced. A coordinator built
     * without any — every test that is not about them — has a store with
     * nothing in it, which reads nothing.
     */
    val keys: AIKeys = AIKeys(NoKeys, defaults),
    /** Builds the model for a reader's key. Injectable so a test can answer from a script instead of a provider. */
    private val makeProviderModel: (ProviderKind, ProviderModel, String) -> AnswerModel =
        { kind, model, key -> ProviderAnswerModel(kind, model, key) },
    /** Lists the models a key can use, which also checks the key. Injectable for the same reason. */
    private val catalog: suspend (ProviderKind, String) -> List<ProviderModel> =
        { kind, key -> ProviderCatalog.models(kind, key) },
) : BookIndexes {
    /**
     * The caller's scope with a last line of defence: nothing thrown inside Ask
     * work may take the process down. Ask is an optional feature, and an
     * uncaught throw from ML Kit once crashed the app on every launch.
     */
    private val scope: CoroutineScope = scope + CoroutineExceptionHandler { _, error ->
        IssaLog.error("ask work failed", mapOf("error" to error.javaClass.name))
    }

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
    private var answerModelOrNull: AnswerModel? = null

    /**
     * The model, or null when making it threw: Ask is then turned back off as
     * unsupported, and what needed it degrades rather than crashing. Not
     * remembered on failure, so turning Ask on again tries again.
     */
    private fun answerModel(): AnswerModel? {
        answerModelOrNull?.let { return it }
        return try {
            platform.makeModel().also { answerModelOrNull = it }
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            IssaLog.error("ask model could not be made", mapOf("error" to error.javaClass.name))
            availability = AskAvailability.UNSUPPORTED_DEVICE
            deviceCannotAnswer(AskSettingsState.Unsupported)
            null
        }
    }

    /**
     * One turn at the on-device model, for the whole app. Held here because
     * this is the only object that outlives a question; it is passed to
     * **both** construction sites below.
     */
    private val turnstile = AskTurnstile()

    /** For index building, prewarming and chips — everything that has no boundary of its own. */
    private var preparerOrNull: AskEngine? = null

    private fun preparer(): AskEngine? {
        preparerOrNull?.let { return it }
        val model = answerModel() ?: return null
        return AskEngine(model = model, store = store, turnstile = turnstile).also { preparerOrNull = it }
    }

    /**
     * For index building and chips where Gemini Nano cannot be warmed — a
     * phone without it, answering with a reader's own key. Never a provider's
     * model: getting ready must not send anything to one.
     */
    private val indexer: AskEngine by lazy { AskEngine(model = IndexOnly, store = store) }

    /**
     * The engine everything without a boundary is built on: Gemini Nano's
     * where it may be warmed, the index alone where only a key answers, and
     * none at all where nothing can.
     */
    private fun gettingReady(): AskEngine? {
        if (deviceMayWarm) preparer()?.let { return it }
        return if (keys.hasAny) indexer else null
    }

    /** Whether Gemini Nano may be made and warmed: on this phone, not set aside, and not known to be unable. */
    private val deviceMayWarm: Boolean
        get() = supportedState && !deviceSetAside && (availability == null || availability == AskAvailability.AVAILABLE)

    /** One model per registered provider, built when first asked and rebuilt when its key or its model changes. */
    private class ProviderEntry(val registration: AIKeys.Registration, val key: String, val model: AnswerModel)

    private val providerModels = HashMap<ProviderKind, ProviderEntry>()

    /**
     * One turn per provider: a question to Anthropic does not wait on one to
     * OpenAI, or on Gemini Nano.
     */
    private val providerTurnstiles = HashMap<ProviderKind, AskTurnstile>()

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

    /**
     * Why Gemini Nano cannot answer while a reader's key keeps Ask on — the
     * reason the switch would otherwise have gone back off with. Null when
     * there is none, or no key.
     */
    private var deviceProblem: AskSettingsState? by mutableStateOf(null)

    /**
     * Whether Gemini Nano is set aside because two checks in a row never came
     * back, on a phone where a key kept Ask on. Kept on disk, as the switch
     * itself is when there is no key: otherwise the next launch would ask ML
     * Kit again and die the same way. Turning Ask off and on tries again.
     */
    private var deviceSetAside: Boolean by mutableStateOf(installState.getBoolean(DEVICE_SET_ASIDE_KEY))

    private fun setDeviceAside(aside: Boolean) {
        deviceSetAside = aside
        installState.putBoolean(DEVICE_SET_ASIDE_KEY, aside)
    }

    private var checking: Job? = null
    private var downloading: Job? = null

    private var supportedState by mutableStateOf(platform.hasSystemService)

    /**
     * Whether this phone has the system service Gemini Nano runs in. Read from
     * the package manager, never from ML Kit, so it is known with Ask off; when
     * it is false the Settings switch is drawn disabled, with the unsupported
     * sentence.
     */
    val isSupported: Boolean get() = supportedState || keys.hasAny

    init {
        // A fresh install has the old phone's flag in the backed-up store and has
        // asked nothing. Dropped now, at the first launch: left there, an update
        // later would make this look like an upgrade and carry it over.
        if (installState !== defaults && installState.getBooleanOrNull(ASKED_FOR_NOTIFICATIONS_KEY) == null && !isInPlaceUpgrade()) {
            defaults.remove(ASKED_FOR_NOTIFICATIONS_KEY)
        }
        // Two checks in a row never came back: the process died inside ML Kit
        // (a native crash no catch can stop) and again when it was tried a
        // second time, so it would die the same way on every launch and this
        // launch does not repeat it. One is not enough: checks run on every
        // return to the foreground and AICore's first bind takes seconds, so a
        // swipe-away, a low-memory kill or an update in that window would
        // label a supported phone unsupported. The 1.7.0 Boolean key is
        // dropped unread for the same reason: a flag set by one such death
        // is exactly what it could not tell from a crash loop.
        defaults.remove(OLD_CHECK_IN_FLIGHT_KEY)
        val interrupted = defaults.getInt(UNFINISHED_CHECKS_KEY) >= UNFINISHED_CHECK_LIMIT
        if (interrupted) {
            defaults.putInt(UNFINISHED_CHECKS_KEY, 0)
            IssaLog.warning("ask check did not finish twice running; turning Ask off")
        }
        if (settings.askEnabled && (interrupted || !supportedState)) {
            if (!keys.hasAny) {
                turnBackOff(AskSettingsState.Unsupported)
            } else if (interrupted) {
                // A key keeps Ask on: only Gemini Nano is set aside.
                setDeviceAside(true)
            }
        }
    }

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
        get() = settings.askEnabled && (keys.hasAny || when (availability) {
            null, AskAvailability.AVAILABLE, AskAvailability.MODEL_DOWNLOADING, AskAvailability.MODEL_DOWNLOADABLE -> true
            AskAvailability.NEEDS_SYSTEM_UPDATE, AskAvailability.UNSUPPORTED_DEVICE,
            AskAvailability.APPLE_INTELLIGENCE_OFF, AskAvailability.UNSUPPORTED_ON_THIS_PLATFORM,
            -> false
        })

    /** Whether Gemini Nano can answer a question right now. */
    val isReady: Boolean
        get() = settings.askEnabled && supportedState && !deviceSetAside && availability == AskAvailability.AVAILABLE

    /**
     * Whether anything here can answer: Gemini Nano, or a reader's own key —
     * which brings Ask to a phone that cannot run Gemini Nano.
     */
    val canAsk: Boolean get() = settings.askEnabled && (isReady || keys.hasAny)

    /**
     * Whether Gemini Nano could ever answer on this phone — ready, downloading,
     * or not asked yet. What decides that a key is the default: only where it
     * never could.
     */
    val deviceSupported: Boolean
        get() = supportedState && !deviceSetAside && AskDefaults.supported(availability)

    /** The Settings section's switch and sentence. */
    val settingsState: AskSettingsState
        get() {
            if (!supportedState && !keys.hasAny) return AskSettingsState.Unsupported
            if (!settings.askEnabled) return turnedOff ?: AskSettingsState.Off
            // A key answers whatever Gemini Nano is doing: the switch stays on,
            // and the footer ([settingsFooter]) says why the phone cannot.
            if (keys.hasAny && (!deviceSupported || deviceProblem != null)) return AskSettingsState.On
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
            if (!supportedState && !keys.hasAny) return AskCopy.unsupported()
            if (!settings.askEnabled) return if (keys.hasAny) AskCopy.TURNED_OFF else turnedOff?.footer() ?: AskCopy.TURNED_OFF
            // With a key the field is always there: the picker's caption says
            // why the phone cannot answer, when it cannot ([deviceNotice]).
            if (keys.hasAny) return null
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
     * Why Gemini Nano cannot take this question, for the caption under the
     * sheet's picker when the reader has it chosen — or null when it can, or
     * has not been asked yet. A question is not sent while there is one: it
     * goes to a provider only when the reader picks one.
     */
    val deviceNotice: String?
        get() {
            if (!supportedState || deviceSetAside) return AskCopy.unsupported()
            deviceProblem?.let { return it.footer() }
            return when (availability) {
                null, AskAvailability.AVAILABLE -> null
                AskAvailability.MODEL_DOWNLOADING -> AskCopy.stillDownloading()
                AskAvailability.MODEL_DOWNLOADABLE -> AskCopy.downloading(download?.fraction)
                AskAvailability.NEEDS_SYSTEM_UPDATE -> AskCopy.needsSystemUpdate()
                AskAvailability.UNSUPPORTED_DEVICE, AskAvailability.APPLE_INTELLIGENCE_OFF,
                AskAvailability.UNSUPPORTED_ON_THIS_PLATFORM,
                -> AskCopy.unsupported()
            }
        }

    /**
     * The sentence under the Settings section: [settingsState]'s, and — with a
     * key — where its questions go. On a phone that cannot run Gemini Nano
     * the key is the only thing that answers, so it says that instead of
     * "isn't available here".
     */
    val settingsFooter: String
        get() {
            val providers = keys.registered
            if (providers.isEmpty()) return settingsState.footer()
            if (!deviceSupported) return AskCopy.keysOnly(providers)
            return (deviceProblem?.footer() ?: settingsState.footer()) + AskCopy.providerSentence(providers)
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
        deviceProblem = null
        if (on && !supportedState) {
            // Not even asked of ML Kit: the phone has no service to ask. A key
            // is what answers here, if there is one.
            if (keys.hasAny) settings.askEnabled = true else turnBackOff(AskSettingsState.Unsupported)
            return
        }
        if (!on) {
            settings.askEnabled = false
            // Everything in flight stops with the switch: a warm-up would go
            // on to prewarm the model, and a question to count tokens and
            // generate, after the reader was told nothing more is sent.
            for ((uuid, task) in preparing.toMap()) {
                task.cancel()
                preparing.remove(uuid)
            }
            // Only what is running (or held): an answer already on the screen is
            // not "in flight" and is the reader's to read or dismiss.
            for ((uuid, job) in jobsState.toMap()) if (job.isPending) cancel(uuid)
            checking?.cancel()
            checking = null
            downloading?.cancel()
            downloading = null
            download = null
            availability = null
            return
        }
        settings.askEnabled = true
        // Turning Ask on is the reader asking again: Gemini Nano, set aside after
        // two checks that never came back, is tried once more, as it is when
        // the switch went off with no key to keep it on.
        if (deviceSetAside) setDeviceAside(false)
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
        // Set aside after two checks that never came back: not asked again.
        if (deviceSetAside) return null
        if (!supportedState) {
            deviceCannotAnswer(AskSettingsState.Unsupported)
            return null
        }
        val check = scope.launch {
            // Counted on disk before ML Kit is touched, and reset once it
            // answers: a process that dies in between leaves the count for the
            // next launch. Off the main thread: a commit() waits on the disk.
            val result = try {
                withContext(Dispatchers.IO) { defaults.putIntDurably(UNFINISHED_CHECKS_KEY, defaults.getInt(UNFINISHED_CHECKS_KEY) + 1) }
                platform.availability()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                IssaLog.error("ask availability failed", mapOf("error" to error.javaClass.name))
                AskAvailability.UNSUPPORTED_DEVICE
            } finally {
                withContext(NonCancellable + Dispatchers.IO) { defaults.putIntDurably(UNFINISHED_CHECKS_KEY, 0) }
            }
            // The reader may have turned it off while ML Kit was answering.
            if (settings.askEnabled) apply(result)
        }
        checking = check
        return check
    }

    private fun apply(result: AskAvailability) {
        availability = result
        when (result) {
            AskAvailability.AVAILABLE -> {
                download = null
                deviceProblem = null
            }
            AskAvailability.MODEL_DOWNLOADING -> Unit
            AskAvailability.MODEL_DOWNLOADABLE -> startDownload()
            AskAvailability.NEEDS_SYSTEM_UPDATE -> deviceCannotAnswer(AskSettingsState.NeedsSystemUpdate)
            AskAvailability.UNSUPPORTED_DEVICE, AskAvailability.APPLE_INTELLIGENCE_OFF,
            AskAvailability.UNSUPPORTED_ON_THIS_PLATFORM,
            -> deviceCannotAnswer(AskSettingsState.Unsupported)
        }
    }

    /**
     * Gemini Nano cannot answer here. Without a key, Ask goes back off, saying
     * why ([turnBackOff]). With one, only Gemini Nano is set aside — its
     * download stopped and the reason kept for the footer — and the key goes
     * on answering: a keyed Boox Palma must not lose Ask.
     */
    private fun deviceCannotAnswer(reason: AskSettingsState) {
        if (!keys.hasAny) {
            turnBackOff(reason)
            return
        }
        IssaLog.info("ask device set aside; a key answers", mapOf("reason" to reason.javaClass.simpleName))
        downloading?.cancel()
        downloading = null
        download = null
        deviceProblem = reason
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
                    is ModelDownload.Failed -> deviceCannotAnswer(AskSettingsState.DownloadFailed(event.failure))
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
            val engine = gettingReady()
            var built = false
            try {
                built = if (engine == null) false else try {
                    engine.prepareIndex(source)
                    true
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Throwable) {
                    false
                }
                // A prewarm that throws (the model's refreshLimits is not
                // guarded) is only logged: it must not skip the clean-up below.
                // Gemini Nano's alone: a reader's provider is never warmed —
                // that would be a request to it.
                if (engine != null && engine !== indexer) try {
                    engine.prewarm()
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Throwable) {
                    IssaLog.error("ask prewarm failed", mapOf("error" to error.javaClass.name))
                }
            } finally {
                // Always forgotten, or a stale entry turns every later prepare()
                // for this book away for the rest of the session.
                if (preparing[uuid] === warmUp) preparing.remove(uuid)
            }
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
        return gettingReady()?.suggestions(source, boundary) ?: AskSuggestions.chips(emptyList())
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
    fun ask(question: String, model: ReaderModel, answerer: AskAnswerer = AskAnswerer.DEVICE): AskJob? {
        val trimmed = question.trim()
        if (trimmed.isEmpty()) return null
        val source = model.askBookSource() ?: return null
        val boundary = model.askBoundary() ?: return null
        return ask(trimmed, source, boundary, answerer)
    }

    /**
     * @param answerer where the reader sent it: Gemini Nano unless they chose
     *   one of their own providers, for this question or as the default.
     */
    fun ask(question: String, source: BookSource, boundary: ReadingBoundary, answerer: AskAnswerer = AskAnswerer.DEVICE): AskJob? {
        if (!settings.askEnabled) return null
        // The first question is the moment the reader has something to be
        // told about later: the one time the permission is asked for.
        requestNotificationsOnce()
        return start(question, source, boundary, answerer, resumption = false, owesNotification = false)
    }

    private fun start(
        question: String,
        source: BookSource,
        boundary: ReadingBoundary,
        answerer: AskAnswerer,
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
            answerer = answerer,
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
        val engine = engine(job, answerer, source, boundary) ?: return job

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
     * The engine this question is answered by, or null when it cannot be asked
     * at all — and the job then says why.
     *
     * A reader's own key is never fallen back from: a missing key, like a
     * failure later, is said, and the sheet offers Gemini Nano only where it
     * can answer.
     */
    private fun engine(job: AskJob, answerer: AskAnswerer, source: BookSource, boundary: ReadingBoundary): AskEngine? {
        val uuid = source.bookUuid
        val provider = answerer.provider
        if (provider != null) {
            val entry = providerModel(provider)
            if (entry == null) {
                IssaLog.info("ask not sent: no key", mapOf("provider" to provider.rawValue))
                job.state = AskJob.State.Failed(
                    AskFailure.Other("Add your ${provider.displayName} key in Settings › Advanced to ask ${provider.displayName}."),
                )
                finished(job)
                return null
            }
            job.providerModelName = entry.registration.model.displayName
            // The book goes with it so the search's results are scrubbed of
            // its name as the prompt is.
            return AskEngine.forQuestion(
                entry.model, store, uuid, boundary, providerTurnstile(provider),
                AskProfile.provider(entry.registration.model, provider),
                epubPackage = source.epubPackage,
            )
        }
        // Never a call into ML Kit on a phone that has no Gemini Nano, or
        // whose checks never came back.
        val model = if (supportedState && !deviceSetAside) answerModel() else null
        if (model == null) {
            // Making the model threw: Ask is off again, and this question says why.
            job.state = AskJob.State.Failed(AskFailure.Other(AskCopy.unsupported()))
            return null
        }
        return AskEngine.forQuestion(model, store, uuid, boundary, turnstile)
    }

    /**
     * The model for a registered provider, built once per key and model. The
     * key is read every time and is part of what the cache matches: a key
     * replaced with the same model is used at once, and a removed key does
     * not stay in memory.
     */
    private fun providerModel(kind: ProviderKind): ProviderEntry? {
        val registration = keys.registration(kind)
        val key = keys.key(kind)
        if (registration == null || key == null) {
            providerModels.remove(kind)
            return null
        }
        providerModels[kind]?.takeIf { it.registration == registration && it.key == key }?.let { return it }
        return ProviderEntry(registration, key, makeProviderModel(kind, registration.model, key)).also { providerModels[kind] = it }
    }

    private fun providerTurnstile(kind: ProviderKind): AskTurnstile = providerTurnstiles.getOrPut(kind) { AskTurnstile() }

    // The reader's own keys

    /** Where a new question starts: Gemini Nano, unless the reader's default or this phone says a key. */
    val defaultAnswerer: AskAnswerer get() = AskDefaults.answerer(settings, keys.registered, deviceSupported)

    /** Every place a question could go from here, in the order the picker lists them. */
    val answerChoices: List<AskAnswerer> get() = AskDefaults.choices(keys.registered, deviceSupported)

    /** The model a provider answers with, as the reader chose it — null for Gemini Nano. */
    fun providerModelName(answerer: AskAnswerer): String? =
        answerer.provider?.let { keys.registration(it)?.model?.displayName }

    /**
     * The reader's default in Settings: Gemini Nano, or one of their
     * providers by name.
     */
    fun setDefaultAnswerer(answerer: AskAnswerer) {
        settings.askDefaultProvider = answerer.provider?.rawValue
    }

    /** The models a key can use, newest first — which also checks the key. */
    suspend fun models(kind: ProviderKind, key: String): List<ProviderModel> = catalog(kind, key)

    /**
     * Saves a key the reader agreed to use, with the model they chose. False
     * when it could not be stored, and nothing is registered then.
     */
    fun registerKey(kind: ProviderKind, key: String, model: ProviderModel): Boolean {
        val saved = keys.register(kind, key, model)
        keysChanged()
        return saved
    }

    /** Another model for a key already registered. */
    fun chooseModel(kind: ProviderKind, model: ProviderModel) {
        keys.choose(model, kind)
        keysChanged()
    }

    /** Removes a key, and with it the default that named its provider. */
    fun removeKey(kind: ProviderKind) {
        keys.remove(kind)
        if (settings.askDefaultProvider == kind.rawValue) settings.askDefaultProvider = null
        keysChanged()
    }

    /** Reads the keys again, as Ask or Settings opens: one unreadable at launch counts once it reads. */
    fun refreshKeys() {
        keys.refresh()
        forgetRemovedProviders()
    }

    /**
     * A key was added, changed or removed. A removed key's model goes from
     * memory; and with no key left, Gemini Nano's problem is Ask's again — on a
     * phone that cannot run it, the switch goes back off, as it would have
     * without one.
     */
    private fun keysChanged() {
        forgetRemovedProviders()
        if (keys.hasAny || !settings.askEnabled) return
        val reason = deviceProblem ?: if (!deviceSupported) AskSettingsState.Unsupported else null
        if (deviceSetAside) setDeviceAside(false)
        deviceProblem = null
        if (reason != null) turnBackOff(reason)
    }

    private fun forgetRemovedProviders() {
        providerModels.keys.retainAll(keys.registered.toSet())
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
        start(held.question, source, held.boundary, held.answerer, resumption = true, owesNotification = held.owesNotification)
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
        if (notificationsAlreadyAsked()) return
        installState.putBoolean(ASKED_FOR_NOTIFICATIONS_KEY, true)
        notifier?.requestAuthorizationIfNeeded()
    }

    /**
     * Whether the reader has been asked on this install. An app updated in place
     * from the release that kept the flag with the other preferences has it there
     * and not in [installState]; taken from the old store, and removed from it,
     * so a reader who declined is not asked again with Android's last allowed
     * ask. A fresh install is not that: the backup restored the old phone's
     * preferences, flag included, and this install has not asked, so the old
     * answer is not carried over.
     *
     * The flag, not the permission's state, because an app cannot tell a
     * permission it never asked for from one the reader denied once without an
     * activity at hand to ask the system.
     */
    private fun notificationsAlreadyAsked(): Boolean {
        installState.getBooleanOrNull(ASKED_FOR_NOTIFICATIONS_KEY)?.let { return it }
        if (installState === defaults || !isInPlaceUpgrade()) return false
        val before = defaults.getBooleanOrNull(ASKED_FOR_NOTIFICATIONS_KEY) ?: return false
        installState.putBoolean(ASKED_FOR_NOTIFICATIONS_KEY, before)
        defaults.remove(ASKED_FOR_NOTIFICATIONS_KEY)
        return before
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
        refreshSupport()
        for (job in jobsState.values.filter { it.isHeld }) resume(job)
        checkAvailability()
    }

    /** The system service may have been installed, or removed, since this was last read. */
    private fun refreshSupport() {
        val now = platform.hasSystemService
        if (now == supportedState) return
        supportedState = now
        if (!now && settings.askEnabled) deviceCannotAnswer(AskSettingsState.Unsupported)
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

        /**
         * How many checks in a row started and never returned: raised
         * (durably) before a check reaches ML Kit, reset to 0 when it returns.
         * At [UNFINISHED_CHECK_LIMIT] at launch, Ask is turned off.
         */
        const val UNFINISHED_CHECKS_KEY = "issa.askChecksUnfinished"
        const val UNFINISHED_CHECK_LIMIT = 2

        /** 1.7.0's flag; removed at launch, unread. */
        internal const val OLD_CHECK_IN_FLIGHT_KEY = "issa.askCheckInFlight"

        /**
         * Gemini Nano set aside by the two-check breaker on a phone a key kept
         * Ask on: this install's, so in the store the backup leaves out.
         */
        const val DEVICE_SET_ASIDE_KEY = "issa.askDeviceSetAside"

        /** Everything the engine can throw, as something the sheet can say. */
        fun failure(error: Throwable): AskFailure =
            error as? AskFailure ?: AskFailure.Other("Something went wrong answering that. Try again.")
    }

    /**
     * The model under the engine that builds indexes and finds chips on a
     * phone only a key answers on. Those never reach a model; nothing asks
     * this one anything, and if something did it would say so rather than
     * send it anywhere.
     */
    private object IndexOnly : AnswerModel {
        override val contextSize: Int = AskPromptBuilder.Budget.tunedContextSize

        override fun answer(instructions: String, prompt: String, tools: List<AskTool>, options: AskGenerationOptions): Flow<String> =
            flow { throw AskFailure.Unavailable }

        override suspend fun tokenCount(text: String): Int = AskPromptBuilder.estimatedTokens(text)

        override suspend fun prewarm() {}
    }
}
