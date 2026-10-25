package com.benjaminissa.issareader.app.model

import com.benjaminissa.issareader.app.Answer
import com.benjaminissa.issareader.app.AppSuite
import com.benjaminissa.issareader.app.SharedFixtures
import com.benjaminissa.issareader.app.StubServer
import com.benjaminissa.issareader.app.TestTokens
import com.benjaminissa.issareader.app.close
import com.benjaminissa.issareader.app.jsonText
import com.benjaminissa.issareader.app.mainTest
import com.benjaminissa.issareader.app.temporaryDirectory
import com.benjaminissa.issareader.app.testApp
import com.benjaminissa.issareader.app.testScope
import com.benjaminissa.issareader.app.waitUntil
import com.benjaminissa.issareader.core.IssaJson
import com.benjaminissa.issareader.core.Session
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.ReadiumLocator
import com.benjaminissa.issareader.core.model.ServerGeneration
import com.benjaminissa.issareader.core.model.Status
import com.benjaminissa.issareader.core.networking.Endpoint
import com.benjaminissa.issareader.core.store.LibraryStore
import com.benjaminissa.issareader.core.sync.MutationDrain
import com.benjaminissa.issareader.core.sync.MutationQueue
import com.benjaminissa.issareader.core.sync.PositionOrigin
import kotlinx.coroutines.CoroutineScope
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import kotlin.time.Duration.Companion.seconds

/**
 * Statuses behave on Storyteller 3 as they did on 2.x. Ported from
 * `StatusParityTests.swift`: through `writePosition` and the refreshes,
 * against a real store and its real queue.
 */
class StatusParityTest : AppSuite() {
    /** A model with a store and a queue of its own, signed into the stub server as the given generation. */
    class Fixture(val app: AppModel, val store: LibraryStore, val directory: File, val server: StubServer, val scope: CoroutineScope) {
        /** What the queue holds, oldest first — the order the drain sends in. */
        suspend fun queued(): List<MutationQueue.Pending> = MutationQueue(store).use { it.pending() }

        /** The queued status write, and the status it will send. */
        suspend fun queuedStatus(): Pair<MutationQueue.Pending, String>? {
            val row = queued().firstOrNull { it.kind == MutationQueue.Kind.STATUS } ?: return null
            return row to IssaJson.decodeFromString(MutationDrain.StatusPayload.serializer(), row.payload.decodeToString()).status
        }

        /** Empties the queue the way a drain does when the server takes every write. */
        suspend fun drainAccepted() {
            MutationQueue(store).use { queue -> for (row in queue.pending()) queue.remove(row.id) }
        }

        fun tearDown() {
            server.close()
            directory.deleteRecursively()
            scope.close()
        }
    }

    /** Which server the stub is; Swift carried it in the port. */
    enum class Kind { UNDETECTED, V2, V3, V3_READER_WITHOUT_DOWNLOAD }

