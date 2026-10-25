package com.benjaminissa.issareader.app.media

import android.content.Context
import android.os.Looper
import androidx.car.app.connection.CarConnection
import androidx.work.Configuration
import androidx.work.testing.SynchronousExecutor
import androidx.work.testing.WorkManagerTestInitHelper
import com.benjaminissa.issareader.app.AppGraph
import com.benjaminissa.issareader.core.diagnostics.IssaLog
import com.benjaminissa.issareader.core.model.AudiobookManifest
import com.benjaminissa.issareader.playback.AudioLocation
import com.benjaminissa.issareader.playback.AudioPlayer
import com.benjaminissa.issareader.playback.AudiobookCoordinator
import com.benjaminissa.issareader.playback.ControlSurface
import com.benjaminissa.issareader.playback.MediaBackend
import com.benjaminissa.issareader.playback.MediaTime
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf

/** An engine that plays nothing: the car's coordinator needs one to exist. */
private class SilentBackend : MediaBackend {
    override var sessionListener: MediaBackend.SessionListener? = null
    override fun configureSession() = Unit
    override fun activateSession() = Unit
    override fun deactivateSession() = Unit
    override val currentItem: MediaBackend.Item? = null
    override fun replaceItem(location: AudioLocation, listener: MediaBackend.ItemListener): MediaBackend.Item =
        object : MediaBackend.Item {
            override suspend fun loadDuration(): Double = 60.0
            override suspend fun loadCarriesGain(): Boolean = true
            override val hasFailed: Boolean = false
            override val failureReason: String? = null
        }
    override fun cancelPendingSeeks() = Unit
    override suspend fun seek(to: MediaTime): Boolean = true
    override var rate: Float = 0f
    override var volume: Float = 1f
    override var gain: Float = 1f
    override val currentTime: Double = 0.0
    override val isPlaying: Boolean = false
    override fun setTimeObserver(intervalSeconds: Double, observer: ((Double) -> Unit)?) = Unit
    override fun release() = Unit
}

/**
 * The car coming and going, through the app's own graph: CarPlay's scene
 * connecting and disconnecting, which `CarPlayBridge.surfaceDidConnect` and
 * `surfaceDidDisconnect` told the remote commands and the model.
 *
 * Connecting makes the car the surface the controls resolve against, and is
 * the one thing that keeps a book on the dashboard while the phone's reader is
 * open; disconnecting gives the surface back to the phone and wakes the
 * listening hand-off, as it does on iOS.
 */
@RunWith(RobolectricTestRunner::class)
class CarConnectionTest {
    private val context: Context = RuntimeEnvironment.getApplication()

    @Before
    fun setUp() {
        WorkManagerTestInitHelper.initializeTestWorkManager(context, Configuration.Builder().setExecutor(SynchronousExecutor()).build())
    }

    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    @Test
    fun theCarIsTheSurfaceAndItsGoingHandsOff() {
        val graph = AppGraph(context, makeMediaBackend = { SilentBackend() })
        val dracula = book("Dracula", narrated = true)
        val manifest = AudiobookManifest(AudiobookManifest.Metadata(duration = 60.0), listOf(AudiobookManifest.Track("one.mp3", duration = 60.0)))
        val coordinator = AudiobookCoordinator(
            manifest,
            AudiobookCoordinator.Source.Streaming("http://localhost/", emptyMap()),
            player = AudioPlayer(SilentBackend()),
            scope = graph.mainScope,
        )
        graph.app.installListening(coordinator, dracula)
        // The reader is open on the book the car is playing: the commonest way a drive ends.
        IssaLog.clear()
        graph.media.carPresence.connectionTypeChanged(CarConnection.CONNECTION_TYPE_PROJECTION)
        graph.app.setReaderVisible(dracula.uuid, true)
        idle()
        assertEquals(ControlSurface.CAR, graph.app.controlSurface)
        assertEquals(ControlSurface.CAR, graph.nowPlaying.remote.activeSurface)
        val driving = IssaLog.export()
        assertTrue("the car holds the book while connected:\n$driving", driving.contains("reason=carConnected"))
        assertFalse(driving.contains("trigger=carDisconnected"))

        IssaLog.clear()
        graph.media.carPresence.connectionTypeChanged(CarConnection.CONNECTION_TYPE_NOT_CONNECTED)
        idle()
        assertEquals(ControlSurface.PHONE, graph.app.controlSurface)
        assertEquals(ControlSurface.PHONE, graph.nowPlaying.remote.activeSurface)
        // The hand-off ran for the car's going, and got past the car's rung:
        // what stops it now is only that this reader has not opened its book.
        val parked = IssaLog.export()
        assertTrue("the hand-off ran on disconnect:\n$parked", parked.contains("trigger=carDisconnected"))
        assertTrue(parked.contains("reason=readerNotReady"))
        assertFalse(parked.contains("reason=carConnected"))
    }
}
