package com.benjaminissa.issareader.app.ui

import android.os.Looper
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isSelectable
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.unit.dp
import com.benjaminissa.issareader.app.model.AppModel
import com.benjaminissa.issareader.app.ui.fixture.FixtureServer
import com.benjaminissa.issareader.app.ui.fixture.Sweep
import com.benjaminissa.issareader.app.ui.shell.AppEnvironment
import com.benjaminissa.issareader.app.ui.shell.IssaRoot
import com.benjaminissa.issareader.ui.IssaTheme
import com.benjaminissa.issareader.ui.Palette
import com.github.takahirom.roborazzi.captureRoboImage
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * The layout sweep's screens, drawn at the three iPhone widths the contact
 * sheets in `docs/screenshots/sweep/_sheets` show, against the same fixture
 * library, for comparing by eye. Written to `build/sweep/<width>/<screen>.png`.
 *
 * The app runs whole — the root, the shell, the real sign-in and library
 * paths against [FixtureServer] — under a strip standing in for the phone's
 * status bar.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
abstract class SweepScreenshotTest(private val device: Sweep.Device) {
    @get:Rule val compose = createComposeRule()

    @get:Rule val temp = TemporaryFolder()

    private fun launch(signedIn: Boolean, dark: Boolean = false): AppEnvironment {
        val environment = Sweep.environment(temp.root, signedIn)
        compose.setContent {
            IssaTheme(darkTheme = dark) {
                Column(Modifier.fillMaxSize().background(Palette.paper)) {
                    Spacer(Modifier.height(STATUS_BAR))
                    IssaRoot(environment)
                }
            }
        }
        val app = environment.app
        app.startRestore()
        if (signedIn) {
            waitFor { app.phase == AppModel.Phase.READY && app.books.isNotEmpty() }
        } else {
            waitFor { app.phase == AppModel.Phase.CHOOSE_SERVER }
        }
        return environment
    }

    /**
     * Runs the main thread until [condition] holds: the app's work is posted
     * to it, and the network answers on threads of its own.
     */
    private fun waitFor(condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + TIMEOUT
        while (true) {
            compose.waitForIdle()
            shadowOf(Looper.getMainLooper()).idle()
            if (condition()) break
            if (System.currentTimeMillis() > deadline) {
                // What was on screen instead, beside the sweep's own shots.
                compose.onRoot().captureRoboImage("build/sweep/${device.width}/timed-out.png")
                error("Timed out waiting for the fixture app")
            }
            Thread.sleep(25)
        }
        compose.waitForIdle()
    }

    private fun waitForNode(matcher: SemanticsMatcher) =
        waitFor { compose.onAllNodes(matcher, useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty() }

    private fun capture(screen: String) {
        // Let the last animations settle: the tab change, the pushed page.
        compose.mainClock.advanceTimeBy(1_000)
        waitFor { true }
        compose.onRoot().captureRoboImage("build/sweep/${device.width}/$screen.png")
    }

    private fun tab(title: String) {
        compose.onNode(hasText(title) and isSelectable()).performClick()
        waitFor { true }
    }

    @Test
    fun signIn() {
        launch(signedIn = false)
        capture("signIn")
    }

    @Test
    fun deviceCode() {
        launch(signedIn = false)
        compose.onNode(hasSetTextAction()).performTextInput(FixtureServer.SERVER)
        compose.onNode(hasText("Use a device code")).performClick()
        waitForNode(hasText("APPROVE THIS DEVICE"))
        capture("deviceCode")
    }

    @Test
    fun library() {
        launch(signedIn = true)
        tab("Library")
        capture("library")
    }

    @Test
    fun libraryGrid() {
        launch(signedIn = true)
        tab("Library")
        compose.onNode(hasText("All books")).performClick()
        capture("libraryGrid")
    }

    @Test
    fun reading() {
        val app = launch(signedIn = true).app
        // The Downloaded section's walk of the disk, which runs off the main
        // thread; its rows may be below the fold, and so not composed.
        waitFor { app.downloadedUuids.size == 6 }
        Thread.sleep(300)
        capture("reading")
    }

    @Test
    fun bookDetail() {
        bookDetail(dark = false)
        capture("bookDetail")
    }

    @Test
    fun series() {
        launch(signedIn = true)
        tab("Library")
        // Through the Series rail's "See all", which is on screen at every width;
        // the tile itself is below the fold on the smallest phone.
        compose.onAllNodes(hasText("See all"))[1].performClick()
        waitForNode(hasText("Series"))
        compose.onNode(hasText("Gothic Horror") and hasClickAction()).performClick()
        waitForNode(hasText("2 BOOKS"))
        capture("series")
    }

    @Test
    fun libraryDark() {
        assumeTrue(device == Sweep.PRO)
        launch(signedIn = true, dark = true)
        tab("Library")
        capture("library-dark")
    }

    @Test
    fun bookDetailDark() {
        assumeTrue(device == Sweep.PRO)
        bookDetail(dark = true)
        capture("bookDetail-dark")
    }

    private fun bookDetail(dark: Boolean) {
        val environment = launch(signedIn = true, dark = dark)
        tab("Library")
        environment.app.requestBook(TIME_WAR, AppModel.PendingBook.Destination.DETAILS)
        waitForNode(hasText("Rate"))
    }

    companion object {
        /** Where the phone's status bar sits over an edge-to-edge app. */
        val STATUS_BAR = 32.dp
        const val TIMEOUT = 20_000L
        const val TIME_WAR = "33333333-3333-4333-8333-333333333333"
    }
}

@Config(qualifiers = "w375dp-h667dp-xxhdpi")
class Sweep375ScreenshotTest : SweepScreenshotTest(Sweep.SE)

@Config(qualifiers = "w402dp-h874dp-xxhdpi")
class Sweep402ScreenshotTest : SweepScreenshotTest(Sweep.PRO)

@Config(qualifiers = "w440dp-h956dp-xxhdpi")
class Sweep440ScreenshotTest : SweepScreenshotTest(Sweep.PRO_MAX)
