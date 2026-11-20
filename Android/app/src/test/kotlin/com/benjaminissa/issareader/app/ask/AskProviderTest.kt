package com.benjaminissa.issareader.app.ask

import com.benjaminissa.issareader.app.ask.AskHarness.Companion.boundary
import com.benjaminissa.issareader.app.ask.AskHarness.Companion.source
import com.benjaminissa.issareader.app.TestTokens
import com.benjaminissa.issareader.app.model.PlaybackSettings
import com.benjaminissa.issareader.app.model.SignOutCentre
import com.benjaminissa.issareader.ask.AskAnswerer
import com.benjaminissa.issareader.ask.AskAvailability
import com.benjaminissa.issareader.ask.AskFailure
import com.benjaminissa.issareader.ask.AskProfile
import com.benjaminissa.issareader.ask.AskPromptBuilder
import com.benjaminissa.issareader.ask.ProviderKind
import com.benjaminissa.issareader.ask.ProviderModel
import com.benjaminissa.issareader.ask.ScriptedAnswerModel
import com.benjaminissa.issareader.ask.android.ModelDownload
import com.benjaminissa.issareader.core.InMemoryKeyValueStore
import com.benjaminissa.issareader.core.auth.TokenPersisting
import kotlinx.coroutines.delay
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A reader's own Anthropic or OpenAI key, as the coordinator routes it.
 * Swift's `AskProviderTests`, with Android's own: a phone that cannot run
 * Gemini Nano keeps Ask on when a key is registered, by every path that used
 * to turn it off. Keys are fakes.
 */
class AskProviderTest {
    private val claude = ProviderModel(id = "claude-test", displayName = "Claude Test", contextSize = 200_000, supportsEffort = true)
    private val gpt = ProviderModel(id = "gpt-6.2-sol", displayName = "GPT-6.2 Sol", contextSize = 1_050_000, supportsEffort = true)

    private fun key(kind: ProviderKind) = if (kind == ProviderKind.ANTHROPIC) "sk-ant-test-1" else "sk-test-1"
    private fun model(kind: ProviderKind) = if (kind == ProviderKind.ANTHROPIC) claude else gpt

    /** Providers that each answer with their own lower-case mark, so an answer says who wrote it and passes the name check. */
    private fun providers(failing: Map<ProviderKind, Throwable> = emptyMap()) = ProviderKind.entries.associateWith { kind ->
        val failure = failing[kind]
        ScriptedAnswerModel(
            listOf(
                if (failure != null) {
                    ScriptedAnswerModel.Turn(failure = failure)
                } else {
                    ScriptedAnswerModel.Turn.answer("Alice followed a white rabbit (${kind.rawValue}).\nSources: 1")
                },
            ),
            // A provider's window: room for everything read.
            contextSize = 200_000,
        )
    }

    private fun harness(
        failing: Map<ProviderKind, Throwable> = emptyMap(),
        platform: CountingPlatform? = null,
        defaults: InMemoryKeyValueStore = InMemoryKeyValueStore(),
        keyStore: TokenPersisting = TestTokens(),
        askEnabled: Boolean = true,
    ): AskHarness {
        val device = ScriptedAnswerModel()
        return AskHarness(
            askEnabled = askEnabled,
            model = device,
            platform = platform ?: CountingPlatform(model = device),
            defaults = defaults,
            keyStore = keyStore,
            providers = providers(failing),
        )
    }

    private fun AskHarness.register(vararg kinds: ProviderKind) {
        for (kind in kinds) assertTrue(coordinator.registerKey(kind, key(kind), model(kind)))
    }

    private suspend fun AskHarness.ask(answerer: AskAnswerer): AskJob {
        val job = coordinator.ask("What did Alice follow?", source(), boundary(), answerer)!!
        job.task?.join()
        return job
    }

    private fun text(job: AskJob): String? = (job.state as? AskJob.State.Answered)?.answer?.text

    /** Keys registered before the coordinator exists, as a relaunch finds them. */
    private fun registeredBeforeLaunch(vararg kinds: ProviderKind): Pair<InMemoryKeyValueStore, TestTokens> {
        val defaults = InMemoryKeyValueStore()
        val tokens = TestTokens()
        val keys = AIKeys(tokens, defaults)
        for (kind in kinds) assertTrue(keys.register(kind, key(kind), model(kind)))
        return defaults to tokens
    }

    // Routing

