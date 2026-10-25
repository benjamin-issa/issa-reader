package com.benjaminissa.issareader.app

import androidx.compose.runtime.snapshots.Snapshot
import com.benjaminissa.issareader.app.model.AppModel
import com.benjaminissa.issareader.app.model.PlaybackSettings
import com.benjaminissa.issareader.app.model.SignOutCentre
import com.benjaminissa.issareader.app.reader.ReaderServices
import com.benjaminissa.issareader.core.CurrentBookSnapshotStore
import com.benjaminissa.issareader.core.InMemoryKeyValueStore
import com.benjaminissa.issareader.core.IssaJson
import com.benjaminissa.issareader.core.KeyValueStore
import com.benjaminissa.issareader.core.Session
import com.benjaminissa.issareader.core.StorageRoot
import com.benjaminissa.issareader.core.auth.TokenPersisting
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.networking.MonitoredReachability
import com.benjaminissa.issareader.core.networking.Reachability
import com.benjaminissa.issareader.playback.MediaBackend
import com.benjaminissa.issareader.render.android.ReaderFonts
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExecutorCoroutineDispatcher
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.rules.ExternalResource
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.File
import java.net.URI
import java.nio.file.Files
import java.util.concurrent.Executors
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

/**
 * The thread the suites call "main".
 *
 * Swift's suites are `@MainActor`: the test and the code under test share one
 * thread, and interleave only where something suspends. One thread of the
 * suites' own does the same here — the test body runs on it ([mainTest]) and
 * so does every coroutine an [AppModel] or a reader launches ([testScope]) —
 * and it always *posts*, as `Dispatchers.Main` does, which the coordinators
 * need. Robolectric's own main looper is left alone: nothing these models do
 * needs it, and pumping it from a blocked test thread is how a suite hangs.
 */
object TestMain {
    lateinit var thread: Thread
        private set

    val dispatcher: ExecutorCoroutineDispatcher = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "issa-test-main").apply {
            isDaemon = true
            thread = this
        }
    }.asCoroutineDispatcher()

    val isCurrent: Boolean get() = Thread.currentThread() === thread
}

/** Runs a test's body on the suites' main thread, bounded so a hang fails rather than stalls the run. */
fun mainTest(timeout: Duration = 120.seconds, block: suspend CoroutineScope.() -> Unit) {
    runBlocking(TestMain.dispatcher) { withTimeout(timeout) { block() } }
}

/** A scope on the suites' main thread for one test's models, cancelled by the caller (or left to the daemon). */
fun testScope(): CoroutineScope = CoroutineScope(SupervisorJob() + TestMain.dispatcher)

/** Cancels a scope made by [testScope]. */
fun CoroutineScope.close() = cancel()

/**
 * Waits, in bounded steps, for a condition the code under test settles in its
 * own time — a detached write, a capability probe. Returns whether it came
 * true; never spins without sleeping. Sends the snapshot system's apply
 * notifications each step, so code that watches state through `snapshotFlow`
 * sees what the test wrote, as a frame would in the app.
 */
suspend fun waitUntil(within: Duration = 10.seconds, condition: suspend () -> Boolean): Boolean {
    val deadline = System.nanoTime() + within.inWholeNanoseconds
    while (System.nanoTime() < deadline) {
        Snapshot.sendApplyNotifications()
        if (condition()) return true
        delay(20.milliseconds)
    }
    Snapshot.sendApplyNotifications()
    return condition()
}

/** Lets everything already queued on the main thread run: `await Task.yield()` a few times over. */
suspend fun settle(rounds: Int = 5) {
    repeat(rounds) {
        Snapshot.sendApplyNotifications()
        kotlinx.coroutines.yield()
        delay(1)
    }
}

/**
 * Every suite runs under Robolectric at sdk 36, with real text layout (the
 * reader's chapters are laid out by `StaticLayout`), and with a storage root of
 * its own per test ([FreshStorage]).
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [36])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
abstract class AppSuite {
    @get:org.junit.Rule
    val storage = FreshStorage()
}

/**
 * A storage root of the test's own, so a store keyed by server — and a
 * server here is `127.0.0.1` on whichever port was free — is never one an
 * earlier test left behind. Swift's suites got the same from a fresh host name
 * per server.
 */
class FreshStorage : ExternalResource() {
    val root: File get() = processRoot

    override fun before() {
        empty()
        StorageRoot.configure(File(root, "files"), File(root, "caches"), isPurgeable = false)
        // The widget's file too: a test's publish never lands where another
        // test, or the next run, reads it.
        CurrentBookSnapshotStore.configure(File(root, "Widget").apply { mkdirs() })
    }

    override fun after() {
        CurrentBookSnapshotStore.configure(null)
        empty()
    }

    /**
     * One root for the process, emptied around every test rather than replaced:
     * `BookContentService` resolves its directory once, lazily, as the app
     * does after configuring the root at launch, so a root moved per test
     * would leave it reading the first test's.
     */
    private fun empty() {
        root.listFiles()?.forEach { it.deleteRecursively() }
    }

    private companion object {
        val processRoot: File by lazy { Files.createTempDirectory("issa-app-tests").toFile().apply { deleteOnExit() } }
    }
}

/** One font registry for the whole test process, as the app has one. */
val testFonts: ReaderFonts by lazy { ReaderFonts(RuntimeEnvironment.getApplication()) }

