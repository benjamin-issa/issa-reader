package com.benjaminissa.issareader.app.local

import com.benjaminissa.issareader.app.AppSuite
import com.benjaminissa.issareader.app.LocalFixtures
import com.benjaminissa.issareader.app.PlaybackSettingsForTests
import com.benjaminissa.issareader.app.RecordingPersistence
import com.benjaminissa.issareader.app.SharedFixtures
import com.benjaminissa.issareader.app.close
import com.benjaminissa.issareader.app.mainTest
import com.benjaminissa.issareader.app.testApp
import com.benjaminissa.issareader.app.testScope
import com.benjaminissa.issareader.app.waitUntil
import com.benjaminissa.issareader.app.model.AppModel
import com.benjaminissa.issareader.app.model.RootScreen
import com.benjaminissa.issareader.app.reader.ReaderModel
import kotlinx.coroutines.Job
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.time.Duration.Companion.seconds

/**
 * Where a reader with no server lands, and what is saved when the app goes to
 * the background while signed out. Ported from `LocalBooksRootTests.swift`.
 */
class LocalBooksRootTest : AppSuite() {
    /** A launch opens on the list while it has books, and on sign-in when it has none. */
    @Test
    fun launchRule() {
        val defaults = SharedFixtures.scratchDefaults()
        val route = LocalBooksRoute(defaults)
        route.showsListSignedOut = true

        route.libraryLoaded(hasBooks = true)
        assertTrue("a reader with books lands on them", route.showsListSignedOut)
        assertTrue("on every later launch too", LocalBooksRoute(defaults).showsListSignedOut)

        route.libraryLoaded(hasBooks = false)
        assertFalse("an empty list is not the root on a later launch", route.showsListSignedOut)
    }

    /** Signing in hands the root back to the library; signing out returns to the books. */
    @Test
    fun phaseRule() {
        val route = LocalBooksRoute(SharedFixtures.scratchDefaults())
        route.showsListSignedOut = true

        route.phaseChanged(AppModel.Phase.SIGNING_IN, AppModel.Phase.READY, hasBooks = true)
        assertFalse(route.showsListSignedOut)
        route.phaseChanged(AppModel.Phase.READY, AppModel.Phase.CHOOSE_SERVER, hasBooks = true)
        assertTrue("signed out with books here, the app opens on them", route.showsListSignedOut)
        route.phaseChanged(AppModel.Phase.READY, AppModel.Phase.CHOOSE_SERVER, hasBooks = false)
        assertFalse("and on sign-in when there are none", route.showsListSignedOut)
        // A connect that fails goes from signing in back to the form: not a sign-out.
        route.showsListSignedOut = true
        route.phaseChanged(AppModel.Phase.SIGNING_IN, AppModel.Phase.CHOOSE_SERVER, hasBooks = false)
        assertTrue(route.showsListSignedOut)
    }

    /** A book, a missing file or an import in flight is something on the list. */
    @Test
    fun hasAnything() = mainTest {
        val scope = testScope()
        val local = LocalFixtures(scope)
        try {
            assertFalse(local.library.hasAnything)
            local.importAndWait(local.pick("alice"))
            assertTrue(local.library.hasAnything)
        } finally {
            local.tearDown()
            scope.close()
        }
    }

    /**
     * An old undo does not reach a later removal: a removal a later one has
     * carried out cannot be taken back by name, and takes back neither the
     * later removal nor a book already deleted. (Swift's undo-manager half is
     * not ported; see PORTING.md.)
     */
    @Test
    fun staleUndoIsHarmless() = mainTest {
        val scope = testScope()
        val local = LocalFixtures(scope)
        try {
            local.importAndWait(local.pick("alice"))
            local.importAndWait(local.pick("readalong"))
            val first = checkNotNull(local.library.books.firstOrNull { it.title.startsWith("Alice") })
            val second = checkNotNull(local.library.books.firstOrNull { !it.title.startsWith("Alice") })

            local.library.remove(listOf(first.uuid))
            // A second removal carries out the first.
            local.library.remove(listOf(second.uuid))
            local.library.undoRemoval(listOf(first.uuid))

            assertEquals("the stale undo took back the wrong removal", listOf(second.uuid), local.library.pendingRemoval?.books?.map { it.uuid })
            assertNull("a removal already carried out came back", local.library.book(first.uuid))
        } finally {
            local.tearDown()
            scope.close()
        }
    }

    /**
     * Signed out, going to the background saves an open book from the
     * reader's files: what the root's lifecycle handler runs
     * (`AppGraph`'s background flush is `flushOpenReaders`).
     */
    @Test
    fun suspendFlushesSignedOut() = mainTest {
        val scope = testScope()
        val persistence = RecordingPersistence(accepts = true)
        try {
            val app = testApp(scope)
            app.phase = AppModel.Phase.CHOOSE_SERVER
            val model = app.reader(persistence.book, persistence)
            model.open(LocalReaderOpenTest.page)
            assertEquals(ReaderModel.Phase.Ready, model.phase)
            assertEquals(0, persistence.positions)

            app.flushOpenReaders()

            assertTrue(
                "the open local book was not saved on the way to the background",
                waitUntil(5.seconds) { persistence.positions > 0 },
            )
        } finally {
            persistence.tearDown()
            scope.close()
        }
    }
}

