package com.benjaminissa.issareader.app.ask

import com.benjaminissa.issareader.app.ask.AskHarness.Companion.boundary
import com.benjaminissa.issareader.app.ask.AskHarness.Companion.source
import com.benjaminissa.issareader.ask.AskAvailability
import com.benjaminissa.issareader.ask.AskFailure
import com.benjaminissa.issareader.ask.android.MlKitStartup
import com.benjaminissa.issareader.ask.android.ModelDownload
import kotlinx.coroutines.delay
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Ask switch, and the reader's decision that with it off nothing reaches
 * Google: ML Kit reports to Google from its first call, so while Ask is off
 * nothing from `:ask-android` may be constructed or called — not at launch,
 * not when Settings opens, not when a book opens. Android's own; the iPhone
 * reads Apple Intelligence's availability freely, and its suite has nothing
 * like this.
 */
class AskSwitchTest {
    private val noun = "phone"

    /** Waits, bounded, for something the coordinator's own thread will do. */
    private suspend fun eventually(condition: () -> Boolean) {
        repeat(400) {
            if (condition()) return
            delay(5)
        }
    }

    @Test
    fun `nothing reaches Gemini Nano while Ask is off`() {
        val notifier = CountingNotifier()
        AskHarness(askEnabled = false, notifier = notifier).use { harness ->
            harness.run {
                // Launch, the app going and coming back, Settings drawing its
                // section, a book opening its sheet, a question tried anyway.
                coordinator.appDidBecomeActive()
                coordinator.appDidEnterBackground()
                coordinator.appDidBecomeActive()
                assertNull("no check is even started", coordinator.checkAvailability())
                assertEquals(AskSettingsState.Off, coordinator.settingsState)
                assertEquals(AskCopy.promise(), AskSettingsState.Off.footer())
                assertFalse(coordinator.isOffered)
                assertFalse(coordinator.isReady)
                assertEquals(AskCopy.TURNED_OFF, coordinator.sheetNotice)
                coordinator.prepare(source())
                assertNull(coordinator.warmUp(source().bookUuid))
                assertNull(coordinator.ask("What did Alice follow?", source(), boundary()))
                coordinator.reopened(source().bookUuid)
                coordinator.purgeAll(keeping = emptySet())
                delay(50)

                assertEquals("no call into Gemini Nano with Ask off", 0, platform.calls)
                assertFalse("and ML Kit never started", MlKitStartup.isStarted)
                assertEquals("nor a permission asked for a feature that is off", 0, notifier.authorizationRequests)
            }
        }
    }

    @Test
    fun `turning Ask on asks this phone once, and an available phone stays on`() = AskHarness(askEnabled = false).use { harness ->
        harness.run {
            coordinator.setEnabled(true)
            coordinator.checkAvailability()?.join()

            assertEquals(1, platform.availabilityCalls)
            assertTrue(settings.askEnabled)
            assertEquals(AskSettingsState.On, coordinator.settingsState)
            assertEquals(AskCopy.promise(noun), coordinator.settingsState.footer(noun))
            assertTrue(coordinator.isOffered)
            assertTrue(coordinator.isReady)
            assertNull(coordinator.sheetNotice)
            assertEquals("the model is made when first needed, not when the switch moves", 0, platform.modelCalls)
        }
    }

    @Test
    fun `a model that can be downloaded is downloaded, with its progress under the switch`() {
        val platform = CountingPlatform(availability = AskAvailability.MODEL_DOWNLOADABLE, scriptedDownload = null)
        AskHarness(askEnabled = false, platform = platform).use { harness ->
            harness.run {
                coordinator.setEnabled(true)
                coordinator.checkAvailability()?.join()
                assertEquals(1, platform.downloadCalls)
                assertTrue(settings.askEnabled)
                assertEquals(AskSettingsState.Downloading(null), coordinator.settingsState)
                assertEquals("Gemini Nano is downloading to this phone…", coordinator.settingsState.footer(noun))
                assertTrue("still offered: it comes right on its own", coordinator.isOffered)
                assertFalse(coordinator.isReady)

                platform.downloadEvents.send(ModelDownload.Started(1_000))
                platform.downloadEvents.send(ModelDownload.Progress(420, 1_000))
                eventually { coordinator.settingsState == AskSettingsState.Downloading(0.42) }
                assertEquals("Gemini Nano is downloading to this phone… 42%", coordinator.settingsState.footer(noun))

                platform.downloadEvents.send(ModelDownload.Completed)
                eventually { coordinator.isReady }
                assertEquals(AskSettingsState.On, coordinator.settingsState)
            }
        }
    }

