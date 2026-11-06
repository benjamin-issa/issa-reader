package com.benjaminissa.issareader.app.ui.library

import androidx.activity.ComponentActivity
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import com.benjaminissa.issareader.app.ui.fixture.AppDriver
import com.benjaminissa.issareader.app.ui.fixture.FixtureServer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * What the shelves say about a catalogue that did not fully arrive. The app runs
 * whole against the fixture server, so these see what a reader would. Swift's
 * `testUnreadableBookNotice`, and the load overlay's other half on Reading.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(qualifiers = "w402dp-h874dp-xxhdpi")
class LibraryLoadScreensTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @get:Rule val temp = TemporaryFolder()

    private val driver by lazy { AppDriver(compose, temp.root, "build/sweep/library-load-timed-out.png") }

    private val notice = hasTestTag("notice.unreadableBooks")

    @Test
    fun `the shelf says how many books could not be read, and Try again clears it`() {
        val app = driver.launch(signedIn = true, catalogue = FixtureServer.Catalogue.UNREADABLE_ROW).app
        driver.tab("Library")
        driver.waitForNode(notice)
        assertTrue(driver.exists(hasText("1 book couldn't be read")))
        assertEquals(1, app.unreadableBookCount)

        // The server's answer can be read again.
        FixtureServer.catalogue = FixtureServer.Catalogue.WHOLE
        compose.onNodeWithText("Try again").performClick()
        driver.waitFor { app.unreadableBookCount == 0 }
        assertFalse(driver.exists(notice))
    }

    @Test
    fun `a whole catalogue says nothing`() {
        driver.launch(signedIn = true)
        driver.tab("Library")
        driver.settle()
        assertFalse(driver.exists(notice))
    }

    /** "Nothing in progress" over a library that failed to load sends a reader looking in the wrong place. */
    @Test
    fun `Reading says the library could not be loaded, not that nothing is in progress`() {
        driver.launch(signedIn = true, catalogue = FixtureServer.Catalogue.FAILS)
        driver.tab("Reading")
        driver.waitForNode(hasText("Couldn't load your library"))
        assertFalse(driver.exists(hasText("Nothing in progress")))
    }
}
