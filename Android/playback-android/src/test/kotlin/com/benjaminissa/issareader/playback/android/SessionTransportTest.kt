package com.benjaminissa.issareader.playback.android

import android.content.Context
import android.os.Bundle
import androidx.car.app.connection.CarConnection
import androidx.media3.common.Player
import androidx.media3.session.CommandButton
import androidx.media3.session.MediaSession
import org.robolectric.RuntimeEnvironment
import com.benjaminissa.issareader.playback.CommandMap
import com.benjaminissa.issareader.playback.CommandRouter
import com.benjaminissa.issareader.playback.ControlSurface
import com.google.common.util.concurrent.Futures
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Which buttons the system draws, and who is asking: `RemoteCommandCenter`'s
 * registration, as Media3 commands and buttons.
 */
@RunWith(RobolectricTestRunner::class)
class SessionTransportTest {
    private fun transport(map: CommandMap = CommandMap(), surface: ControlSurface = ControlSurface.PHONE): CommandRouter.Transport {
        val router = CommandRouter(map)
        router.activate()
        router.activeSurface = surface
        return checkNotNull(router.transport)
    }

    /** On the phone: `⏪15`, `⏩30` in the back and forward slots, the speed in the overflow. */
    @Test
    fun thePhoneDrawsTheSkips() {
        val buttons = SessionTransport.buttons(transport(), rate = 1.0)
        assertEquals(3, buttons.size)
        val (back, forward, rate) = buttons
        assertEquals(Player.COMMAND_SEEK_BACK, back.playerCommand)
        assertEquals(CommandButton.ICON_SKIP_BACK_15, back.icon)
        assertEquals(listOf(CommandButton.SLOT_BACK), back.slots.asList())
        assertEquals(Player.COMMAND_SEEK_FORWARD, forward.playerCommand)
        assertEquals(CommandButton.ICON_SKIP_FORWARD_30, forward.icon)
        assertEquals(listOf(CommandButton.SLOT_FORWARD), forward.slots.asList())
        assertEquals(SessionTransport.CYCLE_RATE, rate.sessionCommand?.customAction)
        assertEquals(CommandButton.ICON_PLAYBACK_SPEED, rate.icon)
        assertEquals("Speed 1×", rate.displayName.toString())
        // No track pair offered, so the system draws these rather than ⏮ ⏭.
        val commands = SessionTransport.playerCommands(usesTrackCommands = false)
        assertFalse(commands.contains(Player.COMMAND_SEEK_TO_NEXT))
        assertFalse(commands.contains(Player.COMMAND_SEEK_TO_PREVIOUS))
        assertTrue(commands.contains(Player.COMMAND_SEEK_FORWARD))
    }

    /** In the car the wheel is bound, so `⏮ ⏭` are drawn and the skips are not. */
    @Test
    fun theCarDrawsTheTrackPair() {
        val car = transport(surface = ControlSurface.CAR)
        assertTrue(car.usesTrackCommands)
        val buttons = SessionTransport.buttons(car, rate = 1.25)
        assertEquals(listOf(SessionTransport.CYCLE_RATE), buttons.map { it.sessionCommand?.customAction })
        assertEquals("Speed 1.25×", buttons.single().displayName.toString())
        val commands = SessionTransport.playerCommands(usesTrackCommands = true)
        assertTrue(commands.contains(Player.COMMAND_SEEK_TO_NEXT))
        assertTrue(commands.contains(Player.COMMAND_SEEK_TO_PREVIOUS))
    }

    /** A numbered glyph only where it names the interval: a button that lies is worse than a plain one. */
    @Test
    fun skipGlyphs() {
        assertEquals(CommandButton.ICON_SKIP_BACK_5, SessionTransport.skipBackIcon(5.0))
        assertEquals(CommandButton.ICON_SKIP_BACK_10, SessionTransport.skipBackIcon(10.0))
        assertEquals(CommandButton.ICON_SKIP_BACK_30, SessionTransport.skipBackIcon(30.0))
        assertEquals(CommandButton.ICON_SKIP_BACK, SessionTransport.skipBackIcon(20.0))
        assertEquals(CommandButton.ICON_SKIP_FORWARD_15, SessionTransport.skipForwardIcon(15.0))
        assertEquals(CommandButton.ICON_SKIP_FORWARD, SessionTransport.skipForwardIcon(45.0))
        val custom = SessionTransport.buttons(transport(CommandMap(skipForwardInterval = 45.0, skipBackwardInterval = 20.0)), 1.0)
        assertEquals("Back 20 seconds", custom[0].displayName.toString())
        assertEquals("Forward 45 seconds", custom[1].displayName.toString())
    }

