package com.benjaminissa.issareader.app.ui.fixture

import android.os.Looper
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isSelectable
import androidx.compose.ui.test.junit4.ComposeContentTestRule
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.benjaminissa.issareader.app.model.AppModel
import com.benjaminissa.issareader.app.ui.shell.AppEnvironment
import com.benjaminissa.issareader.app.ui.shell.IssaRoot
import com.benjaminissa.issareader.ui.IssaTheme
import com.benjaminissa.issareader.ui.Palette
import com.github.takahirom.roborazzi.captureRoboImage
import org.robolectric.Shadows.shadowOf
import java.io.File

/**
 * Drives the whole app in front of [FixtureServer] from a Robolectric test:
 * launches it as the activity does, waits for the work it posts to the main
 * thread and the answers that come back on others, and taps tabs as a reader
 * does.
 *
 * @param failureShot where to keep the screen when a wait runs out, so a
 *   failed run shows what was there instead.
 */
class AppDriver(
    private val compose: ComposeContentTestRule,
    private val root: File,
    private val failureShot: String,
) {
    lateinit var environment: AppEnvironment
        private set

    val app: AppModel get() = environment.app

    /** The app, under a strip standing in for the phone's status bar, restored to signed in or not. */
    fun launch(signedIn: Boolean, dark: Boolean = false, statusBar: Dp = STATUS_BAR): AppEnvironment {
        environment = Sweep.environment(root, signedIn)
        compose.setContent {
            IssaTheme(darkTheme = dark) {
                Column(Modifier.fillMaxSize().background(Palette.paper)) {
                    Spacer(Modifier.height(statusBar))
                    IssaRoot(environment)
                }
            }
        }
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
    fun waitFor(condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + TIMEOUT
        while (true) {
            compose.waitForIdle()
            shadowOf(Looper.getMainLooper()).idle()
            if (condition()) break
            if (System.currentTimeMillis() > deadline) {
                compose.onRoot().captureRoboImage(failureShot)
                error("Timed out waiting for the fixture app")
            }
            Thread.sleep(25)
        }
        compose.waitForIdle()
    }

    fun exists(matcher: SemanticsMatcher): Boolean =
        compose.onAllNodes(matcher, useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty()

    fun waitForNode(matcher: SemanticsMatcher) = waitFor { exists(matcher) }

    /** Lets the last animations settle: a tab change, a pushed page. */
    fun settle() {
        compose.mainClock.advanceTimeBy(1_000)
        waitFor { true }
    }

    /** Taps a tab by its title, as the iPhone's live test finds one. */
    fun tab(title: String) {
        compose.onNode(hasText(title) and isSelectable()).performClick()
        settle()
    }

    companion object {
        /** Where the phone's status bar sits over an edge-to-edge app. */
        val STATUS_BAR = 32.dp
        const val TIMEOUT = 20_000L
    }
}
