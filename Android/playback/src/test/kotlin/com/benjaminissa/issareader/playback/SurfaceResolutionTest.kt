package com.benjaminissa.issareader.playback

import org.junit.Assert.assertEquals
import org.junit.Test

// Ported from `PlaybackTests.swift` (`SurfaceResolutionTests`).

/**
 * Where a control's binding is looked up — what made the Headphones tab real.
 *
 * Nothing ever *assigns* HEADPHONES: the car bridge only ever hands over CAR
 * and PHONE, so before this every binding stored under the headphones surface
 * was silently discarded. The surface is inferred per control from the audio
 * route instead, and only for the wheel, because the wheel — next/previous
 * track — is where headphones' double- and triple-press arrive.
 */
class SurfaceResolutionTest {
    /** The wheel belongs to headphones while a headphone-class device is routed. */
    @Test
    fun wheelFollowsHeadphones() {
        assertEquals(
            ControlSurface.HEADPHONES,
            CommandRouter.surface(PlaybackControl.WHEEL_NEXT, ControlSurface.PHONE, headphonesRouted = true),
        )
        assertEquals(
            ControlSurface.HEADPHONES,
            CommandRouter.surface(PlaybackControl.WHEEL_PREVIOUS, ControlSurface.PHONE, headphonesRouted = true),
        )
        // Unrouted, the wheel is the phone's — a Bluetooth head unit's buttons.
        assertEquals(
            ControlSurface.PHONE,
            CommandRouter.surface(PlaybackControl.WHEEL_NEXT, ControlSurface.PHONE, headphonesRouted = false),
        )
    }

    /** The tap controls stay with the phone: skip commands only ever come from a screen. */
    @Test
    fun tapsStayOnThePhone() {
        assertEquals(
            ControlSurface.PHONE,
            CommandRouter.surface(PlaybackControl.TAP_FORWARD, ControlSurface.PHONE, headphonesRouted = true),
        )
        assertEquals(
            ControlSurface.PHONE,
            CommandRouter.surface(PlaybackControl.TAP_BACKWARD, ControlSurface.PHONE, headphonesRouted = true),
        )
    }

    /** The car wins outright: Android Auto declares itself, the route does not decide. */
    @Test
    fun carWins() {
        for (control in PlaybackControl.entries) {
            assertEquals(ControlSurface.CAR, CommandRouter.surface(control, ControlSurface.CAR, headphonesRouted = true))
        }
    }
}
