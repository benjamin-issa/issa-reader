package com.benjaminissa.issareader.app.model

import com.benjaminissa.issareader.app.Answer
import com.benjaminissa.issareader.app.AppSuite
import com.benjaminissa.issareader.app.SharedFixtures
import com.benjaminissa.issareader.app.StubServer
import com.benjaminissa.issareader.app.TestTokens
import com.benjaminissa.issareader.app.jsonText
import com.benjaminissa.issareader.app.mainTest
import com.benjaminissa.issareader.app.temporaryDirectory
import com.benjaminissa.issareader.app.testApp
import com.benjaminissa.issareader.app.testScope
import com.benjaminissa.issareader.app.waitUntil
import com.benjaminissa.issareader.core.IssaJson
import com.benjaminissa.issareader.core.Session
import com.benjaminissa.issareader.core.model.ServerGeneration
import com.benjaminissa.issareader.core.model.Status
import com.benjaminissa.issareader.core.networking.Endpoint
import com.benjaminissa.issareader.core.store.LibraryStore
import com.benjaminissa.issareader.core.sync.MutationDrain
import com.benjaminissa.issareader.core.sync.MutationQueue
import com.benjaminissa.issareader.core.sync.PositionOrigin
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

/**
 * One account's writes never reach the server as another's. Ported from
 * `AccountSwitchDrainTests.swift`: through `adopt`, `drainPendingWrites`,
 * `writePosition` and the two refreshes, against a real store and queue and a
 * server that tells its readers apart by bearer and logs which bearer every
 * request carried.
 */
class AccountSwitchDrainTest : AppSuite() {
    private val first = BearerServer.first
    private val second = BearerServer.second

    private val statuses = listOf(
        Status(uuid = "status-to-read", name = Status.toReadName),
        Status(uuid = "status-reading", name = Status.readingName),
        Status(uuid = "status-read", name = Status.readName),
    )

    private fun reader(session: Session?): String? = (session?.state?.value as? Session.State.SignedIn)?.user?.id

    private fun position(progress: Double): ByteArray = IssaJson.encodeToString(
        MutationDrain.PositionPayload.serializer(),
        MutationDrain.PositionPayload(StatusParityTest.locator(progress), 10.0),
    ).encodeToByteArray()

    private class Fixture(val parity: StatusParityTest.Fixture, val server: BearerServer) {
        val app get() = parity.app
        suspend fun queued() = parity.queued()
        fun tearDown() {
            server.close()
            parity.tearDown()
        }
    }

    /**
     * A model signed in as reader A on a 3.x server, which leaves the two books
     * it holds unfiled, with a store and a queue of its own. The device last
     * signed in as A, so B's token is a switch.
     */
    private suspend fun fixture(): Fixture {
        val scope = testScope()
        val server = BearerServer()
        val defaults = SharedFixtures.scratchDefaults()
        defaults.putString(AppModel.accountKey(server.url), "reader-A")
        val tokens = TestTokens()
        val app = testApp(scope, keychain = tokens, defaults = defaults)
        val directory = temporaryDirectory("account-switch-drain")
        val store = LibraryStore(server.url.toString(), directory)
        app.useStore(store)
        val session = server.session(keychain = TestTokens())
        session.adopt("token-A")
        assertTrue("the probe never identified the server", waitUntil(10.seconds) { session.capabilities.value.generation == ServerGeneration.V3 })
        assertEquals("reader-A", reader(session))
        app.session = session
        app.books = listOf(
            SharedFixtures.book("First (cached)", uuid = first, progress = 0.1),
            SharedFixtures.book("Second (cached)", uuid = second, progress = 0.1),
        )
        app.rebuildDerived()
        app.statuses = statuses
        server.clearLog()
        return Fixture(StatusParityTest.Fixture(app, store, directory, server, scope), server)
    }

    /** Waits until [condition] holds or a bounded number of turns pass. */
    private suspend fun settle(turns: Int = 400, condition: () -> Boolean) {
        repeat(turns) {
            if (condition()) return
            delay(5.milliseconds)
        }
    }

