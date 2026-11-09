package com.benjaminissa.issareader.app.model

import androidx.sqlite.SQLiteConnection
import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import androidx.sqlite.driver.bundled.SQLITE_OPEN_READWRITE
import androidx.sqlite.execSQL
import com.benjaminissa.issareader.app.Answer
import com.benjaminissa.issareader.app.AppSuite
import com.benjaminissa.issareader.app.SharedFixtures
import com.benjaminissa.issareader.app.StubServer
import com.benjaminissa.issareader.app.jsonText
import com.benjaminissa.issareader.app.mainTest
import com.benjaminissa.issareader.app.temporaryDirectory
import com.benjaminissa.issareader.app.testApp
import com.benjaminissa.issareader.app.testScope
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.Status
import com.benjaminissa.issareader.core.networking.Endpoint
import com.benjaminissa.issareader.core.store.LibraryStore
import com.benjaminissa.issareader.core.sync.MutationQueue
import com.benjaminissa.issareader.core.sync.PositionOrigin
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.time.Duration.Companion.milliseconds

/**
 * A server answer older than a status this device wrote never puts the old
 * status back. Ported from `StatusRefreshRaceTests.swift`: through
 * `refresh(book)`, `refreshLibrary`, `setStatus` and `writePosition`, against a
 * real store and queue, with a server that can hold a catalogue read open
 * while the test writes.
 */
class StatusRefreshRaceTest : AppSuite() {
    private val dracula = StatusParityTest.dracula
    private val bleakHouse = StatusParityTest.bleakHouse
    private val reading = Status(uuid = "status-reading", name = Status.readingName)
    private val read = Status(uuid = "status-read", name = Status.readName, label = "Finished")
    private val statuses = listOf(Status(uuid = "status-to-read", name = Status.toReadName), reading, read)

    /**
     * A Storyteller server that answers reads, cannot be written to, and holds
     * its catalogue reads open while told to. Every book it serves has
     * `status: null`.
     */
    private class RaceServer : StubServer({ request ->
        val titles = StatusParityTest.titles
        when {
            request.method != "GET" -> Answer.lostConnection
            request.path == Endpoint.books -> Answer(200, jsonText(titles.keys.sorted().map(::serverBook)))
            else -> titles.keys.firstOrNull { Endpoint.book(it) == request.path }?.let { Answer(200, jsonText(serverBook(it))) } ?: Answer(404)
        }
    }) {
        private val catalogue = listOf(Endpoint.books) + StatusParityTest.titles.keys.map(Endpoint::book)

        fun holdCatalogueReads() = catalogue.forEach(::hold)
        val catalogueReadsHeld: Int get() = catalogue.sumOf(::held)
        fun releaseCatalogue() = catalogue.forEach(::release)

        companion object {
            fun serverBook(uuid: String): Map<String, Any?> = mapOf(
                "uuid" to uuid, "title" to (StatusParityTest.titles[uuid] ?: uuid),
                "authors" to emptyList<Any>(), "narrators" to emptyList<Any>(), "creators" to emptyList<Any>(),
                "collections" to emptyList<Any>(), "identifiers" to emptyList<Any>(), "tags" to emptyList<Any>(),
                "series" to emptyList<Any>(), "status" to null,
                "ebook" to mapOf("uuid" to "e", "filepath" to "e.epub", "identifiers" to emptyList<Any>()),
            )
        }
    }

    /** A model with a store and queue of its own, and a session the stub answers. Not signed in. */
    private fun fixture(books: List<Book>): Pair<StatusParityTest.Fixture, RaceServer> {
        val scope = testScope()
        val server = RaceServer()
        val app = testApp(scope)
        val directory = temporaryDirectory("status-refresh-race")
        val store = LibraryStore("status-refresh-race", directory)
        app.useStore(store)
        app.session = server.session()
        app.books = books
        app.rebuildDerived()
        app.statuses = statuses
        return StatusParityTest.Fixture(app, store, directory, server, scope) to server
    }

    private suspend fun settle(condition: () -> Boolean) {
        repeat(400) {
            if (condition()) return
            delay(5.milliseconds)
        }
    }

