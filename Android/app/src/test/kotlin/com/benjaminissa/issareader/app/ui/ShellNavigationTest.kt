package com.benjaminissa.issareader.app.ui

import androidx.activity.ComponentActivity
import com.benjaminissa.issareader.app.TestMedia
import com.benjaminissa.issareader.app.local.LocalBooksRoute
import com.benjaminissa.issareader.app.local.LocalLibrary
import com.benjaminissa.issareader.core.InMemoryKeyValueStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import java.io.File
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isSelectable
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import com.benjaminissa.issareader.app.model.AppModel
import com.benjaminissa.issareader.app.ui.fixture.AppDriver
import com.benjaminissa.issareader.app.ui.fixture.FixtureLibrary
import com.benjaminissa.issareader.app.ui.fixture.FixtureServer
import com.benjaminissa.issareader.core.download.BookContentService
import com.benjaminissa.issareader.core.sync.LibraryArrangement
import com.benjaminissa.issareader.app.RecordingPersistence
import com.benjaminissa.issareader.app.ui.reader.LocalReaderBook
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.net.URI

/**
 * The shell's routes, driven as a reader drives them: what a link opens, what
 * a tab tap does, where Back lands, and the undo for a removed download.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(qualifiers = "w402dp-h874dp-xxhdpi")
class ShellNavigationTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @get:Rule val temp = TemporaryFolder()

    private val driver by lazy { AppDriver(compose, temp.root, "build/sweep/shell-timed-out.png") }

    private fun showing(tag: String): Boolean = driver.exists(hasTestTag(tag))

    @Test
    fun `the app opens on the Reading tab`() {
        driver.launch(signedIn = true)
        assertTrue(showing("screen.reading"))
        assertTrue(showing("card.continue"))
    }

    @Test
    fun `a book link opens the reader over the book's page, and Back lands on the page`() {
        val app = driver.launch(signedIn = true).app
        assertTrue(app.open(URI("issareader://book/${FixtureLibrary.READALONG_UUID}")))
        driver.waitForNode(hasTestTag("screen.reader"))
        driver.settle()
        assertFalse("the tabs are under the reader", showing("screen.reading"))
        assertNull(app.pendingBook)

        compose.runOnUiThread { compose.activity.onBackPressedDispatcher.onBackPressed() }
        driver.waitForNode(hasTestTag("screen.bookDetail"))
        driver.settle()
        assertFalse(showing("screen.reader"))
        assertTrue(driver.exists(hasText("Peter and Wendy")))
    }

    @Test
    fun `the Continue card resumes the book in the reader`() {
        driver.launch(signedIn = true)
        compose.onNode(hasTestTag("card.continue")).performClick()
        driver.waitForNode(hasTestTag("screen.reader"))
    }

    @Test
    fun `each tab keeps its own pages`() {
        val app = driver.launch(signedIn = true).app
        app.requestBook(TIME_WAR, AppModel.PendingBook.Destination.DETAILS)
        driver.waitForNode(hasTestTag("screen.bookDetail"))

        driver.tab("Library")
        assertTrue(showing("screen.library"))
        assertFalse(showing("screen.bookDetail"))

        driver.tab("Reading")
        assertTrue("the Reading tab's page came back with it", showing("screen.bookDetail"))
    }

    @Test
    fun `tapping the tab that is showing goes back to its first screen`() {
        val app = driver.launch(signedIn = true).app
        driver.tab("Library")
        app.requestBook(TIME_WAR, AppModel.PendingBook.Destination.DETAILS)
        driver.waitForNode(hasTestTag("screen.bookDetail"))
        driver.tab("Library")
        assertTrue(showing("screen.library"))
        assertFalse(showing("screen.bookDetail"))
    }

    @Test
    fun `a See all on the Reading tab opens that shelf's grid in the Library`() {
        val app = driver.launch(signedIn = true).app
        // Up next's: the first "See all" on the tab.
        compose.onAllNodes(hasText("See all"))[0].performClick()
        driver.settle()
        assertTrue(showing("screen.library"))
        assertEquals(AppModel.LibraryMode.ALL, app.libraryMode)
        assertEquals(LibraryArrangement.Shelf.TO_READ, app.arrangement.shelf)
        assertTrue(showing("grid.library"))
    }

    /** Opens the Peter and Wendy reader by a link and waits for it to be up over its page. */
    private fun openReaderOnPeterAndWendy(app: AppModel) {
        assertTrue(app.open(URI("issareader://book/${FixtureLibrary.READALONG_UUID}")))
        driver.waitForNode(hasTestTag("screen.reader"))
        driver.settle()
    }

    /** A link for [uuid] arriving with another book's reader up: that book's reader replaces it, and Back lands on its page. */
    private fun linkReplacesTheOpenReader(uuid: String, title: String) {
        val app = driver.launch(signedIn = true).app
        openReaderOnPeterAndWendy(app)

        app.requestBook(uuid, AppModel.PendingBook.Destination.READ)
        driver.waitFor { app.pendingBook == null }
        driver.settle()
        assertTrue("the link's reader is up", showing("screen.reader"))

        compose.runOnUiThread { compose.activity.onBackPressedDispatcher.onBackPressed() }
        driver.waitForNode(hasTestTag("screen.bookDetail"))
        driver.settle()
        assertFalse("the first book's reader was left under the new one", showing("screen.reader"))
        assertTrue("Back landed on the link's book", driver.exists(hasText(title)))
        assertFalse("not on the first book's page", driver.exists(hasText("Peter and Wendy")))
    }

    @Test
    fun `a link for a middle book replaces the reader that is open`() =
        linkReplacesTheOpenReader(TIME_WAR, "This Is How You Lose the Time War")

    @Test
    fun `a link for the last book replaces the reader that is open`() =
        linkReplacesTheOpenReader(SONGBIRDS, "The Ballad of Songbirds and Snakes")

    @Test
    fun `a reader opened and closed after See all stays where it was`() {
        val app = driver.launch(signedIn = true).app
        compose.onAllNodes(hasText("See all"))[0].performClick()
        driver.settle()
        assertTrue(showing("screen.library"))

        driver.tab("Reading")
        assertTrue(showing("screen.reading"))
        compose.onNode(hasTestTag("card.continue")).performClick()
        driver.waitForNode(hasTestTag("screen.reader"))
        driver.settle()
        compose.runOnUiThread { compose.activity.onBackPressedDispatcher.onBackPressed() }
        driver.waitFor { !showing("screen.reader") }
        driver.settle()
        assertTrue("the Continue card's book page is where Back lands", showing("screen.bookDetail"))
        assertFalse("closing the reader sent the app to the Library", showing("screen.library"))
    }

    @Test
    fun `a link that opens a book page after See all keeps the page through the reader's close`() {
        val app = driver.launch(signedIn = true).app
        compose.onAllNodes(hasText("See all"))[0].performClick()
        driver.settle()
        app.requestBook(TIME_WAR, AppModel.PendingBook.Destination.READ)
        driver.waitForNode(hasTestTag("screen.reader"))
        driver.settle()
        compose.runOnUiThread { compose.activity.onBackPressedDispatcher.onBackPressed() }
        driver.waitFor { !showing("screen.reader") }
        driver.settle()
        assertTrue("the book page the link pushed was popped", showing("screen.bookDetail"))
    }

    @Test
    fun `a link for a book the library does not hold yet waits for it`() {
        val app = driver.launch(signedIn = true).app
        val late = FixtureLibrary.books.first().copy(uuid = "77777777-7777-4777-8777-777777777777", title = "A Late Arrival")
        app.requestBook(late.uuid, AppModel.PendingBook.Destination.DETAILS)
        driver.settle()
        assertEquals("the request was dropped", late.uuid, app.pendingBook?.uuid)
        assertFalse(showing("screen.bookDetail"))

        compose.runOnUiThread {
            app.books = app.books + late
            app.rebuildDerived()
        }
        driver.waitFor { app.pendingBook == null }
        driver.waitForNode(hasTestTag("screen.bookDetail"))
        assertTrue(driver.exists(hasText("A Late Arrival")))
    }

    /** A local-book fixture: two books from the reader's files, on the route a window of the app has. */
    private fun launchWithLocalBooks(): Pair<AppModel, LocalBooksRoute> {
        val local = LocalLibrary(
            root = File(temp.root, "Local"),
            storeDirectory = File(temp.root, "Store"),
            scope = CoroutineScope(SupervisorJob() + Dispatchers.Main),
            mediaSupport = TestMedia,
            contentResolver = null,
        )
        local.setBooksForTesting(persistences.map { it.book })
        val route = LocalBooksRoute(InMemoryKeyValueStore())
        // Each book opens in the real reader, over its own persistence, so
        // which book's reader is on screen can be told by the book it shows.
        val byUuid = persistences.associateBy { it.book.uuid }
        val opened = driver.launch(
            signedIn = true,
            local = local,
            localRoute = route,
            localBook = { uuid -> byUuid[uuid]?.let { LocalReaderBook(it.book, it) } },
        )
        return opened.app to route
    }

    /** Three books that open, so a middle one and the last can be asked for, not only the first. */
    private val persistences by lazy { List(3) { RecordingPersistence(accepts = true) } }
    private val first get() = persistences[0].book.uuid
    private val middle get() = persistences[1].book.uuid
    private val last get() = persistences[2].book.uuid

    @After
    fun tearDownBooks() {
        if (persistences.isNotEmpty()) persistences.forEach { it.tearDown() }
    }

    @Test
    fun `a link that pops a local reader leaves its book free to be opened again`() {
        val (app, route) = launchWithLocalBooks()
        val book = middle
        route.open(book)
        driver.waitForNode(hasTestTag("screen.reader"))
        driver.settle()

        app.requestBook(TIME_WAR, AppModel.PendingBook.Destination.DETAILS)
        driver.waitForNode(hasTestTag("screen.bookDetail"))
        driver.settle()
        assertFalse(showing("screen.reader"))
        assertNull("the route still holds the popped book", route.openBook)

        route.open(book)
        driver.waitForNode(hasTestTag("screen.reader"))
    }

    /** Which book's reader is on screen, by the book it says it shows, not just that one is. */
    private fun shownBook(app: AppModel): String? = app.visibleReaderUuid

    @Test
    fun `a local book asked for while a server reader is open replaces it`() {
        val (app, route) = launchWithLocalBooks()
        openReaderOnPeterAndWendy(app)
        assertEquals(FixtureLibrary.READALONG_UUID, shownBook(app))

        val asked = last
        route.open(asked)
        driver.waitFor { shownBook(app) == asked }
        driver.settle()
        assertEquals("the local book is the one on screen", asked, shownBook(app))

        compose.runOnUiThread { compose.activity.onBackPressedDispatcher.onBackPressed() }
        driver.waitFor { !showing("screen.reader") }
        driver.settle()
        assertFalse("the server reader was left under the local one", showing("screen.reader"))
    }

    private fun aLocalBookReplacesAnotherLocalBook(first: String, second: String) {
        val (app, route) = launchWithLocalBooks()
        route.open(first)
        driver.waitFor { shownBook(app) == first }
        driver.settle()
        route.open(second)
        driver.waitFor { shownBook(app) == second }
        driver.settle()
        assertEquals("the second book is the one on screen", second, shownBook(app))
        assertEquals(second, route.openBook)

        compose.runOnUiThread { compose.activity.onBackPressedDispatcher.onBackPressed() }
        driver.waitFor { !showing("screen.reader") }
        driver.settle()
        assertFalse("the first local reader was left under the second", showing("screen.reader"))
        assertNull(route.openBook)
    }

    @Test
    fun `a middle local book asked for replaces the first`() = aLocalBookReplacesAnotherLocalBook(first, middle)

    @Test
    fun `the last local book asked for replaces a middle one`() = aLocalBookReplacesAnotherLocalBook(middle, last)

    @Test
    fun `the first local book asked for replaces the last`() = aLocalBookReplacesAnotherLocalBook(last, first)

    @Test
    fun `a removed download can be taken back from the snackbar`() {
        val app = driver.launch(signedIn = true).app
        app.removeDownload(DRACULA, BookContentService.Format.EBOOK, "Dracula")
        assertFalse(DRACULA in app.downloadedUuids)
        driver.waitForNode(hasText("Removed Dracula"))
        compose.onNode(hasText("Undo")).performClick()
        driver.waitFor { app.pendingRemoval == null }
        assertTrue(DRACULA in app.downloadedUuids)
        driver.waitFor { !driver.exists(hasText("Removed Dracula")) }
    }

    @Test
    fun `the status pill says what it does, with the status as its state`() {
        val app = driver.launch(signedIn = true).app
        driver.tab("Library")
        app.requestBook(TIME_WAR, AppModel.PendingBook.Destination.DETAILS)
        driver.waitForNode(hasContentDescription("Change reading status"))
        val pill = compose.onNode(hasContentDescription("Change reading status")).fetchSemanticsNode()
        assertEquals("To read", pill.config.getOrNull(SemanticsProperties.StateDescription))
        assertTrue(showing("action.read"))
        assertTrue(showing("bookDetail.tag"))
    }

    @Test
    fun `the device code is spoken one character at a time`() {
        driver.launch(signedIn = false)
        assertTrue(showing("screen.signIn"))
        assertTrue(showing("field.serverAddress"))
        compose.onNode(hasSetTextAction()).performTextInput(FixtureServer.SERVER)
        compose.onNode(hasText("Use a device code")).performClick()
        // device-start.json's code.
        driver.waitForNode(hasContentDescription("G C D 6 - 8 8 Z 2"))
    }

    companion object {
        const val TIME_WAR = "33333333-3333-4333-8333-333333333333"
        const val DRACULA = "44444444-4444-4444-8444-444444444444"
        const val SONGBIRDS = "66666666-6666-4666-8666-666666666666"
    }
}
