package com.benjaminissa.issareader.playback.android

import android.media.AudioDeviceInfo
import android.media.AudioManager

/**
 * Whether a headphone-class device is the output route, for
 * [com.benjaminissa.issareader.playback.CommandRouter.headphonesRouted].
 *
 * The things worn on a head: wired headphones and headsets, Bluetooth audio,
 * USB headsets, hearing aids. iOS leaves out its `carAudio` port so a plain
 * Bluetooth head unit's buttons keep resolving against the phone. Android
 * reports a head unit as Bluetooth A2DP, the same type as headphones, so it
 * cannot draw that line: a head unit without Android Auto counts as headphones
 * here. A car running Android Auto declares itself as the car surface, which
 * outranks the route.
 */
object HeadphoneRoute {
    private val headphoneTypes = setOf(
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        AudioDeviceInfo.TYPE_BLE_HEADSET,
        AudioDeviceInfo.TYPE_USB_HEADSET,
        AudioDeviceInfo.TYPE_HEARING_AID,
    )

    fun isHeadphoneClass(type: Int): Boolean = type in headphoneTypes

    /** Whether any connected output is headphone-class, which is where media goes when one is. */
    fun isRouted(audioManager: AudioManager): Boolean =
        audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).any { isHeadphoneClass(it.type) }
}
