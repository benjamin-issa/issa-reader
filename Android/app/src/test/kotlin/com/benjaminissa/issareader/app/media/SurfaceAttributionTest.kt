package com.benjaminissa.issareader.app.media

import android.os.Looper
import androidx.media3.session.MediaController
import com.benjaminissa.issareader.playback.CommandMap
import com.benjaminissa.issareader.playback.CommandRouter
import com.benjaminissa.issareader.playback.ControlSurface
import com.benjaminissa.issareader.playback.PlaybackAction
import com.benjaminissa.issareader.playback.PlaybackControl
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.android.controller.ServiceController

/**
 * A command is read against the surface of the controller that sent it,
 * through the real session: the app's own controller is the phone even while
 * a car is connected, where iOS — which could not tell — made everything the
 * car's. A command whose sender says nothing is inferred as iOS inferred it.
 */
@RunWith(RobolectricTestRunner::class)
class SurfaceAttributionTest {
    private lateinit var host: FakeHost
    private lateinit var service: ServiceController<TestPlaybackService>
    private val actions = mutableListOf<PlaybackAction>()

    @Before
    fun setUp() {
        // The phone's tap forward means the next sentence; the car's, thirty seconds.
        val map = CommandMap()
            .withBinding(PlaybackAction.NEXT_SENTENCE, PlaybackControl.TAP_FORWARD, ControlSurface.PHONE)
            .withBinding(PlaybackAction.SKIP_FORWARD, PlaybackControl.TAP_FORWARD, ControlSurface.CAR)
        host = FakeHost(books = listOf(book("Dune")), map = map)
        host.router.onAction = { actions += it }
        TestPlaybackService.nextHost = host
        service = Robolectric.buildService(TestPlaybackService::class.java).create()
        // Something playing, so the controls have an item to act on.
        host.playing = MediaHost.Playing(book("Dune"), isPlaying = true, rate = 1f)
        host.sink?.publish(CommandRouter.nowPlaying("Dune", "Someone", null, elapsed = 10.0, duration = 100.0, rate = 1f), null)
        // A car is connected.
        host.router.activeSurface = ControlSurface.CAR
    }

    @After
    fun tearDown() {
        service.destroy()
        TestPlaybackService.nextHost = null
    }

    private fun idleUntil(condition: () -> Boolean) {
        repeat(100) {
            if (condition()) return
            shadowOf(Looper.getMainLooper()).idle()
        }
    }

    @Test
    fun theAppsOwnControllerIsThePhone() {
        val future = MediaController.Builder(RuntimeEnvironment.getApplication(), service.get().session.token).buildAsync()
        idleUntil { future.isDone }
        val controller = future.get()
        try {
            controller.seekForward()
            idleUntil { actions.isNotEmpty() }
            assertEquals(listOf(PlaybackAction.NEXT_SENTENCE), actions)
        } finally {
            controller.release()
        }
    }

    @Test
    fun aCommandFromNoOneIsInferred() {
        // The player asked directly, as a hardware key with no sender would reach it.
        service.get().player.seekForward()
        assertEquals(listOf(PlaybackAction.SKIP_FORWARD), actions)
    }
}