    /**
     * Finding #5: a drain caught mid-request finishes as the departing
     * account, and the arriving account's token waits for it.
     */
    @Test
    fun aDrainInFlightNeverBorrowsTheArrivingAccountsToken() = mainTest {
        val fixture = fixture()
        try {
            val server = fixture.server
            server.hold(BearerServer.Hold.FIRST_POSITION)
            server.hold(BearerServer.Hold.ARRIVING_IDENTITY)

            MutationQueue(fixture.parity.store).use { queue ->
                for ((book, progress) in listOf(first to 0.2, second to 0.3)) {
                    queue.enqueue(MutationQueue.Kind.POSITION, book, position(progress), supersedes = 10.0)
                }
            }
            val draining = fixture.parity.scope.async { fixture.app.drainPendingWrites() }
            settle { server.sent("POST").size == 1 }
            assertEquals("A's drain has to be mid-request", 1, server.sent("POST").size)
            assertEquals("A's second row has to be waiting behind the first", 2, fixture.queued().size)

            val switching = fixture.parity.scope.async { fixture.app.adopt("token-B") }
            settle(turns = 100) { server.sent("GET", Endpoint.user).isNotEmpty() }
            assertTrue("B's token was installed while A's drain was still sending", server.sent("GET", Endpoint.user).isEmpty())

            server.release(BearerServer.Hold.FIRST_POSITION)
            draining.await()
            settle { server.sent("GET", Endpoint.user).isNotEmpty() }
            server.release(BearerServer.Hold.ARRIVING_IDENTITY)
            switching.await()

            assertEquals("reader-B", reader(fixture.app.session))
            val posts = server.sent("POST")
            assertEquals("A's second row was sent after the switch began", 1, posts.size)
            assertTrue("A's row went out with B's token", posts.all { it.bearer == "token-A" })
            val log = server.log()
            val answered = log.indexOfFirst { it.moment == BearerServer.Moment.ANSWERED && it.method == "POST" }
            val identified = log.indexOfFirst { it.moment == BearerServer.Moment.SENT && it.path == Endpoint.user && it.bearer == "token-B" }
            assertTrue(answered >= 0 && identified >= 0)
            assertTrue("B's token went out before A's request had been answered", answered < identified)
            assertTrue("A's row outlived the switch, for B's drain to send", fixture.queued().isEmpty())
        } finally {
            fixture.tearDown()
        }
    }

    /** Finding #4: a position write that outlives the switch does not file the arriving account's copy of the book. */
    @Test
    fun aWriteThatOutlivesTheSwitchDoesNotFileTheArrivingAccountsBook() = mainTest {
        val fixture = fixture()
        val hold = SeamHold()
        try {
            fixture.app.beforeQueueingStatus = { hold.arrive() }

            val writing = fixture.parity.scope.async {
                fixture.app.writePosition(StatusParityTest.locator(0.5), 10.0, first, PositionOrigin.CHOSEN)
            }
            settle { hold.arrivals == 1 }
            assertEquals("A's write has to be filing the book", 1, hold.arrivals)
            assertEquals(Status.readingName, fixture.app.bookByUuid[first]?.status?.name)

            fixture.app.adopt("token-B")
            assertEquals("reader-B", reader(fixture.app.session))
            val arriving = checkNotNull(fixture.app.bookByUuid[first]) { "B's catalogue has to hold the same book" }
            assertEquals("B's catalogue has to have landed for this to mean anything", "First, for reader-B", arriving.title)
            assertNull(arriving.status)

            hold.release()
            val accepted = writing.await()
            fixture.app.drainPendingWrites(waitingForInFlight = true)

            assertFalse("A's write was reported accepted after B had signed in", accepted)
            assertNull("B's copy of the book was filed by A's reading", fixture.app.bookByUuid[first]?.status)
            assertTrue("A's status went out with B's token", fixture.server.sent("PUT").all { it.bearer != "token-B" })
            assertTrue("A's status was queued for B", fixture.queued().all { it.kind != MutationQueue.Kind.STATUS })
        } finally {
            hold.release()
            fixture.tearDown()
        }
    }