    @Test
    fun `without a key, a question for a provider is not sent anywhere`() = harness().use { harness ->
        harness.run {
            val job = ask(AskAnswerer.ANTHROPIC)
            val failure = (job.state as AskJob.State.Failed).failure
            assertTrue(failure.message("phone", AskAnswerer.ANTHROPIC).contains("Settings › Advanced"))
            assertTrue(model.received.isEmpty())
            assertTrue(providers.getValue(ProviderKind.ANTHROPIC).received.isEmpty())
            assertTrue("no provider model was even built", built.isEmpty())
        }
    }

    @Test
    fun `a question sent to the reader's provider reaches it, with its key, and nothing else`() = harness().use { harness ->
        harness.run {
            register(ProviderKind.ANTHROPIC)
            val job = ask(AskAnswerer.ANTHROPIC)
            assertEquals(AskAnswerer.ANTHROPIC, job.answerer)
            assertTrue("${job.state}", text(job)?.contains("(anthropic)") == true)
            assertEquals("Claude Test", job.providerModelName)
            assertEquals(listOf(Triple(ProviderKind.ANTHROPIC, "claude-test", "sk-ant-test-1")), built.toList())
            val received = providers.getValue(ProviderKind.ANTHROPIC).received.single()
            // The provider study's setup: everything read so far, in Claude's own prompt.
            val profile = AskProfile.provider(claude, ProviderKind.ANTHROPIC)
            assertEquals(AskProfile.ContextShape.EVERYTHING_READ, profile.shape)
            assertEquals(profile.responseTokens, received.options.maximumResponseTokens)
            assertEquals(AskPromptBuilder.anthropicInstructions, received.instructions)
            assertTrue(received.prompt.startsWith("<documents>\n"))
            assertTrue("Gemini Nano was not chosen", model.received.isEmpty())
            assertEquals("and ML Kit was never touched", 0, platform.modelCalls)
        }
    }

    @Test
    fun `each provider gets its own question — OpenAI's row as well as the first`() = harness().use { harness ->
        harness.run {
            register(ProviderKind.ANTHROPIC, ProviderKind.OPENAI)
            val job = ask(AskAnswerer.OPENAI)
            assertTrue("${job.state}", text(job)?.contains("(openai)") == true)
            assertEquals(1, providers.getValue(ProviderKind.OPENAI).received.size)
            assertTrue(providers.getValue(ProviderKind.ANTHROPIC).received.isEmpty())
            assertEquals(listOf(ProviderKind.OPENAI), built.map { it.first })
            assertEquals("sk-test-1", built.single().third)
            assertEquals("GPT-6.2 Sol", job.providerModelName)
            val received = providers.getValue(ProviderKind.OPENAI).received.single()
            assertEquals(AskPromptBuilder.openAiInstructions, received.instructions)
            assertTrue(received.prompt.startsWith("<excerpts>\n"))
            assertTrue(received.prompt.endsWith(AskPromptBuilder.openAiReminder))
        }
    }

    @Test
    fun `a provider that fails says why, and Gemini Nano is not asked behind the reader's back`() =
        harness(failing = mapOf(ProviderKind.ANTHROPIC to AskFailure.OutOfCredit)).use { harness ->
            harness.run {
                register(ProviderKind.ANTHROPIC)
                val job = ask(AskAnswerer.ANTHROPIC)
                assertEquals(AskJob.State.Failed(AskFailure.OutOfCredit), job.state)
                assertEquals(AskAnswerer.ANTHROPIC, job.answerer)
                assertEquals(
                    "Your Anthropic account is out of credit or has reached its spending limit.",
                    AskFailure.OutOfCredit.message("phone", job.answerer),
                )
                assertTrue(AskFailure.OutOfCredit.offersDeviceInstead)
                assertTrue("no silent switch to Gemini Nano", model.received.isEmpty())
                assertEquals(0, platform.modelCalls)
            }
        }

    @Test
    fun `the failure sentences name the provider`() {
        val expected = mapOf(
            AskFailure.KeyRefused to "Anthropic refused your key. Check it in Settings › Advanced.",
            AskFailure.OutOfCredit to "Your Anthropic account is out of credit or has reached its spending limit.",
            AskFailure.RateLimited to "Anthropic is limiting how often your key can ask. Try again in a minute.",
            AskFailure.ModelUnavailable to "The Anthropic model you chose isn't available to your key. Choose another in Settings › Advanced.",
            AskFailure.ProviderUnreachable to "Couldn't reach Anthropic. Check your connection and try again.",
            AskFailure.Declined to "Anthropic declined to answer that one.",
        )
        for ((failure, sentence) in expected) assertEquals(sentence, failure.message("phone", AskAnswerer.ANTHROPIC))
        assertEquals("Couldn't reach OpenAI. Check your connection and try again.", AskFailure.ProviderUnreachable.message("phone", AskAnswerer.OPENAI))
        // Gemini Nano's own sentences are as they were.
        assertEquals("Gemini Nano declined to answer that one.", AskFailure.Declined.message("phone"))
    }

