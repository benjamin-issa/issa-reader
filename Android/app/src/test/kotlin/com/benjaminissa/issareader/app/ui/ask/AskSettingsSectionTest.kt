package com.benjaminissa.issareader.app.ui.ask

import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.ui.test.assertIsOff
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.isToggleable
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import com.benjaminissa.issareader.app.ask.AskCoordinator
import com.benjaminissa.issareader.app.ask.AskCopy
import com.benjaminissa.issareader.app.ask.AskHarness
import com.benjaminissa.issareader.app.ask.CountingPlatform
import com.benjaminissa.issareader.app.model.PlaybackSettings
import com.benjaminissa.issareader.app.model.SignOutCentre
import com.benjaminissa.issareader.ask.AskAvailability
import com.benjaminissa.issareader.ask.AskIndexStore
import com.benjaminissa.issareader.ask.android.MlKitStartup
import com.benjaminissa.issareader.core.InMemoryKeyValueStore
import com.benjaminissa.issareader.ui.IssaTheme
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * The Settings section, drawn: opening Settings with Ask off asks Gemini Nano
 * nothing, and the switch is where it is first asked.
 */
@RunWith(RobolectricTestRunner::class)
class AskSettingsSectionTest {
    @get:Rule val compose = createComposeRule()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
    private val directory = AskHarness.temporaryDirectory()
    private val defaults = InMemoryKeyValueStore()
    private val settings = PlaybackSettings(defaults, SignOutCentre())

    private fun coordinator(platform: CountingPlatform) = AskCoordinator(
        settings = settings,
        platform = platform,
        defaults = defaults,
        scope = scope,
        store = AskIndexStore(directory),
        centre = SignOutCentre(),
    )

    @After
    fun tearDown() {
        scope.cancel()
        directory.deleteRecursively()
    }

    @Test
    fun `opening Settings with Ask off asks Gemini Nano nothing`() {
        val platform = CountingPlatform()
        val coordinator = coordinator(platform)
        compose.setContent { IssaTheme(darkTheme = false) { LazyColumn { askSettingsSection(coordinator) } } }
        compose.waitForIdle()

        compose.onNode(isToggleable()).assertIsOff()
        compose.onNodeWithText("Ask AI about this book").assertExists()
        compose.onNodeWithText(AskCopy.promise()).assertExists()
        assertEquals(0, platform.calls)
        assertFalse(MlKitStartup.isStarted)
    }

    @Test
    fun `the switch is where the phone is first asked`() {
        val platform = CountingPlatform(availability = AskAvailability.AVAILABLE)
        val coordinator = coordinator(platform)
        compose.setContent { IssaTheme(darkTheme = false) { LazyColumn { askSettingsSection(coordinator) } } }

        compose.onNodeWithTag("settings.ask.toggle").performClick()
        compose.waitUntil(5_000) { platform.availabilityCalls == 1 }
        compose.waitForIdle()

        compose.onNode(isToggleable()).assertIsOn()
        assertTrue(settings.askEnabled)
        assertEquals("only the availability is read; the model waits for a question", 0, platform.modelCalls)
    }

    @Test
    fun `a phone that cannot answer turns the switch back off, with the reason under it`() {
        val platform = CountingPlatform(availability = AskAvailability.UNSUPPORTED_DEVICE)
        val coordinator = coordinator(platform)
        compose.setContent { IssaTheme(darkTheme = false) { LazyColumn { askSettingsSection(coordinator) } } }

        compose.onNodeWithTag("settings.ask.toggle").performClick()
        compose.waitUntil(5_000) { platform.availabilityCalls == 1 }
        compose.waitForIdle()

        compose.onNode(isToggleable()).assertIsOff()
        compose.onNodeWithText(AskCopy.unsupported()).assertExists()
        assertFalse(settings.askEnabled)
    }
}