/**
 * The joins between the local library and the rest of the app. Ported from
 * `LocalBooksWiringTests.swift`, less the answer notification's routing,
 * which is the Ask port's.
 */
class LocalBooksWiringTest : AppSuite() {
    private val uuid = "33333333-3333-4333-8333-333333333333"

    /** The wiring hands the local library to the app at launch. */
    @Test
    fun wiringHandsTheLibraryOver() = mainTest {
        val scope = testScope()
        val local = LocalFixtures(scope)
        try {
            val app = testApp(scope)
            val settings = PlaybackSettingsForTests.make()
            LocalBooksWiring.connect(app, local.library, settings, ask = null, scope = scope)
            assertNotNull("a removed book's reader would be left playing", local.library.onRemove)
            assertNotNull("a removed book's index, style and level would stay", local.library.onForget)
            assertTrue("the local library never loaded", waitUntil(10.seconds) { local.library.isLoaded })
            app.localBooksLoaded()

            local.library.setBooksForTesting(listOf(SharedFixtures.book("Dracula", uuid = uuid)))
            assertTrue("an account's exit would not know which books are the device's", uuid in app.localBookUuids())
            assertEquals(local.library.uuids, app.localBookUuids())
        } finally {
            local.tearDown()
            scope.close()
        }
    }

    /** The list's place as the root is remembered, and a book opens by uuid. */
    @Test
    fun routeRemembers() {
        val defaults = SharedFixtures.scratchDefaults()
        val route = LocalBooksRoute(defaults)
        assertFalse(route.showsListSignedOut)
        route.showsListSignedOut = true
        assertTrue(LocalBooksRoute(defaults).showsListSignedOut)
        route.open(uuid)
        assertEquals(uuid, route.openBook)
    }
}

/**
 * What a window's root shows, and what happens to a book from the reader's
 * files open over it. Ported from `RootWindowTests.swift`: the root's
 * decisions, without the hosted SwiftUI window.
 */
class RootWindowTest : AppSuite() {
    /** Every signed-out phase is the one sign-in screen, or the books from Files. */
    @Test
    fun signedOutPhasesShareOneScreen() {
        for (phase in listOf(AppModel.Phase.EXPIRED, AppModel.Phase.SIGNING_IN, AppModel.Phase.CHOOSE_SERVER)) {
            assertEquals("$phase", RootScreen.SIGN_IN, RootScreen.forPhase(phase, showsListSignedOut = false))
            assertEquals("$phase", RootScreen.LOCAL_BOOKS, RootScreen.forPhase(phase, showsListSignedOut = true))
        }
        assertEquals(RootScreen.LIBRARY, RootScreen.forPhase(AppModel.Phase.READY, showsListSignedOut = true))
        assertEquals(RootScreen.LAUNCHING, RootScreen.forPhase(AppModel.Phase.LAUNCHING, showsListSignedOut = true))
    }

    /** R-42: a book removed while its reader is open takes the reader with it. */
    @Test
    fun removedBookClosesItsReader() = mainTest {
        val scope = testScope()
        val local = LocalFixtures(scope)
        var watching: Job? = null
        try {
            local.library.load()
            local.importAndWait(local.pick("alice"))
            val book = checkNotNull(local.library.books.firstOrNull())
            val app = testApp(scope)
            app.phase = AppModel.Phase.CHOOSE_SERVER
            val route = LocalBooksRoute(SharedFixtures.scratchDefaults())
            watching = route.observe(app, local.library, scope)

            route.open(book.uuid)
            assertEquals(book.uuid, route.openBook)

            local.library.remove(listOf(book.uuid))

            assertTrue("the window was left on a reader for a book that is gone", waitUntil(5.seconds) { route.openBook == null })
        } finally {
            watching?.cancel()
            local.tearDown()
            scope.close()
        }
    }

    /** R-43: a server book's link takes down the local reader to be seen. */
    @Test
    fun serverLinkClosesTheLocalReader() = mainTest {
        val scope = testScope()
        val local = LocalFixtures(scope)
        try {
            local.library.load()
            local.importAndWait(local.pick("alice"))
            val book = checkNotNull(local.library.books.firstOrNull())
            val app = testApp(scope)
            val server = SharedFixtures.book("Dracula", uuid = "server-dracula")
            app.books = listOf(server)
            app.rebuildDerived()
            app.phase = AppModel.Phase.READY
            val route = LocalBooksRoute(SharedFixtures.scratchDefaults())
            route.open(book.uuid)

            app.requestBook(server.uuid, AppModel.PendingBook.Destination.DETAILS)
            val taken = route.takePendingBook(app)

            assertEquals("the link was never taken", server.uuid, taken?.first?.uuid)
            assertNull(app.pendingBook)
            assertNull("the server book was pushed underneath the local reader", route.openBook)
        } finally {
            local.tearDown()
            scope.close()
        }
    }
}