    /** Finding #4, for what a refresh publishes: a refresh that outlives the switch does not show the departing catalogue. */
    @Test
    fun aRefreshThatOutlivesTheSwitchDoesNotShowTheDepartingCatalogue() = mainTest {
        for (refresh in listOf("book", "library")) {
            val fixture = fixture()
            try {
                val server = fixture.server
                server.hold(BearerServer.Hold.DEPARTING_CATALOGUE)
                val departing = checkNotNull(fixture.app.bookByUuid[first])
                val refreshing = fixture.parity.scope.async {
                    if (refresh == "book") fixture.app.refresh(departing) else fixture.app.refreshLibrary()
                }
                settle { server.held(BearerServer.Hold.DEPARTING_CATALOGUE) == 1 }
                assertEquals("A's refresh has to be in flight ($refresh)", 1, server.held(BearerServer.Hold.DEPARTING_CATALOGUE))

                fixture.app.adopt("token-B")
                assertEquals("reader-B", reader(fixture.app.session))
                assertEquals("B's catalogue has to have landed for this to mean anything", "First, for reader-B", fixture.app.bookByUuid[first]?.title)

                server.release(BearerServer.Hold.DEPARTING_CATALOGUE)
                refreshing.await()

                assertEquals("A's catalogue replaced B's on screen ($refresh)", "First, for reader-B", fixture.app.bookByUuid[first]?.title)
            } finally {
                fixture.tearDown()
            }
        }
    }

    /** Finding #4, for a refresh that fails: it does not tell the arriving account its library could not load. */
    @Test
    fun aRefreshThatFailsAfterTheSwitchSaysNothingToTheArrivingAccount() = mainTest {
        val fixture = fixture()
        try {
            val server = fixture.server
            server.emptyArrivingLibrary = true
            server.departingCatalogueTimesOut = true
            server.hold(BearerServer.Hold.DEPARTING_CATALOGUE)
            val refreshing = fixture.parity.scope.async { fixture.app.refreshLibrary() }
            settle { server.held(BearerServer.Hold.DEPARTING_CATALOGUE) == 1 }
            assertEquals("A's refresh has to be in flight", 1, server.held(BearerServer.Hold.DEPARTING_CATALOGUE))

            fixture.app.adopt("token-B")
            assertEquals("reader-B", reader(fixture.app.session))
            assertTrue("B's empty library has to have landed for this to mean anything", fixture.app.books.isEmpty())
            assertNull(fixture.app.loadError)

            server.release(BearerServer.Hold.DEPARTING_CATALOGUE)
            refreshing.await()

            assertTrue(
                "A's refresh has to have been answered, with its failure",
                server.log().any { it.moment == BearerServer.Moment.ANSWERED && it.path == Endpoint.books && it.bearer == "token-A" },
            )
            assertNull("A's failed refresh told B their library could not be loaded", fixture.app.loadError)
            assertTrue(fixture.app.books.isEmpty())
        } finally {
            fixture.tearDown()
        }
    }

    /** An account switch forgets the departing account's writes in flight. */
    @Test
    fun theSwitchForgetsTheDepartingWritesInFlight() = mainTest {
        val fixture = fixture()
        val hold = SeamHold()
        try {
            fixture.app.beforeQueueingStatus = { hold.arrive() }

            val writing = fixture.parity.scope.async {
                fixture.app.writePosition(StatusParityTest.locator(0.5), 10.0, first, PositionOrigin.CHOSEN)
            }
            settle { hold.arrivals == 1 }
            assertEquals("A's write has to be filing the book", 1, hold.arrivals)

            fixture.app.adopt("token-B")
            assertEquals("reader-B", reader(fixture.app.session))
            hold.release()
            writing.await()

            // Reader B files the book on the server — on another device, say —
            // and B's next refresh has to show it.
            fixture.server.arrivingFirstIsFiled = true
            fixture.app.refreshLibrary()

            assertEquals(
                "B's refresh kept B's own status for a write of A's that will never be sent",
                Status.readingName, fixture.app.bookByUuid[first]?.status?.name,
            )
        } finally {
            hold.release()
            fixture.tearDown()
        }
    }