    @Test
    fun `changing the model builds a new one, asking again reuses it, and a replaced key is used at once`() = harness().use { harness ->
        harness.run {
            register(ProviderKind.ANTHROPIC)
            ask(AskAnswerer.ANTHROPIC)
            ask(AskAnswerer.ANTHROPIC)
            assertEquals(listOf("claude-test"), built.map { it.second })
            coordinator.chooseModel(ProviderKind.ANTHROPIC, claude.copy(id = "claude-b", displayName = "Claude B"))
            val job = ask(AskAnswerer.ANTHROPIC)
            assertEquals(listOf("claude-test", "claude-b"), built.map { it.second })
            assertEquals("Claude B", job.providerModelName)
            // The same model, another key: the new key, straight away.
            assertTrue(coordinator.registerKey(ProviderKind.ANTHROPIC, "sk-ant-test-2", claude.copy(id = "claude-b", displayName = "Claude B")))
            ask(AskAnswerer.ANTHROPIC)
            assertEquals("sk-ant-test-2", built.last().third)
        }
    }

    @Test
    fun `removing the OpenAI key leaves the Anthropic one, and OpenAI can no longer be asked`() {
        val tokens = TestTokens()
        harness(keyStore = tokens).use { harness ->
            harness.run {
                register(ProviderKind.ANTHROPIC, ProviderKind.OPENAI)
                coordinator.setDefaultAnswerer(AskAnswerer.OPENAI)
                coordinator.removeKey(ProviderKind.OPENAI)
                assertEquals(listOf(ProviderKind.ANTHROPIC), keys.registered)
                assertNull(tokens.read("openai"))
                assertEquals("sk-ant-test-1", tokens.read("anthropic"))
                assertNull("a default naming a removed key goes with it", settings.askDefaultProvider)
                val job = ask(AskAnswerer.OPENAI)
                assertTrue(job.state is AskJob.State.Failed)
                assertTrue(providers.getValue(ProviderKind.OPENAI).received.isEmpty())
                assertTrue(text(ask(AskAnswerer.ANTHROPIC))?.contains("(anthropic)") == true)
            }
        }
    }

    // Where a question starts

    @Test
    fun `a new question starts on the phone unless the reader set a default`() {
        val settings = PlaybackSettings(InMemoryKeyValueStore(), SignOutCentre())
        try {
            val both = listOf(ProviderKind.ANTHROPIC, ProviderKind.OPENAI)
            assertEquals(AskAnswerer.DEVICE, AskDefaults.answerer(settings, both, deviceSupported = true))
            settings.askDefaultProvider = ProviderKind.OPENAI.rawValue
            assertEquals(AskAnswerer.OPENAI, AskDefaults.answerer(settings, both, deviceSupported = true))
            // A default naming a provider whose key has gone is ignored.
            assertEquals(AskAnswerer.DEVICE, AskDefaults.answerer(settings, listOf(ProviderKind.ANTHROPIC), deviceSupported = true))
            assertEquals(listOf(AskAnswerer.DEVICE, AskAnswerer.ANTHROPIC, AskAnswerer.OPENAI), AskDefaults.choices(both, deviceSupported = true))
            // A phone that can never run Gemini Nano starts on the first key added.
            settings.askDefaultProvider = null
            assertEquals(AskAnswerer.OPENAI, AskDefaults.answerer(settings, listOf(ProviderKind.OPENAI, ProviderKind.ANTHROPIC), deviceSupported = false))
            assertEquals(listOf(AskAnswerer.ANTHROPIC), AskDefaults.choices(listOf(ProviderKind.ANTHROPIC), deviceSupported = false))
        } finally {
            settings.close()
        }
    }

