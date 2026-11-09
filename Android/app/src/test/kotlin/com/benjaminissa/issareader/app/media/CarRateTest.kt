package com.benjaminissa.issareader.app.media

import com.benjaminissa.issareader.app.model.NowPlayingController
import com.benjaminissa.issareader.app.model.PlaybackSettings
import com.benjaminissa.issareader.core.InMemoryKeyValueStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * The rate button's press, on the app's own settings: CarPlay's
 * `onCycleRate`, which `AppGraph.cycleRateFromCar` is.
 */
@RunWith(RobolectricTestRunner::class)
class CarRateTest {
    /** 1 → 1.25 → 1.5 → 1.75 → 2 → 1, saved as the listener's speed each time. */
    @Test
    fun cyclesAndSaves() {
        val defaults = InMemoryKeyValueStore()
        val settings = PlaybackSettings(defaults)
        val nowPlaying = NowPlayingController(CoroutineScope(SupervisorJob() + Dispatchers.Main))
        val seen = mutableListOf<Double>()
        repeat(5) {
            CarRate.cycle(settings, nowPlaying)
            seen += settings.playbackRate
        }
        assertEquals(listOf(1.25, 1.5, 1.75, 2.0, 1.0), seen)
        // Persisted, so the next book and the next launch keep it.
        assertEquals(1.0, PlaybackSettings(defaults).playbackRate, 0.0)
        settings.playbackRate = 2.5
        CarRate.cycle(settings, nowPlaying)
        assertEquals("a speed off the car's list goes back to the start of it", 1.0, settings.playbackRate, 0.0)
        settings.close()
    }
}
