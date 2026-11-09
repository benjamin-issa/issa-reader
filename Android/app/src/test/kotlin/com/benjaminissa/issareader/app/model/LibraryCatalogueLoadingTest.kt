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
import com.benjaminissa.issareader.core.model.ReadiumLocator
import com.benjaminissa.issareader.core.networking.Endpoint
import com.benjaminissa.issareader.core.store.LibraryStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.async
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * A library that loses a row keeps the rest, and says so. The catalogue half of
 * `LibraryLoadingTests.swift`; the row-level rules are `CatalogueTest`'s.
 */
class LibraryCatalogueLoadingTest : AppSuite() {
    private val first = "11111111-1111-4111-8111-111111111111"
    private val library = listOf(
        first to "First",
        "22222222-2222-4222-8222-222222222222" to "Second",
        "33333333-3333-4333-8333-333333333333" to "Third",
    )
    private val uuids = library.map { it.first }

    private class Fixture(
        val app: AppModel,
        val server: ScriptedServer,
        val store: LibraryStore,
        val directory: File,
        val scope: CoroutineScope,
    ) {
        fun tearDown() {
            server.close()
            store.close()
            directory.deleteRecursively()
            scope.close()
        }
    }

    /** A row with one field the model cannot read, renamed as well so a copy kept can be told from one replaced. */
    private fun unreadable(uuid: String): Map<String, Any?> =
        ScriptedServer.book(uuid, "Changed on the server") + ("rating" to "five")

    private fun answerWithLibrary(server: ScriptedServer, bad: Set<String> = emptySet()) {
        server.answer(
            Endpoint.books,
            json = library.map { (uuid, title) -> if (uuid in bad) unreadable(uuid) else ScriptedServer.book(uuid, title) },
        )
    }

    /** Reader A with a real store, nothing held, and nothing fetched yet. */
    private suspend fun withAStore(): Fixture {
        val scope = testScope()
        val server = ScriptedServer()
        val defaults = SharedFixtures.scratchDefaults()
        defaults.putString(AppModel.accountKey(server.url), "reader-A")
        val tokens = TestTokens()
        val app = testApp(scope, keychain = tokens, defaults = defaults)
        val session = server.session(storing = "token-A", keychain = tokens)
        session.restore()
        app.session = session
        app.serverAddress = server.url.toString()
        app.phase = AppModel.Phase.READY
        val directory = temporaryDirectory("library-loading")
        val store = LibraryStore(server.url.toString(), directory)
        app.useStore(store)
        return Fixture(app, server, store, directory, scope)
    }

    /** The same, with the whole library already fetched once, in memory and on disk. */
    private suspend fun withTheLibraryHere(): Fixture {
        val fixture = withAStore()
        answerWithLibrary(fixture.server)
        fixture.app.refreshLibrary()
        assertEquals(library.size, fixture.app.books.size)
        assertTrue(waitUntil { fixture.store.allBooks().size == library.size })
        return fixture
    }

    private val locator = ReadiumLocator(
        href = "OEBPS/ch09.xhtml",
        type = "application/xhtml+xml",
        locations = ReadiumLocator.Locations(progression = 0.62, totalProgression = 0.62),
    )

    /**
     * The reported failure, at the level the reader met it: one book's
     * read-along being redone took the whole library down for the length of
     * the job. The first, a middle and the last row, because a loop that stops
     * or slips at a bad row only shows on some of them, and by identity,
     * because a count cannot tell which book survived.
     */
    @Test
    fun `a row that cannot be read keeps this device's copy of that book, and takes the rest`() = mainTest {
        for ((bad, title) in library) {
            val fixture = withTheLibraryHere()
            val app = fixture.app
            // Something the refresh has to bring in, so this can tell it ran.
            val other = uuids.first { it != bad }
            fixture.server.answer(
                Endpoint.books,
                json = library.map { (uuid, name) ->
                    when (uuid) {
                        bad -> unreadable(uuid)
                        other -> ScriptedServer.book(uuid, "Arrived")
                        else -> ScriptedServer.book(uuid, name)
                    }
                },
            )

            app.refreshLibrary()

            assertEquals("the rest of the library has to come in", "Arrived", app.bookByUuid[other]?.title)
            assertEquals("kept as it was", title, app.bookByUuid[bad]?.title)
            assertEquals("and where it was", uuids, app.books.map { it.uuid })
            assertNull(app.loadError)
            assertEquals("and the reader is told", 1, app.unreadableBookCount)
            assertFalse("and nothing may be swept on this answer", app.knowsWholeLibrary)

            assertTrue(waitUntil { fixture.store.book(other)?.title == "Arrived" })
            assertEquals("the stored row survived the replace", title, fixture.store.book(bad)?.title)

            // Dropped silently if the book had left `books`.
            app.recordPosition(locator, 1.0, bad)
            assertEquals(0.62, app.bookByUuid[bad]?.position?.locator?.totalProgression ?: 0.0, 0.0001)

            // And over as soon as the server's answer can be read.
            answerWithLibrary(fixture.server)
            app.refreshLibrary()
            assertTrue(app.knowsWholeLibrary)
            assertEquals(0, app.unreadableBookCount)
            fixture.tearDown()
        }
    }

    /** What is stored for a kept book may be newer than the copy in memory, and with its own row unreadable no later refresh would put a loss right. */
    @Test
    fun `a refresh leaves a book it could not read as the store holds it`() = mainTest {
        val fixture = withTheLibraryHere()
        val (bad, title) = library[1]
        // The memory's copy and the store's disagree, as they do when a
        // position is saved while a refresh is on its way.
        fixture.app.books = fixture.app.books.map { if (it.uuid == bad) it.copy(title = "Only in memory") else it }
        fixture.server.answer(
            Endpoint.books,
            json = listOf(ScriptedServer.book(first, "Arrived"), unreadable(bad), ScriptedServer.book(uuids[2], library[2].second)),
        )

        fixture.app.refreshLibrary()

        assertTrue(waitUntil { fixture.store.book(first)?.title == "Arrived" })
        assertEquals(title, fixture.store.book(bad)?.title)
        fixture.tearDown()
    }