    @Test
    fun `choosing a provider for one question does not make it the next one's`() = harness().use { harness ->
        harness.run {
            register(ProviderKind.ANTHROPIC)
            assertEquals(AskAnswerer.DEVICE, coordinator.defaultAnswerer)
            ask(AskAnswerer.ANTHROPIC)
            assertEquals("the device is still where a new question starts", AskAnswerer.DEVICE, coordinator.defaultAnswerer)
            assertNull(settings.askDefaultProvider)
            // The Settings default is honoured.
            coordinator.setDefaultAnswerer(AskAnswerer.ANTHROPIC)
            assertEquals(AskAnswerer.ANTHROPIC, coordinator.defaultAnswerer)
            coordinator.setDefaultAnswerer(AskAnswerer.DEVICE)
            assertNull(settings.askDefaultProvider)
        }
    }

    @Test
    fun `Gemini Nano still downloading stays the default, and says why it cannot answer yet`() {
        val device = ScriptedAnswerModel()
        val platform = CountingPlatform(availability = AskAvailability.MODEL_DOWNLOADING, model = device)
        harness(platform = platform).use { harness ->
            harness.run {
                register(ProviderKind.ANTHROPIC)
                coordinator.checkAvailability()?.join()
                assertTrue(settings.askEnabled)
                assertTrue(coordinator.deviceSupported)
                assertEquals(AskAnswerer.DEVICE, coordinator.defaultAnswerer)
                assertEquals(listOf(AskAnswerer.DEVICE, AskAnswerer.ANTHROPIC), coordinator.answerChoices)
                assertEquals(AskCopy.stillDownloading(), coordinator.deviceNotice)
                assertTrue("the sheet takes a question for the key", coordinator.canAsk)
                assertNull(coordinator.sheetNotice)
            }
        }
    }

    // A phone that cannot run Gemini Nano

    @Test
    fun `on a phone without Gemini Nano, a key is what answers — the first added`() {
        val (defaults, tokens) = registeredBeforeLaunch(ProviderKind.OPENAI, ProviderKind.ANTHROPIC)
        val platform = CountingPlatform().apply { hasSystemService = false }
        harness(platform = platform, defaults = defaults, keyStore = tokens).use { harness ->
            harness.run {
                assertTrue("a key keeps Ask on", settings.askEnabled)
                assertFalse(coordinator.deviceSupported)
                assertEquals(AskAnswerer.OPENAI, coordinator.defaultAnswerer)
                assertEquals(
                    "neither is Gemini Nano offered",
                    listOf(AskAnswerer.OPENAI, AskAnswerer.ANTHROPIC),
                    coordinator.answerChoices,
                )
                assertTrue("the sparkle shows", coordinator.isOffered)
                assertTrue(coordinator.canAsk)
                assertTrue("the switch can be used", coordinator.isSupported)
                assertTrue(coordinator.settingsState.isOn)
                assertEquals(AskCopy.keysOnly(listOf(ProviderKind.OPENAI, ProviderKind.ANTHROPIC)), coordinator.settingsFooter)
                assertTrue(text(ask(coordinator.defaultAnswerer))?.contains("(openai)") == true)
                // A Settings default naming a registered provider wins.
                coordinator.setDefaultAnswerer(AskAnswerer.ANTHROPIC)
                assertEquals(AskAnswerer.ANTHROPIC, coordinator.defaultAnswerer)
                assertEquals("ML Kit is never asked anything", 0, platform.calls)
            }
        }
    }

    @Test
    fun `without a key, nothing about a phone without Gemini Nano changes`() {
        val platform = CountingPlatform().apply { hasSystemService = false }
        harness(platform = platform).use { harness ->
            harness.run {
                assertFalse("Ask goes back off, as it always did", settings.askEnabled)
                assertFalse(coordinator.isSupported)
                assertFalse(coordinator.isOffered)
                assertEquals(AskSettingsState.Unsupported, coordinator.settingsState)
            }
        }
    }