    companion object {
        const val dracula = "11111111-1111-4111-8111-111111111111"
        const val bleakHouse = "22222222-2222-4222-8222-222222222222"

        /** On this device's shelf only; the server is never asked for it. */
        const val middlemarch = "33333333-3333-4333-8333-333333333333"

        /** The server's titles, which differ from the cached ones so a test can tell a refresh landed. */
        val titles = mapOf(dracula to "Dracula", bleakHouse to "Bleak House")

        /** The server's statuses, relabelled the way the 3.x fixture server is: the rule matches on `name`. */
        val statuses = listOf(
            Status(uuid = "status-to-read", name = Status.toReadName),
            Status(uuid = "status-reading", name = Status.readingName),
            Status(uuid = "status-read", name = Status.readName, label = "Finished"),
        )

        fun status(named: String): Status = statuses.first { it.name == named }

        /** What the reader's own save produces. */
        fun locator(progress: Double) = ReadiumLocator(
            href = "OEBPS/ch09.xhtml", type = "application/xhtml+xml",
            locations = ReadiumLocator.Locations(progression = progress, totalProgression = progress),
        )

        /**
         * A Storyteller server that answers reads and cannot be written to:
         * every write fails as a lost connection would, so the queue keeps it.
         * Every book it serves has `status: null`.
         */
        fun stub(kind: Kind) = StubServer { request ->
            if (request.method != "GET") return@StubServer Answer.lostConnection
            val v3 = kind == Kind.V3 || kind == Kind.V3_READER_WITHOUT_DOWNLOAD
            when (request.path) {
                Endpoint.user -> if (kind == Kind.V3_READER_WITHOUT_DOWNLOAD) {
                    Answer(200, """{"id":"reader","permissions":{"bookRead":true,"bookList":true,"bookDownload":false}}""")
                } else {
                    Answer(200, """{"id":"reader"}""")
                }
                Endpoint.V3.serverPublic -> when {
                    v3 -> Answer(200, """{"id":"server","capabilities":[]}""")
                    kind == Kind.V2 -> Answer(404)
                    else -> Answer(503)
                }
                Endpoint.V3.serverDetails -> if (v3) Answer(200, """{"version":"3.0.0-beta.40"}""") else Answer(404)
                Endpoint.books -> Answer(200, jsonText(titles.keys.sorted().map(::serverBook)))
                else -> titles.keys.firstOrNull { Endpoint.book(it) == request.path }
                    ?.let { Answer(200, jsonText(serverBook(it))) } ?: Answer(404)
            }
        }

        private fun serverBook(uuid: String): Map<String, Any?> = mapOf(
            "uuid" to uuid, "title" to (titles[uuid] ?: uuid),
            "authors" to emptyList<Any>(), "narrators" to emptyList<Any>(), "creators" to emptyList<Any>(),
            "collections" to emptyList<Any>(), "identifiers" to emptyList<Any>(), "tags" to emptyList<Any>(),
            "series" to emptyList<Any>(), "status" to null,
            "ebook" to mapOf("uuid" to "e", "filepath" to "e.epub", "identifiers" to emptyList<Any>()),
        )

        /**
         * A session whose server the probe identifies as [generation]: signed
         * in, and the detection waited for. Null is a session not told yet —
         * the first launch after an upgrade, offline.
         */
        suspend fun session(server: StubServer, generation: ServerGeneration?): Session {
            val session = server.session(keychain = TestTokens())
            if (generation == null) return session
            session.adopt("a-token")
            assertTrue(
                "the probe never identified the server",
                waitUntil(10.seconds) { session.capabilities.value.generation == generation },
            )
            return session
        }

        suspend fun fixture(generation: ServerGeneration?, books: List<Book>, mayWriteStatus: Boolean = true): Fixture {
            val scope = testScope()
            val kind = when (generation) {
                ServerGeneration.V3 -> if (mayWriteStatus) Kind.V3 else Kind.V3_READER_WITHOUT_DOWNLOAD
                ServerGeneration.V2 -> Kind.V2
                null -> Kind.UNDETECTED
            }
            val server = stub(kind)
            val app = testApp(scope)
            val directory = temporaryDirectory("status-parity")
            val store = LibraryStore("status-parity", directory)
            app.useStore(store)
            app.session = session(server, generation)
            app.books = books
            app.rebuildDerived()
            app.statuses = statuses
            return Fixture(app, store, directory, server, scope)
        }
    }

    /** A reader the server does not let set statuses is not filed. */
    @Test
    fun noFilingWithoutPermission() = mainTest {
        val fixture = fixture(
            ServerGeneration.V3, listOf(SharedFixtures.book("Dracula", uuid = dracula, progress = 0.1)), mayWriteStatus = false,
        )
        try {
            val state = fixture.app.session?.state?.value
            val user = (state as? Session.State.SignedIn)?.user
            assertNotNull("the fixture never signed in", user)
            assertEquals(false, user?.permissions?.bookDownload)

            val accepted = fixture.app.writePosition(locator(0.5), 10.0, dracula, PositionOrigin.CHOSEN)

            assertTrue(accepted)
            assertNull(fixture.app.bookByUuid[dracula]?.status)
            assertEquals(listOf(MutationQueue.Kind.POSITION), fixture.queued().map { it.kind })
        } finally {
            fixture.tearDown()
        }
    }

