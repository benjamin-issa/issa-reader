package com.benjaminissa.issareader.app.model

import com.benjaminissa.issareader.app.Answer
import com.benjaminissa.issareader.app.AppSuite
import com.benjaminissa.issareader.app.LifecycleServer
import com.benjaminissa.issareader.app.ScriptedServer
import com.benjaminissa.issareader.app.SharedFixtures
import com.benjaminissa.issareader.app.StubServer
import com.benjaminissa.issareader.app.TestTokens
import com.benjaminissa.issareader.app.close
import com.benjaminissa.issareader.app.mainTest
import com.benjaminissa.issareader.app.temporaryDirectory
import com.benjaminissa.issareader.app.testApp
import com.benjaminissa.issareader.app.testScope
import com.benjaminissa.issareader.app.waitUntil
import com.benjaminissa.issareader.core.IssaJson
import com.benjaminissa.issareader.core.Session
import com.benjaminissa.issareader.core.model.Status
import com.benjaminissa.issareader.core.networking.Endpoint
import com.benjaminissa.issareader.core.store.LibraryStore
import com.benjaminissa.issareader.core.sync.MutationDrain
import com.benjaminissa.issareader.core.sync.MutationQueue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.async
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.net.URI
import java.util.concurrent.atomic.AtomicInteger
import kotlin.time.Duration.Companion.seconds

/**
 * The library spinner stays up while any refresh for the account signed in is
 * still out. Ported from `LibraryLoadingTests.swift`.
 */
class LibraryLoadingTest : AppSuite() {
    private val first = "11111111-1111-4111-8111-111111111111"

    private class Fixture(val app: AppModel, val server: ScriptedServer, val scope: CoroutineScope) {
        fun tearDown() {
            server.close()
            scope.close()
        }
    }

    /** Reader A, signed in on a server of the test's own that serves one book, with every catalogue read held. */
    private suspend fun signedInAsA(): Fixture {
        val scope = testScope()
        val server = ScriptedServer()
        val defaults = SharedFixtures.scratchDefaults()
        defaults.putString(AppModel.accountKey(server.url), "reader-A")
        server.answer(Endpoint.books, json = listOf(ScriptedServer.book(first, "First")))
        val tokens = TestTokens()
        val app = testApp(scope, keychain = tokens, defaults = defaults)
        val session = server.session(storing = "token-A", keychain = tokens)
        session.restore()
        app.session = session
        app.serverAddress = server.url.toString()
        app.phase = AppModel.Phase.READY
        val state = session.state.value
        assertTrue("the fixture has to be signed in as reader A, not $state", state is Session.State.SignedIn && state.user.id == "reader-A")
        server.hold(Endpoint.books)
        return Fixture(app, server, scope)
    }

    /** Two overlapping refreshes keep the spinner up until both have come back. */
    @Test
    fun overlappingRefreshesKeepTheSpinnerUp() = mainTest {
        val fixture = signedInAsA()
        try {
            val app = fixture.app
            val launch = fixture.scope.async { app.refreshLibrary() }
            assertTrue(waitUntil { fixture.server.held(Endpoint.books) == 1 })
            assertTrue(app.isLoadingLibrary)
            val pull = fixture.scope.async { app.refreshLibrary() }
            assertTrue(waitUntil { fixture.server.held(Endpoint.books) == 2 })

            fixture.server.releaseOne(Endpoint.books)
            launch.await()
            assertTrue("the first refresh back took the spinner down over the second", app.isLoadingLibrary)

            fixture.server.releaseOne(Endpoint.books)
            pull.await()
            assertFalse("the spinner outlived every refresh", app.isLoadingLibrary)
            assertEquals("the refreshes have to have landed", "First", app.bookByUuid[first]?.title)
        } finally {
            fixture.tearDown()
        }
    }