    /** Every path that turned Ask back off only sets Gemini Nano aside when a key is registered. */
    @Test
    fun `a keyed phone keeps Ask on by every path that used to turn it off`() {
        // Turning it on on a phone with no AICore.
        run {
            val (defaults, tokens) = registeredBeforeLaunch(ProviderKind.ANTHROPIC)
            val platform = CountingPlatform().apply { hasSystemService = false }
            harness(platform = platform, defaults = defaults, keyStore = tokens, askEnabled = false).use { harness ->
                harness.run {
                    coordinator.setEnabled(true)
                    assertTrue(settings.askEnabled)
                    assertNull(coordinator.checkAvailability())
                    assertEquals(0, platform.calls)
                }
            }
        }
        // ML Kit saying the phone will never run it.
        run {
            val platform = CountingPlatform(availability = AskAvailability.UNSUPPORTED_DEVICE)
            harness(platform = platform).use { harness ->
                harness.run {
                    register(ProviderKind.ANTHROPIC)
                    coordinator.checkAvailability()?.join()
                    assertTrue(settings.askEnabled)
                    assertFalse(coordinator.deviceSupported)
                    assertEquals(AskAnswerer.ANTHROPIC, coordinator.defaultAnswerer)
                    assertTrue(coordinator.isOffered)
                }
            }
        }
        // A system update needed: Gemini Nano is set aside, the default stays where it was.
        run {
            val platform = CountingPlatform(availability = AskAvailability.NEEDS_SYSTEM_UPDATE)
            harness(platform = platform).use { harness ->
                harness.run {
                    register(ProviderKind.ANTHROPIC)
                    coordinator.checkAvailability()?.join()
                    assertTrue(settings.askEnabled)
                    assertEquals(AskCopy.needsSystemUpdate(), coordinator.deviceNotice)
                    assertTrue(coordinator.settingsFooter.startsWith(AskCopy.needsSystemUpdate()))
                }
            }
        }
        // Two checks that never came back.
        run {
            val (defaults, tokens) = registeredBeforeLaunch(ProviderKind.ANTHROPIC)
            defaults.putInt(AskCoordinator.UNFINISHED_CHECKS_KEY, AskCoordinator.UNFINISHED_CHECK_LIMIT)
            val platform = CountingPlatform()
            harness(platform = platform, defaults = defaults, keyStore = tokens).use { harness ->
                harness.run {
                    assertTrue(settings.askEnabled)
                    assertFalse(coordinator.deviceSupported)
                    assertNull("ML Kit is not asked again", coordinator.checkAvailability())
                    coordinator.appDidBecomeActive()
                    assertEquals(0, platform.calls)
                    assertEquals(AskAnswerer.ANTHROPIC, coordinator.defaultAnswerer)
                    // Off and on again is the reader asking: Gemini Nano is tried once more.
                    coordinator.setEnabled(false)
                    coordinator.setEnabled(true)
                    coordinator.checkAvailability()?.join()
                    assertEquals(1, platform.availabilityCalls)
                    assertTrue(coordinator.deviceSupported)
                }
            }
        }
        // Gemini Nano that could not be made.
        run {
            val device = ScriptedAnswerModel()
            val platform = CountingPlatform(model = device).apply { makeModelThrows = NoClassDefFoundError("com/google/mlkit/genai/prompt/Generation") }
            harness(platform = platform).use { harness ->
                harness.run {
                    register(ProviderKind.ANTHROPIC)
                    val job = ask(AskAnswerer.DEVICE)
                    assertTrue(job.state is AskJob.State.Failed)
                    assertTrue(settings.askEnabled)
                    assertFalse(coordinator.deviceSupported)
                    assertTrue(text(ask(AskAnswerer.ANTHROPIC))?.contains("(anthropic)") == true)
                }
            }
        }
        // AICore removed while the app was away.
        run {
            val platform = CountingPlatform()
            harness(platform = platform).use { harness ->
                harness.run {
                    register(ProviderKind.ANTHROPIC)
                    platform.hasSystemService = false
                    coordinator.appDidBecomeActive()
                    assertTrue(settings.askEnabled)
                    assertFalse(coordinator.deviceSupported)
                }
            }
        }
        // The model's download failing.
        run {
            val platform = CountingPlatform(
                availability = AskAvailability.MODEL_DOWNLOADABLE,
                scriptedDownload = listOf(ModelDownload.Started(100), ModelDownload.Failed(AskFailure.Other("no room"))),
            )
            harness(platform = platform).use { harness ->
                harness.run {
                    register(ProviderKind.ANTHROPIC)
                    coordinator.checkAvailability()?.join()
                    repeat(200) { if (coordinator.deviceNotice != "no room") delay(5) }
                    assertTrue(settings.askEnabled)
                    assertEquals("no room", coordinator.deviceNotice)
                }
            }
        }
    }

    @Test
    fun `removing the last key on a phone without Gemini Nano turns Ask back off`() {
        val (defaults, tokens) = registeredBeforeLaunch(ProviderKind.ANTHROPIC)
        val platform = CountingPlatform().apply { hasSystemService = false }
        harness(platform = platform, defaults = defaults, keyStore = tokens).use { harness ->
            harness.run {
                assertTrue(settings.askEnabled)
                coordinator.removeKey(ProviderKind.ANTHROPIC)
                assertFalse(settings.askEnabled)
                assertFalse(coordinator.isOffered)
                assertEquals(AskSettingsState.Unsupported, coordinator.settingsState)
            }
        }
    }

