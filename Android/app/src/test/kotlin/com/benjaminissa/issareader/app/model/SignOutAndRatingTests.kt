package com.benjaminissa.issareader.app.model

import com.benjaminissa.issareader.app.AppSuite
import com.benjaminissa.issareader.app.ScriptedServer
import com.benjaminissa.issareader.app.SharedFixtures
import com.benjaminissa.issareader.app.TestTokens
import com.benjaminissa.issareader.app.close
import com.benjaminissa.issareader.app.mainTest
import com.benjaminissa.issareader.app.temporaryDirectory
import com.benjaminissa.issareader.app.testApp
import com.benjaminissa.issareader.app.testScope
import com.benjaminissa.issareader.app.waitUntil
import com.benjaminissa.issareader.core.IssaJson
import com.benjaminissa.issareader.core.download.BookContentService
import com.benjaminissa.issareader.core.networking.Endpoint
import com.benjaminissa.issareader.core.store.LibraryStore
import com.benjaminissa.issareader.core.sync.MutationDrain
import com.benjaminissa.issareader.core.sync.MutationQueue
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.async
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.UUID

/**
 * What must not survive a sign-out. Ported from `SignOutStateTests.swift`.
 */
class SignOutStateTest : AppSuite() {
    /** A pending deep link does not survive into the next account. */
    @Test
    fun pendingBookIsCleared() = mainTest {
        val scope = testScope()
        val app = testApp(scope)
        app.requestBook("11111111-1111-4111-8111-111111111111", AppModel.PendingBook.Destination.READ)
        assertNotNull("the link has to be armed for the test to mean anything", app.pendingBook)

        app.signOut(keepDownloads = true)
        assertNull(app.pendingBook)
        scope.close()
    }

    /** The catalogue and everything derived from it is dropped. */
    @Test
    fun catalogueStateIsCleared() = mainTest {
        val scope = testScope()
        val app = testApp(scope)
        app.ratings = app.ratings + ("11111111-1111-4111-8111-111111111111" to 4.0)

        app.signOut(keepDownloads = true)
        assertTrue(app.books.isEmpty())
        assertTrue(app.ratings.isEmpty())
        assertTrue(app.statuses.isEmpty())
        assertNull(app.loadError)
        scope.close()
    }

    /** A sign-out that keeps the downloads leaves them on the device, and listed. */
    @Test
    fun keptDownloadsStayOnTheDevice() = mainTest {
        val scope = testScope()
        val app = testApp(scope)
        val uuid = UUID.randomUUID().toString()
        val directory = BookContentService.defaultDirectory()
        directory.mkdirs()
        val file = BookContentService.localUrl(directory, uuid, BookContentService.Format.EBOOK)
        file.writeBytes(ByteArray(32))

        app.signOut(keepDownloads = true)

        assertTrue("a sign-out asked to keep the downloads deleted the app's own", file.exists())
        assertTrue("a download kept on the device was dropped from the shelves", uuid in app.downloadedUuids)
        scope.close()
    }

    /** Per-book reader styles are told to go too. */
    @Test
    fun perBookStylesAreNotified() = mainTest {
        val scope = testScope()
        val centre = SignOutCentre()
        val app = testApp(scope, centre = centre)
        var received = false
        val token = centre.observe { received = true }
        try {
            app.signOut(keepDownloads = true)
            assertTrue("PlaybackSettings.bookStyles is keyed by book uuid like the rest", received)
        } finally {
            token.close()
            scope.close()
        }
    }
}

/**
 * A rating keeps the reader's last choice, against an older rating still on
 * its way into the queue and against a refresh in flight. Ported from
 * `RatingRaceTests.swift`.
 */
class RatingRaceTest : AppSuite() {
    private val uuid = "66666666-6666-4666-8666-666666666666"

    private class Fixture(val app: AppModel, val server: ScriptedServer, val store: LibraryStore, val directory: File, val scope: CoroutineScope) {
        /** The queued rating: null when there is no row, a row whose rating may itself be null otherwise. */
        suspend fun queuedRating(uuid: String): Pair<Double?, Unit>? {
            val row = MutationQueue(store).use { it.pending() }.firstOrNull { it.kind == MutationQueue.Kind.RATING && it.bookUuid == uuid }
                ?: return null
            return IssaJson.decodeFromString(MutationDrain.RatingPayload.serializer(), row.payload.decodeToString()).rating to Unit
        }

        fun tearDown() {
            server.close()
            directory.deleteRecursively()
            scope.close()
        }
    }

    private fun fixture(): Fixture {
        val scope = testScope()
        val server = ScriptedServer()
        server.answer(Endpoint.books, json = listOf(ScriptedServer.book(uuid, "Dracula")))
        // The server holds no rating for the book.
        server.answer(Endpoint.userRatings, json = emptyList<Any>())
        val directory = temporaryDirectory("rating-race")
        val store = LibraryStore(server.url.toString(), directory)
        val tokens = TestTokens()
        val app = testApp(scope, keychain = tokens)
        app.useStore(store)
        app.session = server.session(storing = "token-A", keychain = tokens)
        app.books = listOf(SharedFixtures.book("Dracula", uuid = uuid))
        app.rebuildDerived()
        return Fixture(app, server, store, directory, scope)
    }

    /** An older rating that resumes after a newer one does not replace it in the queue. */
    @Test
    fun anOlderRatingDoesNotReplaceANewerOne() = mainTest {
        val fixture = fixture()
        try {
            fixture.server.refuseWrites()
            val app = fixture.app
            val book = checkNotNull(app.bookByUuid[uuid])
            val hold = FirstArrivalHold()
            app.beforeQueueingRating = { hold.arrive() }

            val older = fixture.scope.async { app.setRating(4.0, book) }
            assertTrue("the four has to be waiting to queue", waitUntil { hold.arrivals == 1 })
            app.setRating(5.0, book)
            hold.release()
            older.await()

            assertEquals("the older rating was queued last and replaced the newer one", 5.0, fixture.queuedRating(uuid)?.first)
            assertEquals(5.0, app.ratings[uuid])
            assertEquals(5.0, fixture.store.ratings()[uuid])
        } finally {
            fixture.tearDown()
        }
    }

    /** A rating set and sent while the library was being fetched is kept. */
    @Test
    fun aRatingSetDuringARefreshIsKept() = mainTest {
        val fixture = fixture()
        try {
            val app = fixture.app
            val book = checkNotNull(app.bookByUuid[uuid])
            fixture.server.hold(Endpoint.userRatings)

            val refreshing = fixture.scope.async { app.refreshLibrary() }
            assertTrue("the ratings fetch has to be in flight", waitUntil { fixture.server.held(Endpoint.userRatings) == 1 })
            app.setRating(5.0, book)
            assertNull("the server took the rating, so it has left the queue", fixture.queuedRating(uuid))
            fixture.server.release(Endpoint.userRatings)
            refreshing.await()

            assertEquals("an answer older than the reader's rating took it off the screen", 5.0, app.ratings[uuid])
        } finally {
            fixture.tearDown()
        }
    }
}

/** Holds the first arrival at a seam until released, and lets every later one straight through. Main-thread only. */
class FirstArrivalHold {
    var arrivals = 0
        private set
    private var released = false
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
