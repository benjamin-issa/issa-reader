package com.benjaminissa.issareader.playback.android

import android.content.Context
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.AudioPlaybackConfiguration
import android.os.Build
import android.os.Handler
import android.os.Looper

/**
 * Reports whether a headphone-class device is the output route, now and each
 * time a device comes or goes or the route moves: Swift's route-change observer in
 * `RemoteCommandCenter`, feeding `CommandRouter.headphonesRouted`.
 *
 * Which surface the wheel resolves against — and therefore whether the track
 * commands exist at all — depends on it, as it does for the car.
 *
 * @param onChange called on the main thread with the current answer, once at
 *   once and again on every device change.
 */
class HeadphoneRouteMonitor(context: Context, private val onChange: (Boolean) -> Unit) : AutoCloseable {
    private val audioManager: AudioManager = context.getSystemService(AudioManager::class.java)

    private val callback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>?) = report()

        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>?) = report()
    }

    private var last: Boolean? = null

    /**
     * Where media goes can change with no device coming or going — the reader
     * picks the speaker in the system's output switcher — so from Android 13,
     * where the route is the active one, any change in playback (which includes
     * the device it goes to) is looked at as well.
     */
    private val playbackCallback = object : AudioManager.AudioPlaybackCallback() {
        override fun onPlaybackConfigChanged(configs: MutableList<AudioPlaybackConfiguration>?) = report()
    }

    init {
        val main = Handler(Looper.getMainLooper())
        audioManager.registerAudioDeviceCallback(callback, main)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            audioManager.registerAudioPlaybackCallback(playbackCallback, main)
        }
        report()
    }

    /** Reports the route: the first time, and after that only when the answer changed. */
    private fun report() {
        val routed = HeadphoneRoute.isRouted(audioManager)
        if (routed == last) return
        last = routed
        onChange(routed)
    }

    override fun close() {
        audioManager.unregisterAudioDeviceCallback(callback)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) audioManager.unregisterAudioPlaybackCallback(playbackCallback)
    }
}
