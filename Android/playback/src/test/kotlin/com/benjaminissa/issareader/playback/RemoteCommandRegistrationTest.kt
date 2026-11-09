package com.benjaminissa.issareader.playback

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

// Ported from `PlaybackTests.swift` (`RemoteCommandRegistrationTests`), against
// the transport `CommandRouter` tells the media session to offer, where the
// Swift suite read `MPRemoteCommandCenter.shared()` back.

/**
 * Which transport the system draws.
 *
 * This is the part the map alone cannot see: the system shows `⏮ ⏭` and hides
 * the interval skips whenever next/previous **track** are offered, and shows
 * `⏪15` / `⏩30` when they are not. Offering the track pair unconditionally is
 * what made every remote control on the phone jump a whole chapter and made the
 * lock screen advertise that as all it could do.
 */
class RemoteCommandRegistrationTest {
    /** By default the system draws the skip buttons, not the track buttons. */
    @Test
    fun defaultsDrawSkipButtons() {
        val remote = CommandRouter()
        remote.activate()
        val transport = checkNotNull(remote.transport)

        assertFalse(transport.usesTrackCommands)
        // …while the skips carry the intervals they claim.
        assertEquals(30.0, transport.skipForwardInterval, 0.0)
        assertEquals(15.0, transport.skipBackwardInterval, 0.0)
        assertEquals(PlaybackRate.ladder, transport.supportedRates)
    }

    /** Binding the wheel brings the track buttons back. */
    @Test
    fun bindingTheWheelEnablesTrackCommands() {
        val map = CommandMap().withBinding(PlaybackAction.NEXT_CHAPTER, PlaybackControl.WHEEL_NEXT, ControlSurface.PHONE)
        val remote = CommandRouter(map)
        remote.activate()

        assertTrue(checkNotNull(remote.transport).usesTrackCommands)
    }

    /** Connecting to a car re-registers against the car's own bindings. */
    @Test
    fun surfaceChangeReregisters() {
        val remote = CommandRouter()
        val published = ArrayList<CommandRouter.Transport?>()
        remote.onTransportChange = { published.add(it) }
        remote.activate()
        // Nothing is bound to the wheel on the phone…
        assertFalse(checkNotNull(remote.transport).usesTrackCommands)

        // …but the car binds it, so its buttons come into being on connect.
        remote.activeSurface = ControlSurface.CAR
        assertTrue(checkNotNull(remote.transport).usesTrackCommands)

        // And go away again on disconnect, which is why assigning the surface
        // re-registers rather than merely being read at fire time.
        remote.activeSurface = ControlSurface.PHONE
        assertFalse(checkNotNull(remote.transport).usesTrackCommands)
        assertEquals(listOf(false, true, false), published.filterNotNull().map { it.usesTrackCommands })
    }

    /** A changed interval reaches the buttons the system draws. */
    @Test
    fun intervalChangeReachesTheSystem() {
        val map = CommandMap().copy(skipBackwardInterval = 10.0, skipForwardInterval = 45.0)
        val remote = CommandRouter(map)
        remote.activate()

        assertEquals(10.0, checkNotNull(remote.transport).skipBackwardInterval, 0.0)
        assertEquals(45.0, checkNotNull(remote.transport).skipForwardInterval, 0.0)
    }

    // Android's own: the media session's entry points.

    /**
     * The wheel's commands only reach a binding while they are offered, and a
     * torn-down router answers nothing — a command arriving after it would
     * otherwise tell the system it was handled while nothing happens.
     */
    @Test
    fun commandsAreAnsweredOnlyWhileOffered() {
        val actions = ArrayList<PlaybackAction>()
        val remote = CommandRouter()
        remote.onAction = { actions.add(it) }

        remote.skipForward()
        assertTrue("nothing is registered before activate()", actions.isEmpty())

        remote.activate()
        remote.skipForward()
        remote.skipBackward()
        remote.nextTrack()
        remote.play()
        remote.pause()
        remote.togglePlayPause()
        assertEquals(
            "the wheel is not offered on the phone, so its command is not answered",
            listOf(
                PlaybackAction.SKIP_FORWARD, PlaybackAction.SKIP_BACKWARD,
                PlaybackAction.PLAY, PlaybackAction.PAUSE, PlaybackAction.PLAY_PAUSE,
            ),
            actions,
        )

        remote.activeSurface = ControlSurface.CAR
        actions.clear()
        remote.nextTrack()
        remote.previousTrack()
        assertEquals(listOf(PlaybackAction.SKIP_FORWARD, PlaybackAction.SKIP_BACKWARD), actions)

        remote.tearDown()
        assertNull(remote.transport)
        actions.clear()
        remote.play()
        remote.nextTrack()
        assertTrue(actions.isEmpty())
    }

    /** A headphone-class route moves the wheel to the headphones tab, and re-registers. */
    @Test
    fun aHeadphoneRouteReregisters() {
        val map = CommandMap().withBinding(PlaybackAction.NEXT_SENTENCE, PlaybackControl.WHEEL_NEXT, ControlSurface.HEADPHONES)
        val remote = CommandRouter(map)
        val actions = ArrayList<PlaybackAction>()
        remote.onAction = { actions.add(it) }
        remote.activate()
        assertFalse(checkNotNull(remote.transport).usesTrackCommands)

        remote.headphonesRouted = true
        assertTrue("the headphones bind the wheel", checkNotNull(remote.transport).usesTrackCommands)
        remote.nextTrack()
        assertEquals(listOf(PlaybackAction.NEXT_SENTENCE), actions)

        remote.headphonesRouted = false
        assertFalse(checkNotNull(remote.transport).usesTrackCommands)
    }

    /** What the now-playing entry says: the book, its byline, and the chapter. */
    @Test
    fun nowPlayingFields() {
        val info = CommandRouter.nowPlaying(
            title = "Peter and Wendy", author = "J. M. Barrie", chapter = "The Flight",
            elapsed = 600.0, duration = 1_800.0, rate = 1.5f,
        )
        assertEquals("Peter and Wendy", info.title)
        assertEquals("J. M. Barrie", info.artist)
        assertEquals("The Flight", info.album)
        assertEquals(600.0, info.elapsed, 0.0)
        assertEquals(1_800.0, info.duration, 0.0)
        assertEquals(1.5f, info.rate)
        assertEquals(1f, info.defaultRate)
        assertTrue(info.isPlaying)
        assertFalse(info.copy(rate = 0f).isPlaying)
    }
}