    /** Waits for the refresh's detached write to put the server's catalogue on disk. */
    private suspend fun persisted(uuid: String, fixture: StatusParityTest.Fixture): Book? {
        repeat(400) {
            val book = fixture.store.allBooks().firstOrNull { it.uuid == uuid }
            if (book?.title == StatusParityTest.titles[uuid]) return book
            delay(5.milliseconds)
        }
        return null
    }

    /** A status set and sent while its book was being fetched is kept. */
    @Test
    fun statusSetAndSentDuringABookRefreshIsKept() = mainTest {
        val (fixture, server) = fixture(listOf(SharedFixtures.book("Dracula (cached)", uuid = dracula, progress = 0.1)))
        try {
            val book = checkNotNull(fixture.app.bookByUuid[dracula])
            server.holdCatalogueReads()
            val refreshing = fixture.scope.async { fixture.app.refresh(book) }
            settle { server.catalogueReadsHeld == 1 }
            assertEquals("the fetch has to be in flight", 1, server.catalogueReadsHeld)

            fixture.app.setStatus(read, book)
            fixture.drainAccepted()
            server.releaseCatalogue()
            refreshing.await()

            val refreshed = checkNotNull(fixture.app.bookByUuid[dracula])
            assertEquals("the refresh has to have landed for this to mean anything", "Dracula", refreshed.title)
            assertEquals("an answer older than the reader's choice put the old status back", read, refreshed.status)

            fixture.app.writePosition(StatusParityTest.locator(0.5), 10.0, dracula, PositionOrigin.CHOSEN)
            assertEquals("the rule filed the book over the reader's choice", listOf(MutationQueue.Kind.POSITION), fixture.queued().map { it.kind })
        } finally {
            fixture.tearDown()
        }
    }

    /** A status set and sent while the library was being fetched is kept, on screen and on disk. */
    @Test
    fun statusSetAndSentDuringALibraryRefreshIsKept() = mainTest {
        val (fixture, server) = fixture(
            listOf(
                SharedFixtures.book("Dracula (cached)", uuid = dracula, progress = 0.1),
                SharedFixtures.book("Bleak House (cached)", uuid = bleakHouse, status = Status.readingName),
            ),
        )
        try {
            val book = checkNotNull(fixture.app.bookByUuid[dracula])
            server.holdCatalogueReads()
            val refreshing = fixture.scope.async { fixture.app.refreshLibrary() }
            settle { server.catalogueReadsHeld == 1 }
            assertEquals("the fetch has to be in flight", 1, server.catalogueReadsHeld)

            fixture.app.setStatus(read, book)
            fixture.drainAccepted()
            server.releaseCatalogue()
            refreshing.await()

            assertNull(fixture.app.loadError)
            val refreshed = checkNotNull(fixture.app.bookByUuid[dracula])
            assertEquals("the refresh has to have landed for this to mean anything", "Dracula", refreshed.title)
            assertEquals("an answer older than the reader's choice put the old status back", read, refreshed.status)
            assertNull(fixture.app.bookByUuid[bleakHouse]?.status)
            val stored = checkNotNull(persisted(dracula, fixture)) { "the refresh never wrote the catalogue to disk" }
            assertEquals("the next cold launch would show the old status", read, stored.status)

            fixture.app.writePosition(StatusParityTest.locator(0.5), 10.0, dracula, PositionOrigin.CHOSEN)
            assertEquals("the rule filed the book over the reader's choice", listOf(MutationQueue.Kind.POSITION), fixture.queued().map { it.kind })
        } finally {
            fixture.tearDown()
        }
    }

