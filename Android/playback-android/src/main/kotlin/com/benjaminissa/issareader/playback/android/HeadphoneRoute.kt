package com.benjaminissa.issareader.playback.android

import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build

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

    /** What the engine plays as: speech, as media. The route to ask about. */
    val mediaAttributes: AudioAttributes by lazy {
        AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build()
    }

    /**
     * Whether media is going to a headphone-class device.
     *
     * From Android 13 that is the devices media is actually routed to
     * (`getAudioDevicesForAttributes`): Bluetooth headphones that are merely
     * connected while the reader chose the phone's speaker do not count. Before
     * that no call says where media goes, so any connected headphone-class
     * output counts, which is where media goes when one is.
     *
     * @param sdk the Android version, a parameter so the older path can be
     *   tested on the one runtime the tests have.
     */
    fun isRouted(audioManager: AudioManager, sdk: Int = Build.VERSION.SDK_INT): Boolean {
        if (sdk >= Build.VERSION_CODES.TIRAMISU) {
            val active = try {
                audioManager.getAudioDevicesForAttributes(mediaAttributes)
            } catch (_: RuntimeException) {
                null
            }
            if (active != null) return active.any { isHeadphoneClass(it.type) }
        }
        return audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).any { isHeadphoneClass(it.type) }
    }
}
