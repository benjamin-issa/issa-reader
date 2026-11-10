package com.benjaminissa.issareader.app.ask

import com.benjaminissa.issareader.app.ask.AskHarness.Companion.boundary
import com.benjaminissa.issareader.app.ask.AskHarness.Companion.source
import com.benjaminissa.issareader.ask.AskAvailability
import com.benjaminissa.issareader.core.InMemoryKeyValueStore
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A Boox Palma (Android 11, no Gemini Nano) took the Ask switch, crashed the
 * moment it was turned on, and then crashed on every launch because the switch
 * had been saved on. Nothing ML Kit does may take the process down, and a
 * check that did must not be repeated.
 */
class AskCrashSafetyTest {
    @Test
    fun `a RuntimeException from the availability check turns Ask back off as unsupported`() =
        AskHarness(askEnabled = false).use { harness ->
            harness.run {
                platform.availabilityThrows = RuntimeException("no AICore")
                coordinator.setEnabled(true)
                coordinator.checkAvailability()?.join()
                assertFalse(settings.askEnabled)
                assertEquals(AskSettingsState.Unsupported, coordinator.settingsState)
            }
        }

    @Test
    fun `an Error from the platform does not escape the coordinator`() =
        AskHarness(askEnabled = false).use { harness ->
            harness.run {
                // Where a bare launch would have killed the process.
                platform.availabilityThrows = NoClassDefFoundError("com/google/mlkit/genai/prompt/Generation")
                coordinator.setEnabled(true)
                coordinator.checkAvailability()?.join()
                assertFalse(settings.askEnabled)
                assertEquals(AskSettingsState.Unsupported, coordinator.settingsState)
            }
        }

    @Test
    fun `the scope itself survives a throw from anywhere inside Ask work`() {
        val uncaught = mutableListOf<Throwable>()
        // A scope with no handler of its own, as AppGraph's is: the coordinator supplies one.
        val outer = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val harness = AskHarness(askEnabled = false)
        val coordinator = AskCoordinator(harness.settings, harness.platform, harness.defaults, outer, centre = harness.centre)
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { _, e -> uncaught += e }
        try {
            // The check says "downloadable", and starting the download throws
            // from inside a coroutine nothing else guards.
            harness.platform.availability = AskAvailability.MODEL_DOWNLOADABLE
            harness.platform.downloadThrows = IllegalStateException("boom")
            coordinator.setEnabled(true)
            runBlocking { coordinator.checkAvailability()?.join() }
        } finally {
            Thread.setDefaultUncaughtExceptionHandler(previous)
            coordinator.close()
            harness.close()
        }
        assertTrue(uncaught.toString(), uncaught.isEmpty())
    }

    @Test
    fun `a model that cannot be made degrades to Ask unavailable instead of crashing`() =
        AskHarness(askEnabled = true).use { harness ->
            harness.run {
                platform.makeModelThrows = NoClassDefFoundError("GeminiNanoAnswerModel")
                val job = coordinator.ask("What did Alice follow?", source(), boundary())
                assertNotNull(job)
                assertTrue(job!!.state is AskJob.State.Failed)
                assertFalse("Ask is off again", settings.askEnabled)
                assertEquals(AskSettingsState.Unsupported, coordinator.settingsState)
            }
        }

    @Test
    fun `a check that never returned is found at launch, and Ask stays off without calling Gemini Nano`() {
        val defaults = InMemoryKeyValueStore()
        // What the previous process left behind when it died inside ML Kit.
        defaults.putBoolean(AskCoordinator.CHECK_IN_FLIGHT_KEY, true)
        AskHarness(askEnabled = true, defaults = defaults).use { harness ->
            harness.run {
                assertFalse(settings.askEnabled)
                assertEquals(AskSettingsState.Unsupported, coordinator.settingsState)
                assertFalse("the marker is cleared", defaults.getBoolean(AskCoordinator.CHECK_IN_FLIGHT_KEY))
                coordinator.appDidBecomeActive()
                assertNull(coordinator.checkAvailability())
                assertEquals(0, platform.calls)
            }
        }
    }

    @Test
    fun `the marker is written before Gemini Nano is called and cleared after`() {
        val seen = CompletableDeferred<Boolean>()
        val defaults = InMemoryKeyValueStore()
        // A platform that reads the marker at the moment it is called.
        val platform = object : AskPlatform {
            override suspend fun availability(): AskAvailability {
                seen.complete(defaults.getBoolean(AskCoordinator.CHECK_IN_FLIGHT_KEY))
                return AskAvailability.AVAILABLE
            }
            override fun download() = throw UnsupportedOperationException()
            override fun makeModel() = throw UnsupportedOperationException()
        }
        AskHarness(askEnabled = false, defaults = defaults).also { /* only for its settings/scope */ }.use { harness ->
            val coordinator = AskCoordinator(harness.settings, platform, defaults, harness.scope, centre = harness.centre)
            harness.run {
                coordinator.setEnabled(true)
                coordinator.checkAvailability()?.join()
                assertTrue("set while ML Kit was being asked", seen.await())
                assertFalse("cleared once it answered", defaults.getBoolean(AskCoordinator.CHECK_IN_FLIGHT_KEY))
            }
            coordinator.close()
        }
    }

    @Test
    fun `without the system AI service the switch cannot turn on and Gemini Nano is never called`() =
        AskHarness(askEnabled = false).use { harness ->
            harness.run {
                platform.hasSystemService = false
                coordinator.appDidBecomeActive()
                assertFalse(coordinator.isSupported)
                assertEquals(AskSettingsState.Unsupported, coordinator.settingsState)
                coordinator.setEnabled(true)
                assertFalse(settings.askEnabled)
                assertNull(coordinator.checkAvailability())
                assertEquals(0, platform.calls)
            }
        }

    @Test
    fun `a stored on with no system AI service reads as off, without calling Gemini Nano`() {
        val platform = CountingPlatform().also { it.hasSystemService = false }
        AskHarness(askEnabled = true, platform = platform).use { harness ->
            harness.run {
                assertFalse(settings.askEnabled)
                assertEquals(AskSettingsState.Unsupported, coordinator.settingsState)
                assertEquals(AskCopy.unsupported(), coordinator.sheetNotice)
                assertEquals(0, platform.calls)
            }
        }
    }
}