    /** A departed account's refresh coming back leaves the arriving account's spinner up. */
    @Test
    fun aDepartedRefreshLeavesTheArrivingSpinnerUp() = mainTest {
        val fixture = signedInAsA()
        try {
            val app = fixture.app
            val departing = fixture.scope.async { app.refreshLibrary() }
            assertTrue(waitUntil { fixture.server.held(Endpoint.books) == 1 })
            val generation = app.catalogueGeneration
            // Reader B's token: a switch, whose library refresh is held as well.
            val arriving = fixture.scope.async { app.adopt("token-B") }
            assertTrue(waitUntil { fixture.server.held(Endpoint.books) == 2 })
            assertTrue("the adopt has to have been a switch", app.catalogueGeneration > generation)
            assertTrue(app.isLoadingLibrary)

            fixture.server.releaseOne(Endpoint.books)
            departing.await()
            assertTrue("the departed account's refresh took the arriving account's spinner down", app.isLoadingLibrary)
            assertTrue("and published nothing, which is what left the placeholder showing", app.books.isEmpty())

            fixture.server.releaseOne(Endpoint.books)
            arriving.await()
            assertFalse(app.isLoadingLibrary)
            assertNotNull("the arriving account's refresh has to have landed", app.bookByUuid[first])
        } finally {
            fixture.tearDown()
        }
    }
}

/**
 * Connecting to a different server starts from that server's library, not
 * from the last one's. Ported from `ServerSwitchTests.swift`: through
 * `prepareForServer`, the head of `connect`.
 */
class ServerSwitchTest : AppSuite() {
    private val book = "11111111-1111-4111-8111-111111111111"

    private class Fixture(
        val app: AppModel,
        val store: LibraryStore,
        val directory: File,
        val broadcasts: AtomicInteger,
        val server: StubServer,
        val scope: CoroutineScope,
    ) {
        fun tearDown() {
            server.close()
            directory.deleteRecursively()
            scope.close()
        }
    }

    /** A model signed into a server of its own, with everything a switch must drop seeded. */
    private suspend fun fixture(): Fixture {
        val scope = testScope()
        val broadcasts = AtomicInteger(0)
        val centre = SignOutCentre()
        centre.observe { broadcasts.incrementAndGet() }
        val server = StubServer { Answer(404) }
        val app = testApp(scope, centre = centre)
        val directory = temporaryDirectory("server-switch")
        val store = LibraryStore(server.url.toString(), directory)
        val shelf = listOf(SharedFixtures.book("Dracula", uuid = book, status = Status.readingName, progress = 0.7))
        store.replaceCatalogue(shelf)
        MutationQueue(store).use {
            it.enqueue(
                MutationQueue.Kind.STATUS, book,
                IssaJson.encodeToString(MutationDrain.StatusPayload.serializer(), MutationDrain.StatusPayload("status-read")).encodeToByteArray(),
            )
        }
        app.useStore(store)
        app.session = server.session()
        app.books = shelf
        app.rebuildDerived()
        app.statuses = listOf(Status(uuid = "status-reading", name = Status.readingName))
        app.ratings = app.ratings + (book to 4.0)
        app.positionGuards[AppModel.positionGuardKey(book, isAudioScaled = false)] = AppModel.seededGuard(shelf[0], isAudioScaled = false)
        app.requestBook(book, AppModel.PendingBook.Destination.READ)
        return Fixture(app, store, directory, broadcasts, server, scope)
    }

    /** A different server starts from an empty library. */
    @Test
    fun anotherServerStartsEmpty() = mainTest {
        val fixture = fixture()
        try {
            val app = fixture.app
            assertNotNull("the link has to be armed for this to mean anything", app.pendingBook)
            val generation = app.catalogueGeneration

            app.prepareForServer(URI("https://second.storyteller.test"))

            assertEquals("a refresh of the first server's in flight would publish into the second's library", generation + 1, app.catalogueGeneration)
            assertTrue("the first server's catalogue was shown as the second's", app.books.isEmpty())
            assertTrue(app.bookByUuid.isEmpty())
            assertTrue(app.statuses.isEmpty())
            assertTrue(app.ratings.isEmpty())
            assertTrue("the first server's marks would refuse the second's positions", app.positionGuards.isEmpty())
            assertNull("a widget tap for the first server's book opened in the second's", app.pendingBook)
        } finally {
            fixture.tearDown()
        }
    }