    /** A status queued before a fetch and sent during it is kept, through either refresh. */
    @Test
    fun statusQueuedBeforeAFetchAndSentDuringItIsKept() = mainTest {
        for (refresh in listOf("book", "library")) {
            val (fixture, server) = fixture(listOf(SharedFixtures.book("Dracula (cached)", uuid = dracula, progress = 0.1)))
            try {
                val book = checkNotNull(fixture.app.bookByUuid[dracula])
                fixture.app.setStatus(read, book)
                assertEquals("the write has to be waiting", listOf(MutationQueue.Kind.STATUS), fixture.queued().map { it.kind })

                server.holdCatalogueReads()
                val refreshing = fixture.scope.async { if (refresh == "book") fixture.app.refresh(book) else fixture.app.refreshLibrary() }
                settle { server.catalogueReadsHeld == 1 }
                assertEquals("the fetch has to be in flight ($refresh)", 1, server.catalogueReadsHeld)
                fixture.drainAccepted()
                server.releaseCatalogue()
                refreshing.await()

                val refreshed = checkNotNull(fixture.app.bookByUuid[dracula])
                assertEquals("the refresh has to have landed for this to mean anything", "Dracula", refreshed.title)
                assertEquals("an answer older than the reader's choice put the old status back ($refresh)", read, refreshed.status)
            } finally {
                fixture.tearDown()
            }
        }
    }

    /** A status chosen by hand survives a refresh that lands before its row is queued. */
    @Test
    fun aChosenStatusSurvivesARefreshBeforeItsRowExists() = mainTest {
        val (fixture, _) = fixture(listOf(SharedFixtures.book("Dracula (cached)", uuid = dracula, progress = 0.1)))
        val hold = FirstArrivalHold()
        try {
            fixture.app.beforeQueueingStatus = { hold.arrive() }
            val book = checkNotNull(fixture.app.bookByUuid[dracula])
            val choosing = fixture.scope.async { fixture.app.setStatus(read, book) }
            settle { hold.arrivals == 1 }
            assertEquals("the choice has to be between its save and its row", 1, hold.arrivals)
            assertTrue(fixture.queued().isEmpty())

            fixture.app.refresh(book)

            val refreshed = checkNotNull(fixture.app.bookByUuid[dracula])
            assertEquals("the refresh has to have landed for this to mean anything", "Dracula", refreshed.title)
            assertEquals("the refresh put the server's status over a choice still being saved", read, refreshed.status)

            hold.release()
            choosing.await()
            assertEquals(read, fixture.app.bookByUuid[dracula]?.status)
            assertEquals(read.uuid, fixture.queuedStatus()?.second)
        } finally {
            hold.release()
            fixture.tearDown()
        }
    }

    /** The rule does not queue its status over a choice made while it was queueing. */
    @Test
    fun theRuleDoesNotOverwriteAChoiceMadeWhileItWasQueueing() = mainTest {
        val (fixture, _) = fixture(listOf(SharedFixtures.book("Dracula (cached)", uuid = dracula, progress = 0.1)))
        val hold = FirstArrivalHold()
        try {
            fixture.app.beforeQueueingStatus = { hold.arrive() }
            val writing = fixture.scope.async {
                fixture.app.writePosition(StatusParityTest.locator(0.5), 10.0, dracula, PositionOrigin.CHOSEN)
            }
            settle { hold.arrivals == 1 }
            assertEquals("the rule has to be between its save and its row", 1, hold.arrivals)
            assertEquals("the rule has to have filed the book", reading, fixture.app.bookByUuid[dracula]?.status)

            fixture.app.setStatus(read, checkNotNull(fixture.app.bookByUuid[dracula]))
            assertEquals("the reader's choice has to have been queued past the seam", 2, hold.arrivals)
            hold.release()
            assertTrue(writing.await())

            assertEquals(read, fixture.app.bookByUuid[dracula]?.status)
            assertEquals(listOf(MutationQueue.Kind.POSITION, MutationQueue.Kind.STATUS), fixture.queued().map { it.kind })
            assertEquals("the rule's status replaced the reader's choice in the queue", read.uuid, fixture.queuedStatus()?.second)
            val stored = fixture.store.allBooks().firstOrNull { it.uuid == dracula }
            assertEquals(read, stored?.status)
        } finally {
            hold.release()
            fixture.tearDown()
        }
    }

