package com.benjaminissa.issareader.playback

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A command resolved against the surface it came from.
 *
 * Android's media session names the controller behind every command — Android
 * Auto, the media notification, the app's own controller — where iOS's command
 * centre never said, so [CommandRouter] takes the surface when the session
 * knows it and infers it, as before, when it does not. No Swift counterpart:
 * `RemoteCommandCenter` had nothing to take it from.
 */
class CommandOriginTest {
    private fun router(map: CommandMap = CommandMap()): Pair<CommandRouter, MutableList<PlaybackAction>> {
        val remote = CommandRouter(map)
        val actions = mutableListOf<PlaybackAction>()
        remote.onAction = { actions.add(it) }
        remote.activate()
        return remote to actions
    }

    /** The car's binding answers the car, even while the phone's transport is the one on offer. */
    @Test
    fun theCarsWheelIsTheCarsBeforeTheConnectIsHeard() {
        val map = CommandMap().withBinding(PlaybackAction.NEXT_CHAPTER, PlaybackControl.WHEEL_NEXT, ControlSurface.CAR)
        val (remote, actions) = router(map)
        // Nothing on the phone binds the wheel, so no track buttons are drawn…
        assertFalse(checkNotNull(remote.transport).usesTrackCommands)
        // …and an inferred track command is not answered…
        remote.nextTrack()
        assertTrue(actions.isEmpty())
        // …but Android Auto's own is, by the car's binding.
        assertTrue(remote.offersTrackCommands(ControlSurface.CAR))
        remote.nextTrack(from = ControlSurface.CAR)
        assertEquals(listOf(PlaybackAction.NEXT_CHAPTER), actions)
    }

    /** A tap control from a named surface uses that surface's binding, not the inferred one. */
    @Test
    fun aNamedSurfaceOutranksTheInference() {
        val map = CommandMap()
            .withBinding(PlaybackAction.NEXT_SENTENCE, PlaybackControl.TAP_FORWARD, ControlSurface.PHONE)
            .withBinding(PlaybackAction.SKIP_FORWARD, PlaybackControl.TAP_FORWARD, ControlSurface.CAR)
        val (remote, actions) = router(map)
        remote.activeSurface = ControlSurface.CAR
        // The notification on the phone is the phone, whatever the car is doing.
        remote.skipForward(from = ControlSurface.PHONE)
        // A command with no sender to go by is the car's while it is connected.
        remote.skipForward()
        assertEquals(listOf(PlaybackAction.NEXT_SENTENCE, PlaybackAction.SKIP_FORWARD), actions)
    }

    /**
     * A track button drawn for the car and pressed on the phone's notification
     * does what it does in the car rather than nothing: the phone binds nothing
     * to the wheel, and a lit button that does nothing is the worst outcome.
     */
    @Test
    fun aDrawnTrackButtonIsNeverDead() {
        val (remote, actions) = router()
        remote.activeSurface = ControlSurface.CAR
        assertTrue(checkNotNull(remote.transport).usesTrackCommands)
        remote.nextTrack(from = ControlSurface.PHONE)
        remote.previousTrack(from = ControlSurface.PHONE)
        // The car's shipped wheel: thirty seconds on, fifteen back.
        assertEquals(listOf(PlaybackAction.SKIP_FORWARD, PlaybackAction.SKIP_BACKWARD), actions)
    }

    /** Nothing is answered while nothing is registered, named surface or not. */
    @Test
    fun torndownAnswersNobody() {
        val (remote, actions) = router()
        remote.tearDown()
        remote.skipForward(from = ControlSurface.CAR)
        remote.nextTrack(from = ControlSurface.CAR)
        assertFalse(remote.offersTrackCommands(ControlSurface.CAR))
        assertTrue(actions.isEmpty())
    }

    /** The headphones tab is still reached by inference, as it is on iOS. */
    @Test
    fun headphonesStayInferred() {
        val map = CommandMap().withBinding(PlaybackAction.NEXT_CHAPTER, PlaybackControl.WHEEL_NEXT, ControlSurface.HEADPHONES)
        val (remote, actions) = router(map)
        remote.headphonesRouted = true
        assertTrue(remote.offersTrackCommands())
        remote.nextTrack()
        assertEquals(listOf(PlaybackAction.NEXT_CHAPTER), actions)
    }
}