    @Test
    fun `getting ready never warms an unready Gemini Nano or contacts a provider`() {
        val (defaults, tokens) = registeredBeforeLaunch(ProviderKind.ANTHROPIC)
        val platform = CountingPlatform().apply { hasSystemService = false }
        harness(platform = platform, defaults = defaults, keyStore = tokens).use { harness ->
            harness.run {
                val source = source()
                coordinator.prepare(source)
                coordinator.warmUp(source.bookUuid)?.join()
                assertTrue("the index is built for the key's questions", coordinator.store.isPrepared(source))
                assertEquals(0, model.prewarmCount)
                assertTrue("no provider model was even built", built.isEmpty())
                assertTrue(providers.getValue(ProviderKind.ANTHROPIC).received.isEmpty())
                assertEquals(0, providers.getValue(ProviderKind.ANTHROPIC).prewarmCount)
                assertEquals("nor ML Kit asked", 0, platform.calls)
            }
        }
    }

    @Test
    fun `with Gemini Nano ready, getting ready warms it and still contacts no provider`() = harness().use { harness ->
        harness.run {
            register(ProviderKind.ANTHROPIC, ProviderKind.OPENAI)
            val source = source()
            coordinator.prepare(source)
            coordinator.warmUp(source.bookUuid)?.join()
            assertEquals(1, model.prewarmCount)
            assertTrue(built.isEmpty())
            for (provider in providers.values) assertEquals(0, provider.prewarmCount)
        }
    }

    // The keys themselves

    @Test
    fun `a registration restored from a backup without its key is not a key`() {
        val defaults = InMemoryKeyValueStore()
        val first = AIKeys(TestTokens(), defaults)
        assertTrue(first.register(ProviderKind.ANTHROPIC, "sk-ant-test-1", claude))
        // Another phone: the same preferences, no sealed key.
        val restored = AIKeys(TestTokens(), defaults)
        assertFalse(restored.hasAny)
        assertNull(restored.key(ProviderKind.ANTHROPIC))
        assertTrue("the preferences never hold the key", defaults.getString(AIKeys.REGISTRATIONS_KEY)?.contains("sk-ant") == false)
    }

    @Test
    fun `a key that does not read back once is not forgotten`() {
        val defaults = InMemoryKeyValueStore()
        val tokens = TestTokens()
        assertTrue(AIKeys(tokens, defaults).register(ProviderKind.OPENAI, "sk-test-1", gpt))
        val flaky = FlakyTokens(tokens)
        val keys = AIKeys(flaky, defaults)
        assertFalse("not readable at launch", keys.hasAny)
        flaky.failing = false
        keys.refresh()
        assertEquals(listOf(ProviderKind.OPENAI), keys.registered)
        assertEquals("sk-test-1", keys.key(ProviderKind.OPENAI))
    }

    @Test
    fun `nothing is saved when the key cannot be stored`() {
        val defaults = InMemoryKeyValueStore()
        val keys = AIKeys(NoKeys, defaults)
        assertFalse(keys.register(ProviderKind.ANTHROPIC, "sk-ant-test-1", claude))
        assertFalse(keys.hasAny)
        assertNull(defaults.getString(AIKeys.REGISTRATIONS_KEY))
    }

    @Test
    fun `with a key, the Settings footer says where questions can go`() = harness().use { harness ->
        harness.run {
            assertEquals(AskSettingsState.On.footer(), coordinator.settingsFooter)
            register(ProviderKind.ANTHROPIC)
            assertEquals(AskCopy.promise() + AskCopy.providerSentence(listOf(ProviderKind.ANTHROPIC)), coordinator.settingsFooter)
            assertTrue(coordinator.settingsFooter.contains("goes there with the book so far, under your account"))
            assertEquals("Sends your question and the book so far to Anthropic, using your key.", AskDefaults.caption(AskAnswerer.ANTHROPIC))
        }
    }

    /** A key store that will not read until told to: a Keystore that is not ready yet. */
    private class FlakyTokens(private val inner: TokenPersisting) : TokenPersisting {
        @Volatile var failing = true

        override fun read(account: String): String? = if (failing) null else inner.read(account)

        override fun write(token: String, account: String): Boolean = inner.write(token, account)

        override fun delete(account: String): Boolean = inner.delete(account)
    }
}
