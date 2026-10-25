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
import com.benjaminissa.issareader.core.model.ReadiumLocator
import com.benjaminissa.issareader.core.networking.Endpoint
import com.benjaminissa.issareader.core.store.LibraryStore
import com.benjaminissa.issareader.core.sync.MutationQueue
import com.benjaminissa.issareader.core.sync.PositionOrigin
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/**
 * The book screen's refresh follows a book restarted on another device.
 * Ported from `BookScreenRefreshTests.swift`: through `refresh(book)` and
 * `writePosition` against [ScriptedServer], with a real store and queue.
 */
class BookScreenRefreshTest : AppSuite() {
    private val uuid = "33333333-3333-4333-8333-333333333333"

    private fun locator(progress: Double) = ReadiumLocator(
        href = "OEBPS/ch09.xhtml", type = "application/xhtml+xml",
        locations = ReadiumLocator.Locations(progression = progress, totalProgression = progress),
    )

    /** A lower, newer server position taken by the book screen lets the next derived write through. */
    @Test
    fun aRestartElsewhereReseedsTheGuard() = mainTest {
        val scope = testScope()
        val server = ScriptedServer()
        val directory = temporaryDirectory("book-screen")
        try {
            val store = LibraryStore(server.url.toString(), directory)
            val tokens = TestTokens()
            val app = testApp(scope, keychain = tokens)
            app.useStore(store)
            app.session = server.session(storing = "token-A", keychain = tokens)
            val book = SharedFixtures.book("Dracula", uuid = uuid, progress = 0.9, positionTimestamp = 1_000.0)
            app.books = listOf(book)
            app.rebuildDerived()
            // Read to 0.9 here: the guard for the text clock holds that mark.
            assertTrue(app.writePosition(locator(0.9), 1_000.0, uuid, PositionOrigin.CHOSEN))
            val key = AppModel.positionGuardKey(uuid, isAudioScaled = false)
            val before = checkNotNull(app.positionGuards[key]?.highWater)
            assertTrue(abs(before - 0.9) < 0.0001)

            // Restarted on another device: the server now says 0.02, written later.
            server.answer(Endpoint.book(uuid), json = ScriptedServer.book(uuid, "Dracula", progress = 0.02, timestamp = 2_000.0))
            app.refresh(book)
            val adopted = checkNotNull(app.bookByUuid[uuid]?.progress)
            assertTrue("the refresh has to have taken the restart", abs(adopted - 0.02) < 0.0001)

            // Reading on from the restarted place.
            val accepted = app.writePosition(locator(0.03), 2_100.0, uuid, PositionOrigin.DERIVED)

            assertTrue("the guard still held the old mark and refused the restarted book", accepted)
            val progress = app.bookByUuid[uuid]?.progress
            assertTrue(progress?.let { abs(it - 0.03) < 0.0001 } == true)
            val queued = MutationQueue(store).use { it.pending() }.filter { it.kind == MutationQueue.Kind.POSITION }
            assertTrue("the server takes every write, so an accepted one has been sent", queued.isEmpty())
            assertTrue(server.requests().any { it.method == "POST" && it.path == Endpoint.positions(uuid) })
        } finally {
            server.close()
            directory.deleteRecursively()
            scope.close()
        }
    }

    /** A refresh that changes nothing does not rebuild the catalogue. */
    @Test
    fun anUnchangedBookDoesNotRebuild() = mainTest {
        val scope = testScope()
        val server = ScriptedServer()
        val directory = temporaryDirectory("book-screen")
        try {
            val store = LibraryStore(server.url.toString(), directory)
            val tokens = TestTokens()
            val app = testApp(scope, keychain = tokens)
            app.useStore(store)
            app.session = server.session(storing = "token-A", keychain = tokens)
            val book = SharedFixtures.book("Dracula", uuid = uuid, progress = 0.5, positionTimestamp = 1_000.0)
            app.books = listOf(book)
            app.rebuildDerived()
            server.answer(Endpoint.book(uuid), json = ScriptedServer.book(uuid, "Dracula", progress = 0.5, timestamp = 1_000.0))

            // The first answer may change the row; what it settles on, the second must keep.
            app.refresh(book)
            val rebuilds = app.derivedRebuilds
            app.refresh(book)
            app.refresh(book)

            assertEquals("an answer that agrees with the row is not news", rebuilds, app.derivedRebuilds)

            // And one that disagrees still is.
            server.answer(Endpoint.book(uuid), json = ScriptedServer.book(uuid, "Dracula", progress = 0.8, timestamp = 2_000.0))
            app.refresh(book)
            assertTrue(app.derivedRebuilds > rebuilds)
            assertTrue(app.bookByUuid[uuid]?.progress?.let { abs(it - 0.8) < 0.0001 } == true)
        } finally {
            server.close()
            directory.deleteRecursively()
            scope.close()
        }
    }
}

/** Proof that the suites reach the app model. Ported from `AppModelReachabilityTests.swift`. */
class AppModelReachabilityTest : AppSuite() {
    /** The app model can be built and reports its launch phase. */
    @Test
    fun buildsAnAppModel() = mainTest {
        val scope = testScope()
        val app = testApp(scope)
        assertEquals("a fresh model has not connected to anything yet", AppModel.Phase.LAUNCHING, app.phase)
        assertTrue(app.books.isEmpty())
        scope.close()
    }
}