    @Test
    fun `a model the system is downloading already is waited for`() {
        val platform = CountingPlatform(availability = AskAvailability.MODEL_DOWNLOADING)
        AskHarness(askEnabled = false, platform = platform).use { harness ->
            harness.run {
                coordinator.setEnabled(true)
                coordinator.checkAvailability()?.join()
                assertTrue(settings.askEnabled)
                assertEquals(AskSettingsState.SystemDownloading, coordinator.settingsState)
                assertEquals(
                    "Gemini Nano is still downloading its model to this phone. Asking will work once it finishes.",
                    coordinator.settingsState.footer(noun),
                )
                assertEquals(0, platform.downloadCalls)
            }
        }
    }

    @Test
    fun `a phone that needs a system update turns the switch back off, and says so`() {
        val platform = CountingPlatform(availability = AskAvailability.NEEDS_SYSTEM_UPDATE)
        AskHarness(askEnabled = false, platform = platform).use { harness ->
            harness.run {
                coordinator.setEnabled(true)
                coordinator.checkAvailability()?.join()
                assertFalse(settings.askEnabled)
                assertEquals(AskSettingsState.NeedsSystemUpdate, coordinator.settingsState)
                assertFalse(coordinator.settingsState.isOn)
                assertEquals(
                    "Gemini Nano needs a system update on this phone before it can answer. Check for updates in Settings, then come back.",
                    coordinator.settingsState.footer(noun),
                )
                assertFalse(coordinator.isOffered)
            }
        }
    }

    @Test
    fun `a phone that cannot run the model turns the switch back off, and says so`() {
        val platform = CountingPlatform(availability = AskAvailability.UNSUPPORTED_DEVICE)
        AskHarness(askEnabled = false, platform = platform).use { harness ->
            harness.run {
                coordinator.setEnabled(true)
                coordinator.checkAvailability()?.join()
                assertFalse(settings.askEnabled)
                assertEquals(AskSettingsState.Unsupported, coordinator.settingsState)
                assertEquals("This phone can't run Gemini Nano, so asking isn't available here.", coordinator.settingsState.footer(noun))

                // And with it back off, nothing more is asked of ML Kit.
                val calls = platform.calls
                coordinator.appDidBecomeActive()
                delay(20)
                assertEquals(calls, platform.calls)
            }
        }
    }

    @Test
    fun `a download that fails turns the switch back off with the reason, and on again retries`() {
        val failure = AskFailure.Other("Gemini Nano needs more free storage to download its model. Free up some space and try again.")
        val platform = CountingPlatform(
            availability = AskAvailability.MODEL_DOWNLOADABLE,
            scriptedDownload = listOf(ModelDownload.Started(10), ModelDownload.Failed(failure)),
        )
        AskHarness(askEnabled = false, platform = platform).use { harness ->
            harness.run {
                coordinator.setEnabled(true)
                coordinator.checkAvailability()?.join()
                eventually { !settings.askEnabled }
                assertEquals(AskSettingsState.DownloadFailed(failure), coordinator.settingsState)
                assertEquals(failure.sentence, coordinator.settingsState.footer(noun))

                coordinator.setEnabled(true)
                coordinator.checkAvailability()?.join()
                eventually { platform.downloadCalls == 2 }
                assertEquals(2, platform.downloadCalls)
            }
        }
    }

    @Test
    fun `availability is read again on coming back only while Ask is on`() = AskHarness(askEnabled = false).use { harness ->
        harness.run {
            coordinator.appDidBecomeActive()
            assertEquals(0, platform.availabilityCalls)

            coordinator.setEnabled(true)
            coordinator.checkAvailability()?.join()
            assertEquals(1, platform.availabilityCalls)

            coordinator.appDidEnterBackground()
            coordinator.appDidBecomeActive()
            coordinator.checkAvailability()?.join()
            assertEquals(2, platform.availabilityCalls)

            coordinator.setEnabled(false)
            coordinator.appDidBecomeActive()
            delay(20)
            assertEquals(2, platform.availabilityCalls)
            assertEquals(AskSettingsState.Off, coordinator.settingsState)
        }
    }
}
