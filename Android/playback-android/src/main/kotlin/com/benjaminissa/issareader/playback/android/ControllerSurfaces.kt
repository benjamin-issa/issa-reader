package com.benjaminissa.issareader.playback.android

import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.MediaSession
import com.benjaminissa.issareader.playback.ControlSurface

/**
 * Which surface a controller is, as far as the reader's bindings go.
 *
 * iOS's command centre never said where a command came from, so Swift
 * inferred it: everything belongs to the car while CarPlay is connected, and
 * the wheel controls belong to headphones while headphones are the route.
 * Android names the controller behind each command, so where that settles the
 * question this answers it:
 *
 * - **Android Auto** (and Android Automotive's media centre) is the car.
 * - **The media notification** — and the system's media controls, which Media3
 *   folds into it — and **the app's own controller** are the phone.
 * - **Anything else** — a hardware media key, a Bluetooth remote, the
 *   assistant, a watch — says nothing about where it was pressed, and is left
 *   to `CommandRouter.surface`'s inference, exactly as on iOS. That is how the
 *   headphones tab is reached: by the route, not the sender.
 */
@OptIn(UnstableApi::class)
object ControllerSurfaces {
    /** The system's media controls, when Media3 has not folded them into the notification. */
    const val SYSTEM_UI_PACKAGE = "com.android.systemui"

    /**
     * The surface [controller] is, or null when its commands must be
     * inferred.
     *
     * @param ownPackage this app's package: its own controllers are the phone.
     */
    fun surface(session: MediaSession, controller: MediaSession.ControllerInfo?, ownPackage: String): ControlSurface? {
        if (controller == null) return null
        if (isCar(session, controller)) return ControlSurface.CAR
        if (session.isMediaNotificationController(controller)) return ControlSurface.PHONE
        if (controller.packageName == SYSTEM_UI_PACKAGE || controller.packageName == ownPackage) return ControlSurface.PHONE
        return null
    }

    /** Whether [controller] is Android Auto, or a car's own media centre. */
    fun isCar(session: MediaSession, controller: MediaSession.ControllerInfo): Boolean =
        session.isAutoCompanionController(controller) || session.isAutomotiveController(controller)
}
