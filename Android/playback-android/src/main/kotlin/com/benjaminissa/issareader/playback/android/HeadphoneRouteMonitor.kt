package com.benjaminissa.issareader.playback.android

import android.content.Context
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Handler
import android.os.Looper

/**
 * Reports whether a headphone-class device is the output route, now and each
 * time a device comes or goes: Swift's route-change observer in
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

    init {
        audioManager.registerAudioDeviceCallback(callback, Handler(Looper.getMainLooper()))
        report()
    }

    private fun report() = onChange(HeadphoneRoute.isRouted(audioManager))

    override fun close() = audioManager.unregisterAudioDeviceCallback(callback)
}