    /** CarPlay's rate button: 1 → 1.25 → 1.5 → 1.75 → 2 → 1, and anything else to the next one up. */
    @Test
    fun theRateCycle() {
        var rate = 1.0
        val seen = mutableListOf<Double>()
        repeat(6) {
            rate = SessionTransport.nextCarRate(rate)
            seen += rate
        }
        assertEquals(listOf(1.25, 1.5, 1.75, 2.0, 1.0, 1.25), seen)
        assertEquals(1.0, SessionTransport.nextCarRate(2.5), 0.0)
        assertEquals(1.0, SessionTransport.nextCarRate(0.75), 0.0)
        assertEquals("1.5×", SessionTransport.rateLabel(1.5))
        assertEquals("2×", SessionTransport.rateLabel(2.0))
        assertEquals("1.75×", SessionTransport.rateLabel(1.75))
    }

    /** The rate button's command is on offer to every controller. */
    @Test
    fun theRateCommandIsOffered() {
        assertTrue(SessionTransport.sessionCommands().contains(SessionTransport.cycleRate))
    }

    // Who is asking

    /** Android Auto is the car, the notification and the app the phone, anything else inferred. */
    @Test
    fun controllersAreSurfaces() {
        val context: Context = RuntimeEnvironment.getApplication()
        val player = IssaSessionPlayer(
            CommandRouter(),
            object : IssaSessionPlayer.Delegate {
                override fun requestSurface(): ControlSurface? = null
                override fun setMediaItems(items: List<androidx.media3.common.MediaItem>, startIndex: Int, startPositionMs: Long) =
                    Futures.immediateVoidFuture()
                override fun playChapter(index: Int) = Futures.immediateVoidFuture()
            },
        )
        val session = MediaSession.Builder(context, player).setId("surfaces").build()
        try {
            fun controller(pkg: String, version: Int = 1_000_000, hints: Bundle = Bundle.EMPTY) =
                MediaSession.ControllerInfo.createTestOnlyControllerInfo(pkg, 0, 0, version, 1, false, hints, true)
            val own = context.packageName
            assertEquals(ControlSurface.CAR, ControllerSurfaces.surface(session, controller("com.google.android.projection.gearhead", version = 0), own))
            assertEquals(ControlSurface.CAR, ControllerSurfaces.surface(session, controller("com.android.car.media"), own))
            val notification = controller(own, hints = Bundle().apply { putBoolean("androidx.media3.session.MediaNotificationManager", true) })
            assertTrue(session.isMediaNotificationController(notification))
            assertEquals(ControlSurface.PHONE, ControllerSurfaces.surface(session, notification, own))
            assertEquals(ControlSurface.PHONE, ControllerSurfaces.surface(session, controller(own), own))
            assertEquals(ControlSurface.PHONE, ControllerSurfaces.surface(session, controller(ControllerSurfaces.SYSTEM_UI_PACKAGE, version = 0), own))
            assertNull(ControllerSurfaces.surface(session, controller("com.android.bluetooth", version = 0), own))
            assertNull(ControllerSurfaces.surface(session, controller("com.google.android.googlequicksearchbox"), own))
            assertNull(ControllerSurfaces.surface(session, null, own))
        } finally {
            session.release()
            player.release()
        }
    }

    // Whether a car is connected

    @Test
    fun carConnectionIsAuthoritativeOnceHeard() {
        val changes = mutableListOf<Boolean>()
        val presence = CarPresence { changes += it }
        // Android Auto's controller arrives before the car library has answered.
        presence.carControllerConnected("gearhead")
        assertTrue(presence.isConnected)
        presence.connectionTypeChanged(CarConnection.CONNECTION_TYPE_PROJECTION)
        // The drive ends; the controller lingers, and is not believed.
        presence.connectionTypeChanged(CarConnection.CONNECTION_TYPE_NOT_CONNECTED)
        assertFalse(presence.isConnected)
        presence.carControllerDisconnected("gearhead")
        assertEquals(listOf(true, false), changes)
    }

    /** An Android Auto that never answers the car library is still a car, by its controller. */
    @Test
    fun theControllerIsTheFallback() {
        val changes = mutableListOf<Boolean>()
        val presence = CarPresence { changes += it }
        presence.connectionTypeChanged(CarConnection.CONNECTION_TYPE_NOT_CONNECTED)
        presence.carControllerConnected("browser")
        presence.carControllerConnected("transport")
        presence.carControllerDisconnected("browser")
        assertTrue(presence.isConnected)
        presence.carControllerDisconnected("transport")
        assertEquals(listOf(true, false), changes)
    }
}
