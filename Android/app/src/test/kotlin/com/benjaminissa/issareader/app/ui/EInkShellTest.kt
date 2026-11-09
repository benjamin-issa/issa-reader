package com.benjaminissa.issareader.app.ui

import androidx.activity.ComponentActivity
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isSelectable
import androidx.compose.ui.test.junit4.AndroidComposeTestRule
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.performClick
import com.benjaminissa.issareader.app.NoMotion
import com.benjaminissa.issareader.app.model.AppModel
import com.benjaminissa.issareader.app.ui.fixture.AppDriver
import com.benjaminissa.issareader.ui.EInk
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
 * The whole app with the motion E-Ink mode's activity has. A screen that fades
 * in leaves the last one on the panel for every frame of the fade.
 *
 * Measured in the test clock's time from a tap until the app goes idle, which
 * is how long something was animating, and which [ShellMotionControlTest] shows
 * is hundreds of milliseconds with the system's motion.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(qualifiers = "w412dp-h915dp-xxhdpi")
class EInkShellTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>(NoMotion)

    @get:Rule val temp = TemporaryFolder()

    private val driver by lazy { AppDriver(compose, temp.root, "build/sweep/eink-shell-timed-out.png") }

    private fun showing(tag: String) = driver.exists(hasTestTag(tag))

    private fun assertInstant(what: String, action: () -> Unit) {
        val took = millisUntilIdle(compose, action)
        assertTrue("$what animated for $took ms", took < INSTANT_MILLIS)
    }

    @Test
    fun `no transition runs`() {
        driver.launch(signedIn = true, eink = true)
        driver.settle()
        assertInstant("a tab") { compose.onNode(hasText("Library") and isSelectable()).performClick() }
        assertTrue(showing("screen.library"))
        assertFalse(showing("screen.reading"))

        assertInstant("a pushed page") { compose.onAllNodes(hasText("See all"))[1].performClick() }
        assertFalse("the page it covers stayed up", showing("screen.library"))

        assertInstant("Back") { compose.runOnUiThread { compose.activity.onBackPressedDispatcher.onBackPressed() } }
        assertTrue(showing("screen.library"))

        assertInstant("a tab") { compose.onNode(hasText("Settings") and isSelectable()).performClick() }
        assertInstant("a menu") { compose.onNode(hasText("Progress bar")).performClick() }
        assertTrue(driver.exists(hasText("Whole book")))
        assertInstant("a menu closing") { compose.onNode(hasText("Whole book")).performClick() }
        assertFalse(driver.exists(hasText("Current chapter")))
    }

    private val floor get() = EInk.target.value * compose.density.density - 0.5f

    private fun tooSmall(node: SemanticsNode): Boolean =
        minOf(node.size.width, node.size.height) < floor && minOf(node.touchBoundsInRoot.width, node.touchBoundsInRoot.height) < floor

    private fun assertTargets(screen: String) {
        driver.settle()
        val small = compose.onAllNodes(hasClickAction()).fetchSemanticsNodes().filter(::tooSmall)
        assertTrue(
            "$screen has targets under 48 dp: " + small.map { "${it.config} at ${it.size}" },
            small.isEmpty(),
        )
    }

    @Test
    fun `every target on the main screens is 48 dp`() {
        val environment = driver.launch(signedIn = true, eink = true)
        assertTargets("Reading")
        driver.tab("Library")
        assertTargets("Library")
        driver.tab("Settings")
        assertTargets("Settings")
        driver.tab("Library")
        environment.app.requestBook(SweepScreenshotTest.TIME_WAR, AppModel.PendingBook.Destination.DETAILS)
        driver.waitForNode(hasText("Rate"))
        assertTargets("a book's page")
    }

    private companion object {
        /** A tap landing and the navigation it asks for: a third of the shortest slide. */
        const val INSTANT_MILLIS = 100L
    }
}

/** The test clock's time [action] took to come to rest. */
private fun millisUntilIdle(compose: AndroidComposeTestRule<*, *>, action: () -> Unit): Long {
    val start = compose.mainClock.currentTime
    action()
    compose.waitForIdle()
    return compose.mainClock.currentTime - start
}

/** The control for [EInkShellTest]: with the system's motion the same clock catches a transition running, so that test can fail. */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(qualifiers = "w412dp-h915dp-xxhdpi")
class ShellMotionControlTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @get:Rule val temp = TemporaryFolder()

    private val driver by lazy { AppDriver(compose, temp.root, "build/sweep/motion-control-timed-out.png") }

    @Test
    fun `a transition does run, off`() {
        driver.launch(signedIn = true)
        driver.tab("Library")
        val took = millisUntilIdle(compose) { compose.onAllNodes(hasText("See all"))[1].performClick() }
        assertTrue("a pushed page slides for 300 ms, and this took $took", took >= 300)
    }
}
