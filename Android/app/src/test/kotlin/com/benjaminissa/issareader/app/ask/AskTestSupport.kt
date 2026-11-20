package com.benjaminissa.issareader.app.ask

import com.benjaminissa.issareader.app.model.PlaybackSettings
import com.benjaminissa.issareader.app.model.SignOutCentre
import com.benjaminissa.issareader.ask.AnswerModel
import com.benjaminissa.issareader.ask.AskAvailability
import com.benjaminissa.issareader.ask.AskIndexStore
import com.benjaminissa.issareader.ask.BookSource
import com.benjaminissa.issareader.ask.ReadingBoundary
import com.benjaminissa.issareader.ask.ProviderKind
import com.benjaminissa.issareader.ask.ProviderModel
import com.benjaminissa.issareader.ask.ScriptedAnswerModel
import com.benjaminissa.issareader.ask.android.ModelDownload
import com.benjaminissa.issareader.core.InMemoryKeyValueStore
import com.benjaminissa.issareader.core.auth.TokenPersisting
import com.benjaminissa.issareader.testing.Fixtures
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExecutorCoroutineDispatcher
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.consumeAsFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.transformWhile
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import java.io.File
import java.nio.file.Files
import java.util.Collections
import java.util.UUID
import java.util.concurrent.Executors

/**
 * Gemini Nano, as the coordinator sees it, counting every call.
 *
 * What lets a test assert the reader's decision — nothing reaches ML Kit while
 * Ask is off — as a fact about calls rather than about intentions: the real
 * platform is the only thing that calls into `:ask-android`, and this stands
 * where it stands.
 */
class CountingPlatform(
    var availability: AskAvailability = AskAvailability.AVAILABLE,
    private val model: AnswerModel = ScriptedAnswerModel(),
    /** The download's events, or null for one the test feeds through [downloadEvents]. */
    private val scriptedDownload: List<ModelDownload>? = listOf(ModelDownload.Started(100), ModelDownload.Progress(42, 100), ModelDownload.Completed),
) : AskPlatform {
    /** Whether the phone has the system's AI service; read without counting as a call into ML Kit. */
    @Volatile override var hasSystemService: Boolean = true

    /** Thrown from [availability] when set, as ML Kit does on a phone without Gemini Nano. */
    @Volatile var availabilityThrows: Throwable? = null

    /** Thrown from [download] when set, from inside the coordinator's own coroutine. */
    @Volatile var downloadThrows: Throwable? = null

    /** Thrown from [makeModel] when set. */
    @Volatile var makeModelThrows: Throwable? = null

    @Volatile var availabilityCalls = 0
        private set

    @Volatile var downloadCalls = 0
        private set

    @Volatile var modelCalls = 0
        private set

    /** Every call into Gemini Nano, of any kind. */
    val calls: Int get() = availabilityCalls + downloadCalls + modelCalls

    /** What a download the test drives by hand emits. */
    val downloadEvents = Channel<ModelDownload>(Channel.UNLIMITED)

    override suspend fun availability(): AskAvailability {
        availabilityCalls += 1
        availabilityThrows?.let { throw it }
        return availability
    }

    override fun download(): Flow<ModelDownload> {
        downloadCalls += 1
        downloadThrows?.let { throw it }
        val events = scriptedDownload ?: return downloadEvents.consumeAsFlow()
            .transformWhile { emit(it); it !is ModelDownload.Completed && it !is ModelDownload.Failed }
        return flow { for (event in events) emit(event) }
    }

    override fun makeModel(): AnswerModel {
        modelCalls += 1
        makeModelThrows?.let { throw it }
        return model
    }
}

/** Counts what the coordinator asks of the notification shade, and asks the real one nothing. */
class CountingNotifier : AskNotifying {
    var authorizationRequests = 0
        private set
    var posted = 0
        private set
    var readyToAnswer = 0
        private set

    /** What each purge asked to keep, so a sign-out that swept the device's own banners shows here. */
    val removedAllKeeping = mutableListOf<Set<String>>()
    val removed = mutableListOf<String>()

    override fun requestAuthorizationIfNeeded() {
        authorizationRequests += 1
    }

    override fun postAnswerReady(job: AskJob) {
        posted += 1
    }

    override fun postReadyToAnswer(job: AskJob) {
        readyToAnswer += 1
    }