/** What a reader needs that is not about its book, over a scripted engine. */
fun testServices(scope: CoroutineScope, makeBackend: () -> MediaBackend = { ScriptedBackend() }): ReaderServices =
    ReaderServices(scope = scope, fonts = testFonts, makeMediaBackend = makeBackend)

/** A token store that never touches the Keystore. */
class TestTokens : TokenPersisting {
    private val stored = HashMap<String, String>()

    @Synchronized override fun read(account: String): String? = stored[account]

    @Synchronized override fun write(token: String, account: String): Boolean {
        stored[account] = token
        return true
    }

    @Synchronized override fun delete(account: String): Boolean {
        stored.remove(account)
        return true
    }
}

/** A fresh temporary directory, deleted by the caller. */
fun temporaryDirectory(prefix: String): File = Files.createTempDirectory(prefix).toFile()

/** Converts plain Kotlin values into JSON, as `JSONSerialization` does a dictionary. */
fun jsonOf(value: Any?): JsonElement = when (value) {
    null -> JsonNull
    is JsonElement -> value
    is String -> JsonPrimitive(value)
    is Number -> JsonPrimitive(value)
    is Boolean -> JsonPrimitive(value)
    is Map<*, *> -> JsonObject(value.entries.associate { (key, item) -> key as String to jsonOf(item) })
    is List<*> -> JsonArray(value.map { jsonOf(it) })
    else -> error("not JSON: $value")
}

fun jsonText(value: Any?): String = jsonOf(value).toString()

/**
 * Values the app tests build from, in the shape the server sends them: a
 * `Book` is only ever decoded, so every suite builds one by decoding.
 */
object SharedFixtures {
    fun book(
        title: String,
        uuid: String? = null,
        status: String? = null,
        progress: Double? = null,
        positionTimestamp: Double? = null,
        positionHref: String = "OEBPS/ch01.xhtml",
        positionType: String = "application/xhtml+xml",
        createdAt: String? = null,
        readaloud: Boolean = false,
        audiobook: Boolean = false,
        ebook: Boolean = true,
        authors: List<String> = emptyList(),
        narrators: List<String> = emptyList(),
        tags: List<String> = emptyList(),
        series: List<Pair<String, Double?>> = emptyList(),
    ): Book {
        val json = mutableMapOf<String, Any?>(
            "uuid" to (uuid ?: title),
            "title" to title,
            "authors" to authors.map { mapOf("uuid" to it, "name" to it) },
            "narrators" to narrators.map { mapOf("uuid" to it, "name" to it) },
            "creators" to emptyList<Any>(), "collections" to emptyList<Any>(),
            "identifiers" to emptyList<Any>(),
            "tags" to tags.mapIndexed { index, name -> mapOf("uuid" to "$name-$index", "name" to name) },
            "series" to series.map { (name, position) ->
                buildMap<String, Any?> {
                    put("uuid", name)
                    put("name", name)
                    if (position != null) put("position", position)
                }
            },
        )
        if (status != null) json["status"] = mapOf("uuid" to status, "name" to status)
        if (progress != null) {
            json["position"] = mapOf(
                "locator" to mapOf(
                    "href" to positionHref,
                    "type" to positionType,
                    "locations" to mapOf("totalProgression" to progress, "progression" to progress),
                ),
                "timestamp" to (positionTimestamp ?: 0.0),
            )
        }
        if (createdAt != null) json["createdAt"] = createdAt
        if (ebook) json["ebook"] = mapOf("uuid" to "e", "filepath" to "e.epub", "identifiers" to emptyList<Any>())
        if (readaloud) json["readaloud"] = mapOf("uuid" to "r", "filepath" to "r.epub", "identifiers" to emptyList<Any>())
        if (audiobook) json["audiobook"] = mapOf("uuid" to "a", "filepath" to "a.m4b", "identifiers" to emptyList<Any>())
        return decodeBook(json)
    }

    fun decodeBook(json: Map<String, Any?>): Book = IssaJson.decodeFromJsonElement(Book.serializer(), jsonOf(json))

    /** A preferences store of the test's own. */
    fun scratchDefaults(): KeyValueStore = InMemoryKeyValueStore()
}

/** Settings of the test's own: preferences in memory, and a sign-out centre no other suite posts to. */
object PlaybackSettingsForTests {
    fun make(defaults: KeyValueStore = SharedFixtures.scratchDefaults(), centre: SignOutCentre = SignOutCentre()): PlaybackSettings =
        PlaybackSettings(defaults, centre)
}

/**
 * An app model on the suites' main thread, with a token store, preferences
 * and a sign-out centre of its own, and its sessions built by [makeSession].
 */
fun testApp(
    scope: CoroutineScope,
    keychain: TokenPersisting = TestTokens(),
    defaults: KeyValueStore = SharedFixtures.scratchDefaults(),
    centre: SignOutCentre = SignOutCentre(),
    reachability: Reachability = MonitoredReachability(),
    makeSession: ((URI) -> Session)? = null,
    makeBackend: () -> MediaBackend = { ScriptedBackend() },
): AppModel = AppModel(
    keychain = keychain,
    defaults = defaults,
    notificationCentre = centre,
    reachability = reachability,
    scope = scope,
    makeSession = makeSession ?: { url -> Session(url, keychain) },
).also {
    // What the app's graph hands over at launch: the readers' fonts and a
    // scripted engine in place of ExoPlayer.
    it.readerServices = testServices(scope, makeBackend)
}
