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
    fun `two checks in a row that never returned are found at launch, and Ask stays off without calling Gemini Nano`() {
        val defaults = InMemoryKeyValueStore()
        // What two processes in a row left behind when they died inside ML Kit.
        defaults.putIntDurably(AskCoordinator.UNFINISHED_CHECKS_KEY, 2)
        AskHarness(askEnabled = true, defaults = defaults).use { harness ->
            harness.run {
                assertFalse(settings.askEnabled)
                assertEquals(AskSettingsState.Unsupported, coordinator.settingsState)
                assertEquals("the count starts again", 0, defaults.getInt(AskCoordinator.UNFINISHED_CHECKS_KEY))
                coordinator.appDidBecomeActive()
                assertNull(coordinator.checkAvailability())
                assertEquals(0, platform.calls)
            }
        }
    }

    /** A swipe-away, a low-memory kill or an update during AICore's first bind is not a crash loop. */
    @Test
    fun `one check that never returned does not turn Ask off, and the next one is made`() {
        val defaults = InMemoryKeyValueStore()
        defaults.putIntDurably(AskCoordinator.UNFINISHED_CHECKS_KEY, 1)
        AskHarness(askEnabled = true, defaults = defaults).use { harness ->
            harness.run {
                assertTrue("still on", settings.askEnabled)
                assertTrue(coordinator.isOffered)
                coordinator.checkAvailability()?.join()
                assertEquals("Gemini Nano was asked", 1, platform.calls)
                assertTrue(settings.askEnabled)
                assertEquals("and it came back, so the count is cleared", 0, defaults.getInt(AskCoordinator.UNFINISHED_CHECKS_KEY))
            }
        }
    }

    /** One interrupted check, then another that also dies: the second launch stops the loop. */
    @Test
    fun `a check that dies again after an interrupted one leaves the count that stops the next launch`() {
        val defaults = InMemoryKeyValueStore()
        defaults.putIntDurably(AskCoordinator.UNFINISHED_CHECKS_KEY, 1)
        val seen = CompletableDeferred<Int>()
        val platform = object : AskPlatform {
            override suspend fun availability(): AskAvailability {
                seen.complete(defaults.getInt(AskCoordinator.UNFINISHED_CHECKS_KEY))
                return AskAvailability.AVAILABLE
            }
            override fun download() = throw UnsupportedOperationException()
            override fun makeModel() = throw UnsupportedOperationException()
        }
        AskHarness(askEnabled = true, defaults = defaults).use { harness ->
            val coordinator = AskCoordinator(harness.settings, platform, defaults, harness.scope, centre = harness.centre)
            harness.run {
                coordinator.checkAvailability()?.join()
                assertEquals("counted before ML Kit was called: the process dying here leaves 2", 2, seen.await())
            }
            coordinator.close()
        }
    }

    @Test
    fun `the count is raised before Gemini Nano is called and back to zero after`() {
        val seen = CompletableDeferred<Int>()
        val defaults = InMemoryKeyValueStore()
        // A platform that reads the count at the moment it is called.
        val platform = object : AskPlatform {
            override suspend fun availability(): AskAvailability {
                seen.complete(defaults.getInt(AskCoordinator.UNFINISHED_CHECKS_KEY))
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
                assertEquals("raised while ML Kit was being asked", 1, seen.await())
                assertEquals("reset once it answered", 0, defaults.getInt(AskCoordinator.UNFINISHED_CHECKS_KEY))
            }
            coordinator.close()
        }
    }

    @Test
    fun `a check that threw still resets the count`() =
        AskHarness(askEnabled = false).use { harness ->
            harness.run {
                platform.availabilityThrows = RuntimeException("no AICore")
                coordinator.setEnabled(true)
                coordinator.checkAvailability()?.join()
                assertEquals(0, defaults.getInt(AskCoordinator.UNFINISHED_CHECKS_KEY))
            }
        }

    @Test
    fun `1_7_0's flag is dropped at launch and counts for nothing`() {
        val defaults = InMemoryKeyValueStore()
        defaults.putBoolean(AskCoordinator.OLD_CHECK_IN_FLIGHT_KEY, true)
        AskHarness(askEnabled = true, defaults = defaults).use { harness ->
            harness.run {
                assertTrue(settings.askEnabled)
                assertFalse(defaults.getBoolean(AskCoordinator.OLD_CHECK_IN_FLIGHT_KEY))
            }
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