    /** A position written for a book with no status files it, queued behind the position. */
    @Test
    fun positionFilesAnUnfiledBook() = mainTest {
        for (generation in listOf(ServerGeneration.V3, null)) {
            for ((progress, expected) in listOf(0.2 to Status.readingName, 0.99 to Status.readName)) {
                val fixture = fixture(generation, listOf(SharedFixtures.book("Dracula", uuid = dracula, progress = 0.1)))
                try {
                    val accepted = fixture.app.writePosition(locator(progress), 10.0, dracula, PositionOrigin.CHOSEN)

                    assertTrue(accepted)
                    assertEquals(
                        "the shelf should move under the reader's finger, as a chosen status does ($generation, $progress)",
                        expected, fixture.app.bookByUuid[dracula]?.status?.name,
                    )
                    val queued = fixture.queued()
                    assertEquals(
                        "the status follows the position it was decided from",
                        listOf(MutationQueue.Kind.POSITION, MutationQueue.Kind.STATUS), queued.map { it.kind },
                    )
                    val sent = IssaJson.decodeFromString(MutationDrain.StatusPayload.serializer(), queued.last().payload.decodeToString())
                    assertEquals(status(expected).uuid, sent.status)
                    val persisted = fixture.store.allBooks().firstOrNull { it.uuid == dracula }
                    assertEquals("a cold launch would show the book unfiled again", expected, persisted?.status?.name)
                } finally {
                    fixture.tearDown()
                }
            }
        }
    }

    /** A known 2.x server, or a book with a status, is left to the server. */
    @Test
    fun leftToTheServer() = mainTest {
        for ((generation, status) in listOf(
            ServerGeneration.V2 to null,
            ServerGeneration.V3 to Status.toReadName,
            ServerGeneration.V3 to Status.readingName,
            null to Status.readName,
        )) {
            val fixture = fixture(generation, listOf(SharedFixtures.book("Dracula", uuid = dracula, status = status, progress = 0.1)))
            try {
                val accepted = fixture.app.writePosition(locator(0.99), 10.0, dracula, PositionOrigin.CHOSEN)

                assertTrue(accepted)
                assertEquals("$generation, $status", status, fixture.app.bookByUuid[dracula]?.status?.name)
                assertEquals(listOf(MutationQueue.Kind.POSITION), fixture.queued().map { it.kind })
            } finally {
                fixture.tearDown()
            }
        }
    }

    /** A book whose status has reached the server is not filed again. */
    @Test
    fun filedOnceItHasDrained() = mainTest {
        val fixture = fixture(ServerGeneration.V3, listOf(SharedFixtures.book("Dracula", uuid = dracula, progress = 0.1)))
        try {
            fixture.app.writePosition(locator(0.2), 10.0, dracula, PositionOrigin.CHOSEN)
            assertEquals(status(Status.readingName).uuid, fixture.queuedStatus()?.second)
            fixture.drainAccepted()

            fixture.app.writePosition(locator(0.99), 20.0, dracula, PositionOrigin.CHOSEN)

            assertEquals(Status.readingName, fixture.app.bookByUuid[dracula]?.status?.name)
            assertEquals("the server moves it to Read itself", listOf(MutationQueue.Kind.POSITION), fixture.queued().map { it.kind })
        } finally {
            fixture.tearDown()
        }
    }