    override fun removeDelivered(bookUuid: String) {
        removed += bookUuid
    }

    override fun removeAllDelivered(keeping: Set<String>) {
        removedAllKeeping += keeping
    }
}

/**
 * A coordinator with a scripted model, its own index directory, its own
 * defaults and its own sign-out centre — nothing it does can reach the real
 * app — confined, as the app's is to the main thread, to one thread of its own.
 */
class AskHarness(
    turns: List<ScriptedAnswerModel.Turn> = listOf(ScriptedAnswerModel.Turn.answer("Alice followed a white rabbit.\nSources: 1")),
    val notifier: AskNotifying? = null,
    askEnabled: Boolean = true,
    val model: ScriptedAnswerModel = ScriptedAnswerModel(turns),
    val platform: CountingPlatform = CountingPlatform(model = model),
    val directory: File = temporaryDirectory(),
    store: AskIndexStore = AskIndexStore(directory),
    val defaults: InMemoryKeyValueStore = InMemoryKeyValueStore(),
    /** The install's own store, when a test keeps one apart from [defaults] as the app does. */
    val installState: InMemoryKeyValueStore? = null,
    /** Whether the app was updated in place (true) or installed afresh. */
    var inPlaceUpgrade: Boolean = false,
    /** Where the reader's own keys are sealed: nothing, unless a test is about them. */
    val keyStore: TokenPersisting = NoKeys,
    /** What each provider answers, for a test about the reader's own keys. */
    val providers: Map<ProviderKind, ScriptedAnswerModel> = ProviderKind.entries.associateWith { kind ->
        ScriptedAnswerModel(
            listOf(ScriptedAnswerModel.Turn.answer("Alice followed a white rabbit (${kind.rawValue}).\nSources: 1")),
            contextSize = 200_000,
        )
    },
    /** What a key's model list is, for the screens that read it. */
    val catalog: suspend (ProviderKind, String) -> List<ProviderModel> = { _, _ -> emptyList() },
) : AutoCloseable {
    val dispatcher: ExecutorCoroutineDispatcher = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
    val scope = CoroutineScope(SupervisorJob() + dispatcher)
    val centre = SignOutCentre()
    val settings = PlaybackSettings(defaults, centre).also { it.askEnabled = askEnabled }

    /** The reader's own keys, over [keyStore] and this harness's preferences. */
    val keys = AIKeys(keyStore, defaults)

    /** Every provider model the coordinator built, as (provider, model id, key) — the only way a key reaches one. */
    val built: MutableList<Triple<ProviderKind, String, String>> = Collections.synchronizedList(ArrayList())

    val coordinator = AskCoordinator(
        settings = settings,
        platform = platform,
        defaults = defaults,
        scope = scope,
        store = store,
        notifier = notifier,
        centre = centre,
        installState = installState ?: defaults,
        isInPlaceUpgrade = { inPlaceUpgrade },
        keys = keys,
        makeProviderModel = { kind, model, key ->
            built += Triple(kind, model.id, key)
            providers.getValue(kind)
        },
        catalog = catalog,
    )

    /** Runs [block] on the coordinator's own thread, as the app runs everything on the main one. */
    fun <T> run(block: suspend AskHarness.() -> T): T = runBlocking(dispatcher) {
        // Bounded, so a coordinator that never finishes a job fails here rather than hanging the run.
        withTimeout(30_000) { block() }
    }

    override fun close() {
        coordinator.close()
        settings.close()
        scope.cancel()
        dispatcher.close()
        directory.deleteRecursively()
    }

    companion object {
        fun temporaryDirectory(): File = Files.createTempDirectory("issa-ask-coordinator-${UUID.randomUUID()}").toFile()

        /** *Alice's Adventures in Wonderland*, IssaAsk's own fixture, read in place. */
        fun source(uuid: String = "alice-uuid"): BookSource = BookSource(uuid, Fixtures.ask("alice.epub"))

        /**
         * The end of Chapter I — far enough in that questions about Alice and
         * the rabbit retrieve something, and short of everything the story
         * spoils.
         */
        fun boundary(spine: Int = 2): ReadingBoundary =
            ReadingBoundary(spineIndex = spine, charOffset = Int.MAX_VALUE, chapterTitle = "Chapter I", pageNumber = 6)
    }
}
