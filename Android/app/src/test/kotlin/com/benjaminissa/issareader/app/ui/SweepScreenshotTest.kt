package com.benjaminissa.issareader.app.ui

import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import com.benjaminissa.issareader.app.model.AppModel
import com.benjaminissa.issareader.app.ui.fixture.AppDriver
import com.benjaminissa.issareader.app.ui.fixture.FixtureServer
import com.benjaminissa.issareader.app.ui.fixture.Sweep
import com.benjaminissa.issareader.ui.Metrics
import com.github.takahirom.roborazzi.captureRoboImage
import java.io.File
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
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

    private val driver by lazy { AppDriver(compose, temp.root, "build/sweep/${device.width}/timed-out.png") }

    private fun capture(screen: String) {
        driver.settle()
        compose.onRoot().captureRoboImage("build/sweep/${device.width}/$screen.png")
        recordReference()
    }

    /**
     * What `Tools/scripts/make-contact-sheet.py` draws its guides from, as the
     * iPhone's `LayoutSweepTests.recordReference` writes it: the window's
     * width and the screen margin, as this run measured them rather than as
     * anything here assumes.
     */
    private fun recordReference() {
        val width = compose.onRoot().fetchSemanticsNode().size.width / compose.density.density
        val margin = Metrics.screenMargin.value
        File("build/sweep/${device.width}").apply { mkdirs() }
            .resolve("reference.txt")
            .writeText("width=${"%.1f".format(java.util.Locale.ROOT, width)}\nmargin=${"%.1f".format(java.util.Locale.ROOT, margin)}\n")
    }

    @Test
    fun signIn() {
        driver.launch(signedIn = false)
        capture("signIn")
    }

    @Test
    fun deviceCode() {
        driver.launch(signedIn = false)
        compose.onNode(hasSetTextAction()).performTextInput(FixtureServer.SERVER)
        compose.onNode(hasText("Use a device code")).performClick()
        driver.waitForNode(hasText("APPROVE THIS DEVICE"))
        capture("deviceCode")
    }

    @Test
    fun library() {
        driver.launch(signedIn = true)
        driver.tab("Library")
        capture("library")
    }

    @Test
    fun libraryGrid() {
        driver.launch(signedIn = true)
        driver.tab("Library")
        compose.onNode(hasText("All books")).performClick()
        capture("libraryGrid")
    }

    @Test
    fun reading() {
        val app = driver.launch(signedIn = true).app
        // The Downloaded section's walk of the disk, which runs off the main
        // thread; its rows may be below the fold, and so not composed.
        driver.waitFor { app.downloadedUuids.size == 6 }
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
        driver.launch(signedIn = true)
        driver.tab("Library")
        // Through the Series rail's "See all", which is on screen at every
        // width; the tile itself is below the fold on the smallest phone.
        compose.onAllNodes(hasText("See all"))[1].performClick()
        driver.waitForNode(hasText("Series"))
        compose.onNode(hasText("Gothic Horror") and hasClickAction()).performClick()
        driver.waitForNode(hasText("2 BOOKS"))
        capture("series")
    }

    @Test
    fun settings() {
        driver.launch(signedIn = true)
        driver.tab("Settings")
        driver.waitForNode(hasTestTag("screen.settings"))
        capture("settings")
    }

    @Test
    fun libraryDark() {
        driver.launch(signedIn = true, dark = true)
        driver.tab("Library")
        capture("library-dark")
    }

    @Test
    fun bookDetailDark() {
        bookDetail(dark = true)
        capture("bookDetail-dark")
    }

    private fun bookDetail(dark: Boolean) {
        val environment = driver.launch(signedIn = true, dark = dark)
        driver.tab("Library")
        environment.app.requestBook(TIME_WAR, AppModel.PendingBook.Destination.DETAILS)
        driver.waitForNode(hasText("Rate"))
    }

    companion object {
        const val TIME_WAR = "33333333-3333-4333-8333-333333333333"
    }
}

@Config(qualifiers = "w375dp-h667dp-xxhdpi")
class Sweep375ScreenshotTest : SweepScreenshotTest(Sweep.SE)

@Config(qualifiers = "w402dp-h874dp-xxhdpi")
class Sweep402ScreenshotTest : SweepScreenshotTest(Sweep.PRO)

@Config(qualifiers = "w440dp-h956dp-xxhdpi")
class Sweep440ScreenshotTest : SweepScreenshotTest(Sweep.PRO_MAX)

@Config(qualifiers = "w360dp-h800dp-xxhdpi")
class Sweep360ScreenshotTest : SweepScreenshotTest(Sweep.COMPACT)

@Config(qualifiers = "w412dp-h915dp-xxhdpi")
class Sweep412ScreenshotTest : SweepScreenshotTest(Sweep.PIXEL)
