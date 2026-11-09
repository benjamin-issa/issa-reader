package com.benjaminissa.issareader.app.ui

import androidx.activity.ComponentActivity
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import com.benjaminissa.issareader.app.model.AppModel
import com.benjaminissa.issareader.app.ui.fixture.AppDriver
import com.benjaminissa.issareader.app.ui.fixture.FixtureLibrary
import com.benjaminissa.issareader.app.ui.fixture.FixtureServer
import com.benjaminissa.issareader.core.download.BookContentService
import com.benjaminissa.issareader.core.sync.LibraryArrangement
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
    }
}
