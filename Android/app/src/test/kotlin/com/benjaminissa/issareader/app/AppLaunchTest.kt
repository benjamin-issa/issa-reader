package com.benjaminissa.issareader.app

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Looper
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.test.core.app.ApplicationProvider
import androidx.work.Configuration
import androidx.work.testing.WorkManagerTestInitHelper
import com.benjaminissa.issareader.ask.android.MlKitStartup
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.android.controller.ActivityController
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * The app started the way a phone starts it: the manifest's own
 * [IssaApplication] building the whole [AppGraph], and [MainActivity] drawing
 * the root from `AppEnvironment.from(graph)`.
 *
 * Every other screen test draws a fixture environment, and every other suite
 * runs on a bare `Application` (`robolectric.properties`), so none of them
 * walks this path — and it is where the port's one launch crash lived: the
 * model's `init` ran before the state it rebuilds, and building the graph
 * threw. This is the test that would have caught it. It also holds the
 * manifest to the classes it names, and ML Kit to staying off until Ask is
 * turned on.
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = LaunchTestApplication::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class AppLaunchTest {
    @get:Rule val compose = createEmptyComposeRule()

    private val context: Context get() = ApplicationProvider.getApplicationContext()

    private var controller: ActivityController<MainActivity>? = null

    @After
    fun tearDown() {
        controller?.pause()?.stop()?.destroy()
    }

    /** Started from the launcher, as a phone starts it. */
    private fun launch(): ActivityController<MainActivity> {
        val launcher = context.packageManager.getLaunchIntentForPackage(context.packageName)!!
        return Robolectric.buildActivity(MainActivity::class.java, launcher).setup().also { controller = it }
    }

    /** The main thread run until [condition] holds, as a phone's would. */
    private fun waitFor(what: String, condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + 20_000
        while (!condition()) {
            check(System.currentTimeMillis() < deadline) { "timed out waiting for $what" }
            shadowOf(Looper.getMainLooper()).idle()
            compose.waitForIdle()
            Thread.sleep(25)
        }
    }

    private fun showing(tag: String): Boolean =
        compose.onAllNodes(hasTestTag(tag), useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty()

    @Test
    fun `a first launch builds the graph and lands on sign-in`() {
        val application = context as IssaApplication
        launch()
        waitFor("the sign-in screen") { showing("screen.signIn") }
        assertEquals(AppModelPhases.signedOut, application.graph.app.phase.name)
    }

    @Test
    fun `the app's own links arriving signed out do not take it down`() {
        val launched = launch()
        waitFor("the sign-in screen") { showing("screen.signIn") }
        for (link in listOf("issareader://book/11111111-1111-4111-8111-111111111111", "issareader://continue")) {
            // The launcher-mode singleTask activity takes a link as a new intent.
            launched.newIntent(Intent(Intent.ACTION_VIEW, Uri.parse(link)).setPackage(context.packageName))
            shadowOf(Looper.getMainLooper()).idle()
            compose.waitForIdle()
        }
        // Still the sign-in screen: a link waits for a session, it does not
        // open a reader on nothing.
        assertTrue(showing("screen.signIn"))
    }

    @Test
    fun `ML Kit is not started by launching the app`() {
        launch()
        waitFor("the sign-in screen") { showing("screen.signIn") }
        assertFalse("ML Kit reports to Google from its first call; with Ask off nothing may", MlKitStartup.isStarted)
    }

    /**
     * Every class the manifest names loads: a service, provider or receiver
     * Android Auto, the launcher or WorkManager reaches for by name and R8 or
     * a rename left behind would fail only on a phone, with no activity up.
     */
    @Test
    fun `every component the manifest declares is a class that loads`() {
        val flags = PackageManager.GET_ACTIVITIES or PackageManager.GET_SERVICES or
            PackageManager.GET_RECEIVERS or PackageManager.GET_PROVIDERS
        val info = context.packageManager.getPackageInfo(context.packageName, flags)
        val names = listOfNotNull(info.activities, info.services, info.receivers, info.providers)
            .flatMap { components -> components.map { it.name } }
        for (expected in listOf(
            MainActivity::class.java.name,
            "com.benjaminissa.issareader.app.media.IssaPlaybackService",
            "com.benjaminissa.issareader.app.media.CoverProvider",
            "com.benjaminissa.issareader.app.widget.CurrentBookWidgetReceiver",
            "androidx.work.impl.foreground.SystemForegroundService",
            "androidx.core.content.FileProvider",
        )) {
            assertTrue("$expected is not in the merged manifest", expected in names)
        }
        for (name in names) {
            assertTrue("$name is declared but does not load", runCatching { Class.forName(name) }.isSuccess)
        }
    }

    private object AppModelPhases {
        /** The phase a first launch with nothing stored settles in: asking for a server. */
        const val signedOut = "CHOOSE_SERVER"
    }
}

/**
 * The app's own application, with WorkManager started first: on a phone
 * Android's start-up provider (`androidx.startup`) starts it before
 * `Application.onCreate`, and Robolectric runs no providers. Everything else
 * is the app's.
 */
class LaunchTestApplication : IssaApplication() {
    override fun onCreate() {
        WorkManagerTestInitHelper.initializeTestWorkManager(this, Configuration.Builder().build())
        super.onCreate()
    }
}
