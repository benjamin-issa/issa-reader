package com.benjaminissa.issareader.app.ask

import com.benjaminissa.issareader.app.model.PlaybackSettings
import com.benjaminissa.issareader.app.model.SignOutCentre
import com.benjaminissa.issareader.ask.AnswerModel
import com.benjaminissa.issareader.ask.AskAvailability
import com.benjaminissa.issareader.ask.AskIndexStore
import com.benjaminissa.issareader.ask.BookSource
import com.benjaminissa.issareader.ask.ReadingBoundary
import com.benjaminissa.issareader.ask.ScriptedAnswerModel
import com.benjaminissa.issareader.ask.android.ModelDownload
import com.benjaminissa.issareader.core.InMemoryKeyValueStore
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
        return availability
    }

    override fun download(): Flow<ModelDownload> {
        downloadCalls += 1
        val events = scriptedDownload ?: return downloadEvents.consumeAsFlow()
            .transformWhile { emit(it); it !is ModelDownload.Completed && it !is ModelDownload.Failed }
        return flow { for (event in events) emit(event) }
    }

    override fun makeModel(): AnswerModel {
        modelCalls += 1
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
) : AutoCloseable {
    val dispatcher: ExecutorCoroutineDispatcher = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
    val scope = CoroutineScope(SupervisorJob() + dispatcher)
    val defaults = InMemoryKeyValueStore()
    val centre = SignOutCentre()
    val settings = PlaybackSettings(defaults, centre).also { it.askEnabled = askEnabled }
    val coordinator = AskCoordinator(
        settings = settings,
        platform = platform,
        defaults = defaults,
        scope = scope,
        store = store,
        notifier = notifier,
        centre = centre,
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