    /** A book finished before its status drains is filed Read, behind the position. */
    @Test
    fun finishedBeforeTheDrain() = mainTest {
        val fixture = fixture(ServerGeneration.V3, listOf(SharedFixtures.book("Dracula", uuid = dracula, progress = 0.1)))
        try {
            fixture.app.writePosition(locator(0.2), 10.0, dracula, PositionOrigin.CHOSEN)
            assertEquals(status(Status.readingName).uuid, fixture.queuedStatus()?.second)

            fixture.app.writePosition(locator(0.99), 20.0, dracula, PositionOrigin.CHOSEN)

            assertEquals(Status.readName, fixture.app.bookByUuid[dracula]?.status?.name)
            val queued = fixture.queued()
            assertEquals("the status is sent after the position", listOf(MutationQueue.Kind.POSITION, MutationQueue.Kind.STATUS), queued.map { it.kind })
            val position = IssaJson.decodeFromString(MutationDrain.PositionPayload.serializer(), queued[0].payload.decodeToString())
            assertEquals(20.0, position.timestamp, 0.0)
            assertEquals(status(Status.readName).uuid, fixture.queuedStatus()?.second)
            val persisted = fixture.store.allBooks().firstOrNull { it.uuid == dracula }
            assertEquals(Status.readName, persisted?.status?.name)
        } finally {
            fixture.tearDown()
        }
    }

    /** A status chosen by hand is not overridden by the rule. */
    @Test
    fun aChosenStatusStands() = mainTest {
        for (chosen in listOf(Status.toReadName, "Abandoned")) {
            val fixture = fixture(ServerGeneration.V3, listOf(SharedFixtures.book("Dracula", uuid = dracula, progress = 0.1)))
            try {
                fixture.app.writePosition(locator(0.2), 10.0, dracula, PositionOrigin.CHOSEN)
                assertEquals(status(Status.readingName).uuid, fixture.queuedStatus()?.second)
                val choice = statuses.firstOrNull { it.name == chosen } ?: Status(uuid = "status-abandoned", name = chosen)
                fixture.app.setStatus(choice, checkNotNull(fixture.app.bookByUuid[dracula]))
                val queuedChoice = checkNotNull(fixture.queuedStatus())
                assertEquals(choice.uuid, queuedChoice.second)

                fixture.app.writePosition(locator(0.99), 20.0, dracula, PositionOrigin.CHOSEN)

                assertEquals(choice, fixture.app.bookByUuid[dracula]?.status)
                val after = checkNotNull(fixture.queuedStatus())
                assertEquals("nothing should have been queued after the choice", queuedChoice.first.id, after.first.id)
                assertEquals(choice.uuid, after.second)
            } finally {
                fixture.tearDown()
            }
        }
    }

    /** The rule never moves a book back, and never queues the status it has. */
    @Test
    fun forwardOnly() = mainTest {
        val fixture = fixture(ServerGeneration.V3, listOf(SharedFixtures.book("Dracula", uuid = dracula, progress = 0.1)))
        try {
            fixture.app.writePosition(locator(0.99), 10.0, dracula, PositionOrigin.CHOSEN)
            val read = checkNotNull(fixture.queuedStatus())
            assertEquals(status(Status.readName).uuid, read.second)

            fixture.app.writePosition(locator(0.5), 20.0, dracula, PositionOrigin.CHOSEN)
            assertEquals("turned back, not unread", Status.readName, fixture.app.bookByUuid[dracula]?.status?.name)
            fixture.app.writePosition(locator(0.995), 30.0, dracula, PositionOrigin.CHOSEN)

            assertEquals(Status.readName, fixture.app.bookByUuid[dracula]?.status?.name)
            val after = checkNotNull(fixture.queuedStatus())
            assertEquals("nothing should have been queued after Read", read.first.id, after.first.id)
            assertEquals(read.second, after.second)
        } finally {
            fixture.tearDown()
        }
    }