    /**
     * A status overruled while it was being saved does not leave its save in
     * the store. The store is held by a third save waiting on a write lock the
     * test takes on its own connection, so both status saves queue behind it.
     * Swift ran the two at different task priorities so the older landed
     * last; coroutines have no priorities, so the order the store takes them
     * in is the lock's, and the next test fixes it by hand.
     */
    @Test
    fun anOverruledStatusSavedLastDoesNotStayInTheStore() = mainTest {
        val (fixture, _) = fixture(
            listOf(
                SharedFixtures.book("Dracula (cached)", uuid = dracula, progress = 0.1),
                SharedFixtures.book("Bleak House (cached)", uuid = bleakHouse),
            ),
        )
        val lock = WriteLock(fixture.store.url.path)
        try {
            val book = checkNotNull(fixture.app.bookByUuid[dracula])
            val bleak = checkNotNull(fixture.app.bookByUuid[bleakHouse])
            var occupied = false
            val occupying = fixture.scope.launch {
                occupied = true
                runCatching { fixture.store.upsert(bleak) }
            }
            settle { occupied }
            val overruled = fixture.scope.async { fixture.app.setStatus(reading, book) }
            settle { fixture.app.bookByUuid[dracula]?.status == reading }
            assertEquals("the older write has to be waiting to save", reading, fixture.app.bookByUuid[dracula]?.status)
            val choosing = fixture.scope.async { fixture.app.setStatus(read, book) }
            settle { fixture.app.bookByUuid[dracula]?.status == read }
            assertEquals("the newer write has to be waiting to save", read, fixture.app.bookByUuid[dracula]?.status)

            lock.release()
            occupying.join()
            choosing.await()
            overruled.await()

            assertEquals(read, fixture.app.bookByUuid[dracula]?.status)
            assertEquals("the overruled status replaced the newer one in the queue", read.uuid, fixture.queuedStatus()?.second)
            val stored = fixture.store.allBooks().firstOrNull { it.uuid == dracula }
            assertEquals("the overruled status's save landed last and was left there", read, stored?.status)
        } finally {
            lock.release()
            fixture.tearDown()
        }
    }

    /** An overruled status whose save landed after the newer one's is saved over again. */
    @Test
    fun anOverruledStatusSavedLastIsSavedOver() = mainTest {
        val (fixture, _) = fixture(listOf(SharedFixtures.book("Dracula (cached)", uuid = dracula, progress = 0.1)))
        val hold = FirstArrivalHold()
        try {
            fixture.app.beforeQueueingStatus = { hold.arrive() }
            val book = checkNotNull(fixture.app.bookByUuid[dracula])

            val overruled = fixture.scope.async { fixture.app.setStatus(reading, book) }
            settle { hold.arrivals == 1 }
            assertEquals("the older write has to be between its save and its row", 1, hold.arrivals)
            fixture.app.setStatus(read, book)
            assertEquals("the newer write has to have gone past the seam", 2, hold.arrivals)
            // The older write's save, landing last.
            val late = checkNotNull(fixture.app.bookByUuid[dracula]).copy(status = reading)
            fixture.store.upsert(late)
            hold.release()
            overruled.await()

            assertEquals(read, fixture.app.bookByUuid[dracula]?.status)
            assertEquals(read.uuid, fixture.queuedStatus()?.second)
            val stored = fixture.store.allBooks().firstOrNull { it.uuid == dracula }
            assertEquals("the overruled status's save landed last and was left there", read, stored?.status)
        } finally {
            hold.release()
            fixture.tearDown()
        }
    }
}

/**
 * Holds the write lock on a database file from a connection of its own, as
 * another process writing would, until released. `BEGIN IMMEDIATE` takes the
 * lock or fails at once, so once this exists the lock is held.
 */
private class WriteLock(path: String) {
    private var connection: SQLiteConnection? = BundledSQLiteDriver().open(path, SQLITE_OPEN_READWRITE).also {
        it.execSQL("BEGIN IMMEDIATE")
    }

    @Synchronized
    fun release() {
        val connection = connection ?: return
        this.connection = null
        runCatching { connection.execSQL("ROLLBACK") }
        connection.close()
    }
}