    /** A fresh install has no copy to keep. */
    @Test
    fun `a first sync shows every book it can read`() = mainTest {
        val fixture = withAStore()
        val app = fixture.app
        answerWithLibrary(fixture.server, setOf(uuids[1]))

        app.refreshLibrary()

        assertEquals(listOf(uuids[0], uuids[2]), app.books.map { it.uuid })
        assertNull("a shelf with a gap is not a failed library", app.loadError)
        assertEquals("but the reader is told of the gap", 1, app.unreadableBookCount)
        assertFalse("a file for the book left out is not an orphan", app.knowsWholeLibrary)
        fixture.tearDown()
    }

    /** Two of three unreadable used to drop the answer, with the third book's position and status, and on a shelf nothing said so. */
    @Test
    fun `most of a library unreadable still brings in the rest, and says so`() = mainTest {
        val fixture = withTheLibraryHere()
        val app = fixture.app
        fixture.server.answer(
            Endpoint.books,
            json = listOf(unreadable(uuids[0]), ScriptedServer.book(uuids[1], "Arrived"), unreadable(uuids[2])),
        )

        app.refreshLibrary()

        assertEquals(listOf("First", "Arrived", "Third"), app.books.map { it.title })
        assertEquals(2, app.unreadableBookCount)
        assertNull(app.loadError)
        fixture.tearDown()
    }

    @Test
    fun `a library with no readable row reaches the reader as an error`() = mainTest {
        val fixture = withAStore()
        val app = fixture.app
        answerWithLibrary(fixture.server, uuids.toSet())

        app.refreshLibrary()

        assertTrue(app.books.isEmpty())
        assertNotNull(app.loadError)
        assertFalse(app.knowsWholeLibrary)
        fixture.tearDown()
    }

    /** The catalogue this came from can say what is not in the library again, so the sweep and the storage bar's claim come back with it. */
    @Test
    fun `a complete library is one this device can say what is missing from`() = mainTest {
        val fixture = withTheLibraryHere()
        assertTrue(fixture.app.knowsWholeLibrary)
        fixture.tearDown()
    }

    /**
     * What a launch has before its refresh comes back. A first sync that left
     * a book out wrote a shelf without it, and the claim used to default to
     * true: that book's files read as orphans on the next launch.
     */
    @Test
    fun `a shelf read from the store is not a library this device can vouch for`() = mainTest {
        val fixture = withAStore()
        fixture.app.books = listOf(SharedFixtures.book("Cached", uuid = first, progress = 0.1))
        assertNull(fixture.app.loadError)
        assertFalse(fixture.app.knowsWholeLibrary)
        fixture.tearDown()
    }

    @Test
    fun `a refresh that fails leaves the shelf and withdraws the claim`() = mainTest {
        val fixture = withTheLibraryHere()
        val app = fixture.app
        assertTrue(app.knowsWholeLibrary)
        fixture.server.answer(Endpoint.books, status = 500, json = mapOf("message" to "no"))

        app.refreshLibrary()

        assertEquals(library.size, app.books.size)
        assertNull("a shelf is on screen, so there is nothing to apologise for", app.loadError)
        assertFalse(app.knowsWholeLibrary)
        fixture.tearDown()
    }

    /** The store deletes nothing on this answer, and the shelf has to agree with it, or the book is gone until the next launch brings it back. */
    @Test
    fun `a row that cannot say which book it was leaves every book where it is`() = mainTest {
        val fixture = withTheLibraryHere()
        val app = fixture.app
        fixture.server.answer(
            Endpoint.books,
            json = listOf(ScriptedServer.book(first, "Arrived"), ScriptedServer.book(uuids[1], "No uuid") - "uuid"),
        )

        app.refreshLibrary()

        assertEquals("Arrived", app.bookByUuid[first]?.title)
        assertEquals(uuids.toSet(), app.books.map { it.uuid }.toSet())
        assertFalse(app.knowsWholeLibrary)
        assertTrue(waitUntil { fixture.store.book(first)?.title == "Arrived" })
        assertEquals(library.size, fixture.store.allBooks().size)
        fixture.tearDown()
    }

    /** One answer for both shelves, which is why it is tested here and not on each: Library and Reading draw it through `LibraryLoadOverlay`. */
    @Test
    fun `a shelf with nothing to show says the library is coming, then why it did not`() = mainTest {
        val fixture = withAStore()
        val app = fixture.app
        assertEquals(AppModel.LibraryLoad.Settled, app.libraryLoad)

        answerWithLibrary(fixture.server, uuids.toSet())
        fixture.server.hold(Endpoint.books)
        val failing = async { app.refreshLibrary() }
        assertTrue(waitUntil { fixture.server.held(Endpoint.books) == 1 })
        assertEquals(AppModel.LibraryLoad.Loading, app.libraryLoad)

        fixture.server.release(Endpoint.books)
        failing.await()
        assertTrue("expected the failure, got ${app.libraryLoad}", app.libraryLoad is AppModel.LibraryLoad.Failed)

        answerWithLibrary(fixture.server)
        app.refreshLibrary()
        assertEquals(AppModel.LibraryLoad.Settled, app.libraryLoad)
        assertEquals(library.size, app.books.size)
        fixture.tearDown()
    }
}
