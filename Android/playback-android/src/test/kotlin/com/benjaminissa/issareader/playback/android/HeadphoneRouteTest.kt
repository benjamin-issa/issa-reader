package com.benjaminissa.issareader.playback.android

import android.media.AudioDeviceInfo
import android.media.AudioManager
import com.benjaminissa.issareader.playback.CommandRouter
import com.benjaminissa.issareader.playback.ControlSurface
import com.benjaminissa.issareader.playback.PlaybackControl
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.shadows.AudioDeviceInfoBuilder

// The route half of `SurfaceResolutionTests.swift`: which outputs count as
// headphones, read off the audio manager the way the media session will.

@RunWith(RobolectricTestRunner::class)
class HeadphoneRouteTest {
    private val audioManager = RuntimeEnvironment.getApplication().getSystemService(AudioManager::class.java)

    private fun output(type: Int): AudioDeviceInfo = AudioDeviceInfoBuilder.newBuilder().setType(type).build()

    private fun route(vararg types: Int) {
        shadowOf(audioManager).setOutputDevices(types.map(::output))
    }

    /** The things worn on a head are headphones; the phone's own speaker is not. */
    @Test
    fun whatCountsAsHeadphones() {
        for (type in listOf(
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
            AudioDeviceInfo.TYPE_BLE_HEADSET,
            AudioDeviceInfo.TYPE_USB_HEADSET,
            AudioDeviceInfo.TYPE_HEARING_AID,
        )) {
            assertTrue("$type", HeadphoneRoute.isHeadphoneClass(type))
        }
        for (type in listOf(
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER,
            AudioDeviceInfo.TYPE_BUILTIN_EARPIECE,
            AudioDeviceInfo.TYPE_HDMI,
            AudioDeviceInfo.TYPE_USB_DEVICE,
            AudioDeviceInfo.TYPE_BLE_SPEAKER,
            AudioDeviceInfo.TYPE_REMOTE_SUBMIX,
        )) {
            assertFalse("$type", HeadphoneRoute.isHeadphoneClass(type))
        }
    }

    /** The speaker alone is no headphone route, and a pair plugged in beside it is one. */
    @Test
    fun theRouteIsReadOffTheOutputs() {
        route(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER)
        assertFalse(HeadphoneRoute.isRouted(audioManager))

        route(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER, AudioDeviceInfo.TYPE_WIRED_HEADPHONES)
        assertTrue(HeadphoneRoute.isRouted(audioManager))

        route(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER, AudioDeviceInfo.TYPE_BLUETOOTH_A2DP)
        assertTrue(HeadphoneRoute.isRouted(audioManager))
    }

    /**
     * What the route decides: the wheel controls — where headphones' double-
     * and triple-press arrive — resolve against the headphones' bindings while
     * a pair is the route, and the phone's on the speaker. A car outranks both.
     */
    @Test
    fun theRouteChoosesTheSurface() {
        route(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER, AudioDeviceInfo.TYPE_WIRED_HEADSET)
        val worn = HeadphoneRoute.isRouted(audioManager)
        assertEquals(ControlSurface.HEADPHONES, CommandRouter.surface(PlaybackControl.WHEEL_NEXT, ControlSurface.PHONE, worn))
        assertEquals("a tap is the screen's", ControlSurface.PHONE, CommandRouter.surface(PlaybackControl.TAP_FORWARD, ControlSurface.PHONE, worn))
        assertEquals(ControlSurface.CAR, CommandRouter.surface(PlaybackControl.WHEEL_NEXT, ControlSurface.CAR, worn))

        route(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER)
        val speaker = HeadphoneRoute.isRouted(audioManager)
        assertEquals(ControlSurface.PHONE, CommandRouter.surface(PlaybackControl.WHEEL_NEXT, ControlSurface.PHONE, speaker))
    }
}
