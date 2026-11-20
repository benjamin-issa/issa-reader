package com.benjaminissa.issareader.app.ui.ask

import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertIsOff
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.isToggleable
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import com.benjaminissa.issareader.app.TestTokens
import com.benjaminissa.issareader.app.ask.AIKeys
import com.benjaminissa.issareader.app.ask.AskCoordinator
import com.benjaminissa.issareader.app.ask.AskDefaults
import com.benjaminissa.issareader.app.ask.NoKeys
import com.benjaminissa.issareader.app.ask.AskCopy
import com.benjaminissa.issareader.app.ask.AskHarness
import com.benjaminissa.issareader.app.ask.CountingPlatform
import com.benjaminissa.issareader.app.model.PlaybackSettings
import com.benjaminissa.issareader.app.model.SignOutCentre
import com.benjaminissa.issareader.ask.AskAnswerer
import com.benjaminissa.issareader.ask.AskAvailability
import com.benjaminissa.issareader.ask.ProviderKind
import com.benjaminissa.issareader.ask.ProviderModel
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

    private fun coordinator(platform: CountingPlatform, keys: AIKeys = AIKeys(NoKeys, defaults)) = AskCoordinator(
        settings = settings,
        platform = platform,
        defaults = defaults,
        scope = scope,
        store = AskIndexStore(directory),
        centre = SignOutCentre(),
        keys = keys,
    )

    /** A key registered in this test's own preferences, over an in-memory store. */
    private fun keysWith(vararg kinds: ProviderKind): AIKeys = AIKeys(TestTokens(), defaults).also { keys ->
        for (kind in kinds) keys.register(kind, "sk-test-1", ProviderModel(id = "m-${kind.rawValue}", displayName = "Model", contextSize = 200_000))
    }

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

    @Test
    fun `without the system AI service the switch is disabled with the unsupported sentence, and nothing is asked`() {
        val platform = CountingPlatform().also { it.hasSystemService = false }
        val coordinator = coordinator(platform)
        compose.setContent { IssaTheme(darkTheme = false) { LazyColumn { askSettingsSection(coordinator) } } }
        compose.waitForIdle()

        compose.onNode(isToggleable()).assertIsOff().assertIsNotEnabled()
        compose.onNodeWithText(AskCopy.unsupported()).assertExists()
        compose.onNodeWithTag("settings.ask.toggle").performClick()
        compose.waitForIdle()
        assertFalse(settings.askEnabled)
        assertEquals(0, platform.calls)
        assertFalse(MlKitStartup.isStarted)
    }

    @Test
    fun `with the system AI service the switch is enabled`() {
        val coordinator = coordinator(CountingPlatform())
        compose.setContent { IssaTheme(darkTheme = false) { LazyColumn { askSettingsSection(coordinator) } } }
        compose.waitForIdle()

        compose.onNode(isToggleable()).assertIsEnabled()
    }

    @Test
    fun `no default picker until a key is registered`() {
        settings.askEnabled = true
        val coordinator = coordinator(CountingPlatform())
        compose.setContent { IssaTheme(darkTheme = false) { LazyColumn { askSettingsSection(coordinator) } } }
        compose.waitForIdle()
        compose.onNodeWithTag("settings.ask.defaultAnswerer").assertDoesNotExist()
        compose.onNodeWithText(AskCopy.promise()).assertExists()
    }

    @Test
    fun `with a key, the default picker offers this phone and the provider, and the footer says where questions go`() {
        settings.askEnabled = true
        val coordinator = coordinator(CountingPlatform(), keysWith(ProviderKind.ANTHROPIC))
        compose.setContent { IssaTheme(darkTheme = false) { LazyColumn { askSettingsSection(coordinator) } } }
        compose.waitForIdle()
        compose.onNodeWithTag("settings.ask.defaultAnswerer").assertExists()
        compose.onNodeWithText(AskDefaults.choiceTitle(AskAnswerer.DEVICE)).assertExists()
        compose.onNodeWithText(AskCopy.promise() + AskCopy.providerSentence(listOf(ProviderKind.ANTHROPIC))).assertExists()

        compose.onNodeWithTag("settings.ask.defaultAnswerer").performClick()
        compose.onNodeWithText("Anthropic").performClick()
        compose.waitForIdle()
        assertEquals(ProviderKind.ANTHROPIC.rawValue, settings.askDefaultProvider)
    }

    @Test
    fun `on a phone without the system AI service, a key makes the switch usable and says it is what answers`() {
        val platform = CountingPlatform().also { it.hasSystemService = false }
        val coordinator = coordinator(platform, keysWith(ProviderKind.ANTHROPIC))
        compose.setContent { IssaTheme(darkTheme = false) { LazyColumn { askSettingsSection(coordinator) } } }
        compose.waitForIdle()

        compose.onNode(isToggleable()).assertIsEnabled()
        compose.onNodeWithTag("settings.ask.toggle").performClick()
        compose.waitForIdle()
        assertTrue(settings.askEnabled)
        compose.onNode(isToggleable()).assertIsOn()
        compose.onNodeWithText(AskCopy.keysOnly(listOf(ProviderKind.ANTHROPIC))).assertExists()
        // One place only: no picker of one.
        compose.onNodeWithTag("settings.ask.defaultAnswerer").assertDoesNotExist()
        assertEquals(0, platform.calls)
        assertFalse(MlKitStartup.isStarted)
    }

    @Test
    fun `the disabled switch still reads in E-Ink mode`() {
        val coordinator = coordinator(CountingPlatform().also { it.hasSystemService = false })
        compose.setContent { IssaTheme(darkTheme = false, eink = true) { LazyColumn { askSettingsSection(coordinator) } } }
        compose.waitForIdle()

        compose.onNode(isToggleable()).assertIsNotEnabled()
        compose.onNodeWithText(AskCopy.unsupported()).assertExists()
    }
}
