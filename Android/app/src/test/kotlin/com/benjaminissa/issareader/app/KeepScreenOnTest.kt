package com.benjaminissa.issareader.app

import android.app.Activity
import android.content.Context
import android.os.Looper
import android.view.WindowManager
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.test.core.app.ApplicationProvider
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.android.controller.ActivityController
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * The window flag itself, through the real activity.
 *
 * `ScreenAwakeTest` holds the decision to its rules and stops at
 * `ScreenAwakeAssertion.isHeld`. Nothing checked that `MainActivity` turns that
 * decision into `FLAG_KEEP_SCREEN_ON` on its window, which is the only thing the
 * screen actually obeys — so when the Boox Palma went to sleep with a book open
 * (19 Nov 2026), there was no test to say whether the app ever asked it not to.
 * These do, in the ordinary and the E-Ink composition alike: E-Ink mode builds
 * the activity's content on a different recomposer.
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = LaunchTestApplication::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class KeepScreenOnTest {
    @get:Rule val compose = createEmptyComposeRule()

    private val application: IssaApplication get() = ApplicationProvider.getApplicationContext<Context>() as IssaApplication

    private var controller: ActivityController<MainActivity>? = null

    @After
    fun tearDown() {
        controller?.pause()?.stop()?.destroy()
        application.graph.settings.einkMode = false
    }

    private fun launch(): ActivityController<MainActivity> {
        val context: Context = ApplicationProvider.getApplicationContext()
        val launcher = context.packageManager.getLaunchIntentForPackage(context.packageName)!!
        return Robolectric.buildActivity(MainActivity::class.java, launcher).setup().also {
            controller = it
            settle()
        }
    }

    private fun settle() {
        repeat(5) {
            shadowOf(Looper.getMainLooper()).idle()
            compose.waitForIdle()
        }
    }

    private fun keptAwake(activity: Activity): Boolean =
        activity.window.attributes.flags and WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON != 0

    @Test
    fun `an open book keeps the window awake, and closing it lets the screen sleep`() {
        val launched = launch()
        val app = application.graph.app
        assertFalse("nothing is open yet", keptAwake(launched.get()))

        app.setReaderVisible(BOOK, true)
        settle()
        assertTrue("a book on screen must keep the window awake", keptAwake(launched.get()))

        app.setReaderVisible(BOOK, false)
        settle()
        assertFalse("a closed book must let the screen sleep", keptAwake(launched.get()))
    }

    @Test
    fun `E-Ink mode keeps the window awake with a book open too`() {
        application.graph.settings.einkMode = true
        val launched = launch()

        application.graph.app.setReaderVisible(BOOK, true)
        settle()
        assertTrue("the E-Ink composition must still apply the flag", keptAwake(launched.get()))

        application.graph.app.setReaderVisible(BOOK, false)
        settle()
        assertFalse(keptAwake(launched.get()))
    }

    /**
     * The background half through the same window. Driven by the model's own
     * foreground state rather than the activity's lifecycle: Robolectric does
     * not deliver ProcessLifecycleOwner's delayed stop, and what is under test
     * here is that the window follows the decision, both ways.
     */
    @Test
    fun `leaving the app lets the screen sleep, and coming back keeps it awake again`() {
        val launched = launch()
        val app = application.graph.app
        app.setReaderVisible(BOOK, true)
        settle()
        assertTrue(keptAwake(launched.get()))

        app.setForeground(false)
        settle()
        assertFalse("a book left open in the background must not hold the screen", app.keepsScreenAwake)
        assertFalse(keptAwake(launched.get()))

        app.setForeground(true)
        settle()
        assertTrue("back in front with the book still open", keptAwake(launched.get()))
    }

    private companion object {
        const val BOOK = "11111111-1111-4111-8111-111111111111"
    }
}
