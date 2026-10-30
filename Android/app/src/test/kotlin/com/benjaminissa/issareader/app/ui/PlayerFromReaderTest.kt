package com.benjaminissa.issareader.app.ui

import androidx.activity.ComponentActivity
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasAnyDescendant
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.performClick
import com.benjaminissa.issareader.app.ScriptedBackend
import com.benjaminissa.issareader.app.SharedFixtures
import com.benjaminissa.issareader.app.model.AppModel
import com.benjaminissa.issareader.app.ui.fixture.AppDriver
import com.benjaminissa.issareader.app.ui.fixture.FixtureLibrary
import com.benjaminissa.issareader.app.ui.reader.SEEN_COACH_KEY
import com.benjaminissa.issareader.app.ui.reader.SEEN_NARRATION_TIP_KEY
import com.benjaminissa.issareader.core.download.BookContentService
import com.benjaminissa.issareader.core.model.AudiobookManifest
import com.benjaminissa.issareader.playback.AudioPlayer
import com.benjaminissa.issareader.playback.AudiobookCoordinator
import com.benjaminissa.issareader.testing.Fixtures
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.After
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
import java.io.File

/**
 * The player sheet a reader raises goes with that reader. It is about the
 * reader's book, started or not, only while that reader is the one on screen;
 * dismissing it, or closing the reader under it, must not leave a claim that
 * the next sheet — the mini bar's, about whatever is playing — then draws.
 *
 * The fixture library's read-along book holds a stub where its EPUB goes, so
 * each test first plants the real read-along EPUB there; the reader then
 * opens it and narrates.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(qualifiers = "w402dp-h874dp-xxhdpi")
class PlayerFromReaderTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @get:Rule val temp = TemporaryFolder()

    private val driver by lazy { AppDriver(compose, temp.root, "build/sweep/player-from-reader-timed-out.png") }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    @After
    fun tearDown() {
        scope.cancel()
    }

    private fun showing(tag: String): Boolean = driver.exists(hasTestTag(tag))

    /** Matches anything inside the player sheet. */
    private val inSheet = hasAnyAncestor(hasTestTag("screen.player"))

    /** The real read-along where the fixture's stub is, for both editions the reader might choose. */
    private fun plantReadAlong() {
        val directory = BookContentService.defaultDirectory()
        for (format in listOf(BookContentService.Format.EBOOK, BookContentService.Format.READALOUD)) {
            val target = BookContentService.localUrl(directory, FixtureLibrary.READALONG_UUID, format)
            Fixtures.playback("readalong.epub").copyTo(target, overwrite = true)
        }
    }

    /** The app signed in, and the read-along's reader open on screen, narrated. */
    private fun openNarratedReader(): AppModel {
        val environment = driver.launch(signedIn = true)
        val app = environment.app
        // The first reader's guide covers the footer and takes the first tap.
        environment.readerEnvironment()?.defaults?.apply {
            putBoolean(SEEN_COACH_KEY, true)
            putBoolean(SEEN_NARRATION_TIP_KEY, true)
        }
        plantReadAlong()
        assertTrue(app.open(java.net.URI("issareader://book/${FixtureLibrary.READALONG_UUID}")))
        driver.waitForNode(hasTestTag("screen.reader"))
        driver.waitFor { app.visibleReader?.hasNarration == true }
        driver.settle()
        return app
    }

    private fun raisePlayerFromReader() {
        compose.onNode(hasContentDescription("Open player"), useUnmergedTree = true).performClick()
        driver.waitForNode(hasTestTag("screen.player"))
    }

    /** An audiobook in the engine's slot, as the mini bar draws it, for a book that is not the reader's. */
    private fun startListening(app: AppModel): String {
        val title = "The Other Book"
        val book = SharedFixtures.book(title, uuid = OTHER_UUID, audiobook = true)
        val coordinator = AudiobookCoordinator(
            manifest = AudiobookManifest(
                metadata = AudiobookManifest.Metadata(title = mapOf("und" to title)),
                readingOrder = (0 until 3).map { AudiobookManifest.Track(href = "t$it.mp3", type = "audio/mpeg", duration = 1_000.0) },
            ),
            // A source nothing can open: the sheet only has to draw it.
            source = AudiobookCoordinator.Source.Local(File(temp.root, "missing.mp3")),
            player = AudioPlayer(ScriptedBackend()),
            scope = scope,
        )
        compose.runOnUiThread { app.installListening(coordinator, book, BookContentService.Format.AUDIOBOOK) }
        driver.waitForNode(hasContentDescription("Now playing: $title"))
        return title
    }

    private fun assertSheetIsAbout(title: String) {
        driver.waitForNode(hasTestTag("screen.player"))
        assertTrue("the sheet does not show $title", driver.exists(hasTestTag("screen.player") and hasAnyDescendant(hasText(title))))
        assertFalse("the sheet shows the closed reader's book", driver.exists(hasText("Peter and Wendy") and inSheet))
    }

    @Test
    fun `the reader's waveform raises the player for its own book`() {
        val app = openNarratedReader()
        assertNull("nothing is playing, so only the reader's own sheet can show", app.listening)

        raisePlayerFromReader()

        assertTrue(showing("screen.player"))
    }

    @Test
    fun `a sheet dismissed from the reader does not outlive it for the mini bar`() {
        val app = openNarratedReader()
        raisePlayerFromReader()
        compose.onNode(hasText("Done") and inSheet).performClick()
        driver.waitFor { !showing("screen.player") }

        compose.runOnUiThread { compose.activity.onBackPressedDispatcher.onBackPressed() }
        driver.waitForNode(hasTestTag("screen.bookDetail"))
        driver.settle()
        assertFalse(showing("screen.reader"))
        assertNull(app.visibleReader)

        val title = startListening(app)
        compose.onNode(hasContentDescription("Now playing: $title")).performClick()

        assertSheetIsAbout(title)
    }

    @Test
    fun `a reader closed under its sheet takes the sheet with it`() {
        val app = openNarratedReader()
        raisePlayerFromReader()

        // A link to another book takes the reader down while the sheet is up.
        app.requestBook(TIME_WAR, AppModel.PendingBook.Destination.DETAILS)
        driver.waitForNode(hasTestTag("screen.bookDetail"))
        driver.waitFor { !showing("screen.player") }
        driver.settle()
        assertFalse("the sheet stayed over the tabs", showing("screen.player"))

        val title = startListening(app)
        compose.onNode(hasContentDescription("Now playing: $title")).performClick()

        assertSheetIsAbout(title)
    }

    private companion object {
        const val TIME_WAR = "33333333-3333-4333-8333-333333333333"
        const val OTHER_UUID = "66666666-6666-4666-8666-666666666666"
    }
}