    /** With no statuses loaded, the ones the cached books carry are written. */
    @Test
    fun coldLaunchFilesFromTheShelf() = mainTest {
        for ((progress, expected) in listOf(0.2 to Status.readingName, 0.99 to Status.readName)) {
            val fixture = fixture(
                null,
                listOf(
                    SharedFixtures.book("Dracula", uuid = dracula, progress = 0.1),
                    SharedFixtures.book("Bleak House", uuid = bleakHouse, status = Status.readingName),
                    SharedFixtures.book("Middlemarch", uuid = middlemarch, status = Status.readName),
                ),
            )
            try {
                fixture.app.statuses = emptyList()

                val accepted = fixture.app.writePosition(locator(progress), 10.0, dracula, PositionOrigin.CHOSEN)

                assertTrue(accepted)
                assertEquals(expected, fixture.app.bookByUuid[dracula]?.status?.name)
                val queued = fixture.queued()
                assertEquals(listOf(MutationQueue.Kind.POSITION, MutationQueue.Kind.STATUS), queued.map { it.kind })
                val sent = IssaJson.decodeFromString(MutationDrain.StatusPayload.serializer(), queued.last().payload.decodeToString())
                // `SharedFixtures` gives each status its name as its uuid, which is what the cached books carry.
                assertEquals(expected, sent.status)
            } finally {
                fixture.tearDown()
            }
        }
    }

    /** With no statuses loaded and none on the shelf, nothing is written. */
    @Test
    fun coldLaunchWithAnUnfiledShelf() = mainTest {
        val fixture = fixture(null, listOf(SharedFixtures.book("Dracula", uuid = dracula, progress = 0.1)))
        try {
            fixture.app.statuses = emptyList()

            fixture.app.writePosition(locator(0.2), 10.0, dracula, PositionOrigin.CHOSEN)

            assertNull(fixture.app.bookByUuid[dracula]?.status)
            assertEquals(listOf(MutationQueue.Kind.POSITION), fixture.queued().map { it.kind })
        } finally {
            fixture.tearDown()
        }
    }

    /** A refresh keeps a status still waiting in the queue. */
    @Test
    fun refreshKeepsAQueuedStatus() = mainTest {
        val fixture = fixture(
            null,
            listOf(
                SharedFixtures.book("Dracula (cached)", uuid = dracula, progress = 0.1),
                SharedFixtures.book("Bleak House (cached)", uuid = bleakHouse, status = Status.readingName),
            ),
        )
        try {
            val book = checkNotNull(fixture.app.bookByUuid[dracula])
            fixture.app.setStatus(status(Status.readingName), book)
            assertEquals("the write has to be waiting", listOf(MutationQueue.Kind.STATUS), fixture.queued().map { it.kind })

            fixture.app.refreshLibrary()

            assertNull(fixture.app.loadError)
            val refreshed = checkNotNull(fixture.app.bookByUuid[dracula])
            assertEquals("the refresh has to have landed for this to mean anything", "Dracula", refreshed.title)
            assertEquals(Status.readingName, refreshed.status?.name)
            assertNull(fixture.app.bookByUuid[bleakHouse]?.status)
        } finally {
            fixture.tearDown()
        }
    }

    /** Refreshing one book keeps a status still waiting in the queue. */
    @Test
    fun bookRefreshKeepsAQueuedStatus() = mainTest {
        val fixture = fixture(
            null,
            listOf(
                SharedFixtures.book("Dracula (cached)", uuid = dracula, progress = 0.1),
                SharedFixtures.book("Bleak House (cached)", uuid = bleakHouse, status = Status.readingName),
            ),
        )
        try {
            val book = checkNotNull(fixture.app.bookByUuid[dracula])
            fixture.app.setStatus(status(Status.readingName), book)

            fixture.app.refresh(book)
            fixture.app.refresh(checkNotNull(fixture.app.bookByUuid[bleakHouse]))

            val refreshed = checkNotNull(fixture.app.bookByUuid[dracula])
            assertEquals("the refresh has to have landed for this to mean anything", "Dracula", refreshed.title)
            assertEquals(Status.readingName, refreshed.status?.name)
            assertNull(fixture.app.bookByUuid[bleakHouse]?.status)
        } finally {
            fixture.tearDown()
        }
    }
}