    /** Leaving a server keeps its store and signs nobody out. */
    @Test
    fun leavingAServerIsNotASignOut() = mainTest {
        val fixture = fixture()
        try {
            fixture.app.prepareForServer(URI("https://other.storyteller.test"))

            assertEquals("the first server's cached catalogue was deleted", 1, fixture.store.allBooks().size)
            assertEquals("the first server's unsent write was thrown away", 1, MutationQueue(fixture.store).use { it.pending() }.size)
            assertEquals("per-book styles, trims and question indexes were cleared for an account still signed in", 0, fixture.broadcasts.get())
        } finally {
            fixture.tearDown()
        }
    }

    /** The same server keeps its library. */
    @Test
    fun theSameServerKeepsItsLibrary() = mainTest {
        val fixture = fixture()
        try {
            val generation = fixture.app.catalogueGeneration

            fixture.app.prepareForServer(fixture.server.url)

            assertEquals(generation, fixture.app.catalogueGeneration)
            assertEquals(1, fixture.app.books.size)
            assertEquals(4.0, fixture.app.ratings[book])
            assertNotNull(fixture.app.pendingBook)
        } finally {
            fixture.tearDown()
        }
    }

    /** The first connect has nothing to leave. */
    @Test
    fun theFirstConnectLeavesNothing() = mainTest {
        val scope = testScope()
        val app = testApp(scope)
        app.requestBook(book, AppModel.PendingBook.Destination.READ)
        val generation = app.catalogueGeneration

        app.prepareForServer(URI("https://first-launch.storyteller.test"))

        assertEquals(generation, app.catalogueGeneration)
        assertNotNull("the widget tap that launched the app was dropped", app.pendingBook)
        scope.close()
    }
}

/**
 * A refresh started on the server being left publishes nothing into the next
 * one's library. Ported from `ServerSwitchRefreshTests.swift`.
 */
class ServerSwitchRefreshTest : AppSuite() {
    /** A refresh begun while leaving a server publishes nothing for the next one. */
    @Test
    fun aRefreshBegunWhileLeavingAServerPublishesNothing() = mainTest {
        val fixture = HandOverFixture.storing("token-A")
        val other = LifecycleServer()
        val otherDirectory = temporaryDirectory("server-switch-refresh")
        try {
            val app = fixture.app
            app.currentBookPublisher = CurrentBookPublisher(fixture.scope)
            app.resumeStoredSession()
            assertEquals("First, for reader-A", app.bookByUuid[LifecycleServer.first]?.title)

            // `connect` to the second server: first the exit from the first.
            app.prepareForServer(other.url)
            assertTrue(app.books.isEmpty())

            // A refresh, in the window before the new session and store are in place.
            fixture.server.hold(Endpoint.books)
            val refreshing = fixture.scope.async { app.refreshLibrary() }
            waitUntil(2.seconds) { fixture.server.held(Endpoint.books) == 1 }

            // The rest of `connect`: the second server's session — a first
            // sign-in, so no token yet — and its store.
            val otherStore = LibraryStore(other.url.toString(), otherDirectory)
            app.session = other.session()
            app.useStore(otherStore)
            fixture.server.release(Endpoint.books)
            refreshing.await()

            assertTrue("the first server's catalogue was shown as the second's library", app.books.isEmpty())
            val written = waitUntil(1.seconds) { runCatching { otherStore.allBooks() }.getOrDefault(emptyList()).isNotEmpty() }
            assertFalse("the first server's catalogue was written into the second's store", written)
        } finally {
            other.close()
            otherDirectory.deleteRecursively()
            fixture.tearDown()
        }
    }
}
