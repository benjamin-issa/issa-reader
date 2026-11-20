package com.benjaminissa.issareader.app.ui.settings

import androidx.compose.ui.test.assertHasNoClickAction
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import com.benjaminissa.issareader.app.TestTokens
import com.benjaminissa.issareader.app.ask.AIKeys
import com.benjaminissa.issareader.app.ask.AskCoordinator
import com.benjaminissa.issareader.app.ask.AskHarness
import com.benjaminissa.issareader.app.ask.CountingPlatform
import com.benjaminissa.issareader.app.model.PlaybackSettings
import com.benjaminissa.issareader.app.model.SignOutCentre
import com.benjaminissa.issareader.ask.AskIndexStore
import com.benjaminissa.issareader.ask.ProviderKind
import com.benjaminissa.issareader.ask.ProviderModel
import com.benjaminissa.issareader.core.InMemoryKeyValueStore
import com.benjaminissa.issareader.ui.IssaTheme
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.Collections

/**
 * Adding a key: what the provider checked is what is saved, and nothing can
 * change it while it is being checked. Keys are fakes.
 */
@RunWith(RobolectricTestRunner::class)
@Config(qualifiers = "w402dp-h1960dp-xxhdpi")
class ProviderKeySetupTest {
    @get:Rule val compose = createComposeRule()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
    private val directory = AskHarness.temporaryDirectory()
    private val defaults = InMemoryKeyValueStore()
    private val settings = PlaybackSettings(defaults, SignOutCentre())
    private val tokens = TestTokens()
    private val listed = CompletableDeferred<List<ProviderModel>>()
    private val checked: MutableList<String> = Collections.synchronizedList(ArrayList())
    private val opus = ProviderModel("claude-opus-5-5", "Claude Opus 5.5", 1_000_000, supportsEffort = true)

    private val coordinator = AskCoordinator(
        settings = settings,
        platform = CountingPlatform(),
        defaults = defaults,
        scope = scope,
        store = AskIndexStore(directory),
        centre = SignOutCentre(),
        keys = AIKeys(tokens, defaults),
        catalog = { _, key ->
            checked += key
            listed.await()
        },
    )

    @After
    fun tearDown() {
        coordinator.close()
        settings.close()
        scope.cancel()
        directory.deleteRecursively()
    }

    @Test
    fun `the key checked is the key saved, and neither the field nor paste works while it is checked`() {
        compose.setContent { IssaTheme(darkTheme = false) { ProviderKeyScreen(ProviderKind.ANTHROPIC, coordinator, onBack = {}, onChangeModel = {}) } }
        compose.onNodeWithTag("aiKey.field").performTextInput("sk-ant-test-1")
        compose.onNodeWithTag("aiKey.check").performClick()
        compose.waitForIdle()

        compose.onNodeWithTag("aiKey.field").assertIsNotEnabled()
        compose.onNodeWithTag("aiKey.paste").assertHasNoClickAction()
        assertNull("nothing is saved before Agree", tokens.read("anthropic"))

        listed.complete(listOf(opus))
        compose.waitUntil(5_000) { compose.onAllNodesWithTagExists("aiKey.continue") }
        compose.onNodeWithText("Tested with Issa Reader").assertExists()
        compose.onNodeWithTag("aiKey.continue").performClick()
        assertNull("nor before the consent screen is agreed to", tokens.read("anthropic"))
        compose.onNodeWithTag("aiKey.agree").performClick()
        compose.waitForIdle()

        assertEquals(listOf("sk-ant-test-1"), checked.toList())
        assertEquals("sk-ant-test-1", tokens.read("anthropic"))
        assertEquals("Claude Opus 5.5", coordinator.keys.registration(ProviderKind.ANTHROPIC)?.model?.displayName)
    }

    private fun androidx.compose.ui.test.junit4.ComposeContentTestRule.onAllNodesWithTagExists(tag: String): Boolean =
        onAllNodes(androidx.compose.ui.test.hasTestTag(tag)).fetchSemanticsNodes().isNotEmpty()
}