    /** The departing account's queue is retired by the switch. */
    @Test
    fun theSwitchRetiresTheDepartingQueue() = mainTest {
        val fixture = fixture()
        try {
            val departing = checkNotNull(fixture.app.currentMutationQueue)

            fixture.app.adopt("token-B")
            assertEquals("reader-B", reader(fixture.app.session))

            assertNotSame(departing, fixture.app.currentMutationQueue)
            try {
                departing.enqueue(MutationQueue.Kind.POSITION, first, position(0.9), supersedes = 11.0)
                fail("the departing queue still took rows")
            } catch (_: MutationQueue.Retired) {
            }
            fixture.app.drainPendingWrites(waitingForInFlight = true)
            assertTrue("A's write went out with B's token", fixture.server.sent("POST").all { it.bearer != "token-B" })
        } finally {
            fixture.tearDown()
        }
    }

    /** A drain on the queue a reconnect replaced stops before its next row. */
    @Test
    fun aReconnectStopsTheReplacedQueuesDrain() = mainTest {
        val fixture = fixture()
        try {
            val server = fixture.server
            server.hold(BearerServer.Hold.FIRST_POSITION)
            MutationQueue(fixture.parity.store).use { queue ->
                for ((book, progress) in listOf(first to 0.2, second to 0.3)) {
                    queue.enqueue(MutationQueue.Kind.POSITION, book, position(progress), supersedes = 10.0)
                }
            }
            val replaced = checkNotNull(fixture.app.currentMutationQueue)
            val draining = fixture.parity.scope.async { fixture.app.drainPendingWrites() }
            settle { server.sent("POST").size == 1 }
            assertEquals("the old queue's drain has to be mid-request", 1, server.sent("POST").size)

            fixture.app.reopenMutationQueue()
            assertNotSame(replaced, fixture.app.currentMutationQueue)
            server.release(BearerServer.Hold.FIRST_POSITION)
            draining.await()

            assertEquals("the replaced queue's drain went on sending after the reconnect", 1, server.sent("POST").size)
            assertEquals("the row it stopped before is the new queue's to send", 1, fixture.queued().size)
        } finally {
            fixture.tearDown()
        }
    }
}

/** Holds the first status write that reaches `AppModel.beforeQueueingStatus` until released, and lets every later one straight through. */
private class SeamHold {
    @Volatile var arrivals = 0
        private set
    @Volatile private var released = false
    private val gate = CompletableDeferred<Unit>()

    suspend fun arrive() {
        arrivals += 1
        if (arrivals != 1 || released) return
        gate.await()
    }

    fun release() {
        released = true
        gate.complete(Unit)
    }
}

/**
 * A 3.x server with two readers, told apart by bearer, that logs which bearer
 * every request carried and when each was answered.
 *
 * Three kinds of request can be held until released: the first position
 * write, reader B's identity call, and reader A's catalogue reads. Reader A's
 * catalogue reads can also be made to fail as the transport would (a dropped
 * connection): a 401 would have the client invalidate the token, which by
 * then is B's.
 */
private class BearerServer : StubServer({ request -> (this as BearerServer).handle(request) }) {
    enum class Moment { SENT, ANSWERED }
    enum class Hold { FIRST_POSITION, ARRIVING_IDENTITY, DEPARTING_CATALOGUE }

    data class Entry(val moment: Moment, val method: String, val path: String, val bearer: String?)

    private val lock = Any()
    private val entries = ArrayList<Entry>()
    private val holding = HashSet<Hold>()
    private val held = HashMap<Hold, MutableList<CountDownLatch>>()
    private val heldCounts = HashMap<Hold, Int>()
    private var positionsSeen = 0

    @Volatile var departingCatalogueTimesOut = false
    @Volatile var emptyArrivingLibrary = false
    @Volatile var arrivingFirstIsFiled = false

    fun clearLog() = synchronized(lock) { entries.clear() }
    fun log(): List<Entry> = synchronized(lock) { entries.toList() }

    fun sent(method: String, path: String? = null): List<Entry> =
        log().filter { it.moment == Moment.SENT && it.method == method && (path == null || it.path == path) }

    fun hold(hold: Hold) = synchronized(lock) { holding.add(hold) }
    fun held(hold: Hold): Int = synchronized(lock) { heldCounts[hold] ?: 0 }

    fun release(hold: Hold) {
        val latches = synchronized(lock) {
            holding.remove(hold)
            held.remove(hold) ?: emptyList()
        }
        latches.forEach { it.countDown() }
    }

    override fun close() {
        Hold.entries.forEach(::release)
        super.close()
    }

    fun handle(request: com.benjaminissa.issareader.app.SentRequest): Answer {
        val method = request.method
        val path = request.path
        val bearer = request.bearer
        val departingRead = method == "GET" && bearer == "token-A" &&
            (path == Endpoint.books || path == Endpoint.book(first) || path == Endpoint.book(second))
        val answer = answer(method, path, bearer)
        val timesOut = departingRead && departingCatalogueTimesOut
        var latch: CountDownLatch? = null
        synchronized(lock) {
            entries.add(Entry(Moment.SENT, method, path, bearer))
            val hold = when {
                method == "POST" && path.endsWith("/positions") -> {
                    positionsSeen += 1
                    if (positionsSeen == 1) Hold.FIRST_POSITION else null
                }
                path == Endpoint.user && bearer == "token-B" -> Hold.ARRIVING_IDENTITY
                departingRead -> Hold.DEPARTING_CATALOGUE
                else -> null
            }
            if (hold != null && hold in holding) {
                latch = CountDownLatch(1).also { held.getOrPut(hold) { mutableListOf() }.add(it) }
                heldCounts[hold] = (heldCounts[hold] ?: 0) + 1
            }
        }
        latch?.await(120, TimeUnit.SECONDS)
        synchronized(lock) { entries.add(Entry(Moment.ANSWERED, method, path, bearer)) }
        return if (timesOut) Answer.lostConnection else answer
    }

    private fun answer(method: String, path: String, bearer: String?): Answer {
        val reader = when (bearer) {
            "token-A" -> "reader-A"
            "token-B" -> "reader-B"
            else -> null
        } ?: return Answer(401)
        return when {
            method == "GET" && path == Endpoint.user -> Answer(200, """{"id":"$reader"}""")
            method == "GET" && path == Endpoint.V3.serverPublic -> Answer(200, """{"id":"server","capabilities":[]}""")
            method == "GET" && path == Endpoint.V3.serverDetails -> Answer(200, """{"version":"3.0.0-beta.40"}""")
            method == "GET" && path == Endpoint.books ->
                if (reader == "reader-B" && emptyArrivingLibrary) Answer(200, "[]")
                else Answer(200, jsonText(listOf(firstBook(reader), book(second, "Second", reader))))
            method == "GET" && path == Endpoint.book(first) -> Answer(200, jsonText(firstBook(reader)))
            method == "GET" && path == Endpoint.book(second) -> Answer(200, jsonText(book(second, "Second", reader)))
            method == "GET" && path == Endpoint.statuses -> Answer(
                200,
                jsonText(
                    listOf(
                        mapOf("uuid" to "status-to-read", "name" to Status.toReadName),
                        mapOf("uuid" to "status-reading", "name" to Status.readingName),
                        mapOf("uuid" to "status-read", "name" to Status.readName),
                    ),
                ),
            )
            (method == "POST" && (path == Endpoint.positions(first) || path == Endpoint.positions(second))) ||
                (method == "PUT" && (path == Endpoint.status(first) || path == Endpoint.status(second))) -> Answer(200, "{}")
            else -> Answer(404)
        }
    }

    private fun book(uuid: String, title: String, reader: String, filed: Boolean = false): Map<String, Any?> = mapOf(
        "uuid" to uuid, "title" to "$title, for $reader",
        "authors" to emptyList<Any>(), "narrators" to emptyList<Any>(), "creators" to emptyList<Any>(),
        "collections" to emptyList<Any>(), "identifiers" to emptyList<Any>(), "tags" to emptyList<Any>(),
        "series" to emptyList<Any>(),
        "status" to if (filed) mapOf("uuid" to "status-reading", "name" to Status.readingName) else null,
        "ebook" to mapOf("uuid" to "e", "filepath" to "e.epub", "identifiers" to emptyList<Any>()),
    )

    private fun firstBook(reader: String) = book(first, "First", reader, filed = reader == "reader-B" && arrivingFirstIsFiled)

    companion object {
        const val first = "11111111-1111-4111-8111-111111111111"
        const val second = "22222222-2222-4222-8222-222222222222"
    }
}
