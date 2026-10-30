package com.benjaminissa.issareader.app.model

import com.benjaminissa.issareader.app.AppSuite
import com.benjaminissa.issareader.app.ScriptedBackend
import com.benjaminissa.issareader.app.SharedFixtures
import com.benjaminissa.issareader.app.close
import com.benjaminissa.issareader.app.mainTest
import com.benjaminissa.issareader.app.settle
import com.benjaminissa.issareader.app.testScope
import com.benjaminissa.issareader.core.IssaJson
import com.benjaminissa.issareader.core.InMemoryKeyValueStore
import com.benjaminissa.issareader.core.KeyValueStore
import com.benjaminissa.issareader.playback.PlaybackAction
import com.benjaminissa.issareader.playback.PlaybackRate
import com.benjaminissa.issareader.playback.SleepTimer
import com.benjaminissa.issareader.playback.VolumeTrim
import com.benjaminissa.issareader.render.PageTurnStyle
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs
import kotlin.math.log10

/**
 * Configuring the Now Playing controller more than once. Ported from
 * `NowPlayingConfigureTests.swift`: `remoteActivations` counts the
 * re-registrations, which is the finding's own unit.
 */
class NowPlayingConfigureTest : AppSuite() {
    /** Configuring with the same settings again does nothing. */
    @Test
    fun repeatedConfigureIsIdempotent() = mainTest {
        val scope = testScope()
        val controller = NowPlayingController(scope)
        val settings = PlaybackSettings(InMemoryKeyValueStore(), SignOutCentre())

        controller.configure(settings)
        controller.configure(settings)
        controller.configure(settings)

        assertEquals("each screen re-registered the whole command set", 1, controller.remoteActivations)
        scope.close()
    }

    /** One settings change produces one re-registration. */
    @Test
    fun oneChangeOneActivation() = mainTest {
        val scope = testScope()
        val controller = NowPlayingController(scope)
        val settings = PlaybackSettings(InMemoryKeyValueStore(), SignOutCentre())
        repeat(5) { controller.configure(settings) }
        val before = controller.remoteActivations

        settings.commandMap = settings.commandMap.copy(skipForwardInterval = 45.0)
        settle()

        assertEquals("${controller.remoteActivations - before} cycles for one change", before + 1, controller.remoteActivations)
        scope.close()
    }

    /** The previous settings object stops being observed. */
    @Test
    fun supersededObservationStops() = mainTest {
        val scope = testScope()
        val controller = NowPlayingController(scope)
        val first = PlaybackSettings(InMemoryKeyValueStore(), SignOutCentre())
        val second = PlaybackSettings(InMemoryKeyValueStore(), SignOutCentre())

        controller.configure(first)
        controller.configure(second)
        assertEquals("a different object is a real reconfiguration", 2, controller.remoteActivations)

        val before = controller.remoteActivations
        first.commandMap = first.commandMap.copy(skipForwardInterval = 45.0)
        settle()

        assertEquals("the superseded settings object was still driving the media session", before, controller.remoteActivations)
        scope.close()
    }
}

/**
 * The sleep timer gives the audio route back. Ported from
 * `NowPlayingSessionEndTests.swift`; the route is the scripted engine's
 * session, which `AudioPlayer.endSession` deactivates.
 */
class NowPlayingSessionEndTest : AppSuite() {
    /** A sleep timer that expires ends the session; a pause does not. */
    @Test
    fun anExpiredTimerEndsTheSession() = mainTest {
        val scope = testScope()
        val controller = NowPlayingController(scope)
        val backend = ScriptedBackend()
        val engine = NowPlayingAttachTest.engine(scope, backend = backend)
        controller.attach(engine, SharedFixtures.book("Dracula", uuid = "sleep-uuid"))
        try {
            engine.player.play()
            engine.player.pause()
            engine.player.play()
            assertEquals("a pause keeps the route", 0, backend.sessionsDeactivated)

            checkNotNull(controller.sleepTimer).start(SleepTimer.Mode.EndOfChapter)
            engine.onChapterChangeObserved?.invoke()

            assertFalse(engine.player.isPlaying)
            assertEquals("the timer stopped the book and kept the route", 1, backend.sessionsDeactivated)
        } finally {
            controller.attach(null, null)
            scope.close()
        }
    }
}

/**
 * The Page turn choice: Slide unless the reader picked otherwise, kept across
 * launches, and costing the open book nothing when it changes. Ported from
 * `PageTurnSettingTests.swift`.
 */
class PageTurnSettingTest : AppSuite() {
    /** A reader who never chose gets Slide, and nothing is stored for them. */
    @Test
    fun slideByDefault() {
        val defaults = InMemoryKeyValueStore()
        assertEquals(PageTurnStyle.SLIDE, PlaybackSettings(defaults, SignOutCentre()).pageTurn)
        assertNull(defaults.getString("issa.pageTurn"))
    }

    /** A stored value this build cannot read is Slide too. */
    @Test
    fun unknownIsSlide() {
        val defaults = InMemoryKeyValueStore()
        defaults.putString("issa.pageTurn", "curl")
        assertEquals(PageTurnStyle.SLIDE, PlaybackSettings(defaults, SignOutCentre()).pageTurn)
    }

    /** The choice is the choice a relaunch restores. */
    @Test
    fun persists() {
        for (style in PageTurnStyle.entries) {
            val defaults = InMemoryKeyValueStore()
            val settings = PlaybackSettings(defaults, SignOutCentre())
            settings.pageTurn = style
            assertEquals(style, PlaybackSettings(defaults, SignOutCentre()).pageTurn)
        }
    }

    /** Changing it leaves the reading style alone: a change there re-paginates the open book. */
    @Test
    fun notAStyle() {
        val defaults = InMemoryKeyValueStore()
        val settings = PlaybackSettings(defaults, SignOutCentre())
        val style = settings.readerStyle
        settings.pageTurn = PageTurnStyle.COVER
        assertEquals(style, settings.readerStyle)
        assertEquals(style, PlaybackSettings(defaults, SignOutCentre()).readerStyle)
    }
}

/**
 * The "Show book title" choice: on unless the reader turned it off, kept
 * across launches, and costing the open book nothing when it changes. Ported
 * from `BookTitleSettingTests.swift`.
 */
class BookTitleSettingTest : AppSuite() {
    /** A reader who never chose sees the title, and nothing is stored for them. */
    @Test
    fun onByDefault() {
        val defaults = InMemoryKeyValueStore()
        assertTrue(PlaybackSettings(defaults, SignOutCentre()).showsBookTitle)
        assertNull(defaults.getBooleanOrNull("issa.showBookTitle"))
    }

    /** The choice is the choice a relaunch restores, off included. */
    @Test
    fun persists() {
        for (shown in listOf(true, false)) {
            val defaults = InMemoryKeyValueStore()
            PlaybackSettings(defaults, SignOutCentre()).showsBookTitle = shown
            assertEquals(shown, defaults.getBooleanOrNull("issa.showBookTitle"))
            assertEquals(shown, PlaybackSettings(defaults, SignOutCentre()).showsBookTitle)
        }
    }

    /** Changing it leaves the reading style alone: a change there re-paginates the open book. */
    @Test
    fun notAStyle() {
        val defaults = InMemoryKeyValueStore()
        val settings = PlaybackSettings(defaults, SignOutCentre())
        val style = settings.readerStyle
        settings.showsBookTitle = false
        assertEquals(style, settings.readerStyle)
        assertEquals(style, PlaybackSettings(defaults, SignOutCentre()).readerStyle)
    }
}

/**
 * The rate the reader sees and the rate on disk are the same rate. Ported
 * from `PlaybackRatePersistenceTests.swift`.
 */
class PlaybackRatePersistenceTest : AppSuite() {
    /** A rate clamped on the way in is the rate a relaunch restores. */
    @Test
    fun clampedRateIsPersisted() {
        val defaults = InMemoryKeyValueStore()
        val settings = PlaybackSettings(defaults, SignOutCentre())
        settings.playbackRate = 9.0
        assertEquals("the clamp itself", PlaybackRate.maximum, settings.playbackRate, 0.0)

        val relaunched = PlaybackSettings(defaults, SignOutCentre())
        assertEquals(
            "the live rate was ${settings.playbackRate} but ${relaunched.playbackRate} was stored",
            PlaybackRate.maximum, relaunched.playbackRate, 0.0,
        )
    }

    /** A speed chosen from a bound control is the speed a relaunch restores. */
    @Test
    fun boundSpeedControlIsPersisted() = mainTest {
        val scope = testScope()
        val defaults = InMemoryKeyValueStore()
        val settings = PlaybackSettings(defaults, SignOutCentre())
        val controller = NowPlayingController(scope)
        controller.configure(settings)
        val engine = NowPlayingAttachTest.engine(scope)
        engine.player.rate = settings.playbackRate.toFloat()
        controller.attach(engine, SharedFixtures.book("Dracula", uuid = "rate-uuid"))

        engine.perform(PlaybackAction.SPEED_UP, settings.commandMap)

        assertEquals(1.25f, engine.player.rate)
        assertEquals("the setting never heard of it", 1.0 + PlaybackRate.STEP, settings.playbackRate, 0.0)
        assertEquals("and a relaunch went back to 1×", 1.25, PlaybackSettings(defaults, SignOutCentre()).playbackRate, 0.0)
        controller.attach(null, null)
        scope.close()
    }

    /** A legal rate is persisted as itself. */
    @Test
    fun legalRateIsPersisted() {
        val defaults = InMemoryKeyValueStore()
        PlaybackSettings(defaults, SignOutCentre()).playbackRate = 1.5
        assertEquals(1.5, PlaybackSettings(defaults, SignOutCentre()).playbackRate, 0.0)
    }
}

/**
 * What the reader hears next launch, and what an account leaves behind.
 * Ported from `VolumeTrimPersistenceTests.swift`.
 */
class VolumeTrimPersistenceTest : AppSuite() {
    /** The key builds up to 1.1.0 (32) wrote percentages under, spelled out because what is on disk is the point. */
    private val legacyKey = "issa.bookVolumes"
    private val decibelKey = "issa.bookVolumeDecibels"
    private val serializer = MapSerializer(String.serializer(), Int.serializer())

    private fun write(trims: Map<String, Int>, key: String, defaults: KeyValueStore) =
        defaults.putString(key, IssaJson.encodeToString(serializer, trims))

    private fun read(key: String, defaults: KeyValueStore): Map<String, Int>? =
        defaults.getString(key)?.let { IssaJson.decodeFromString(serializer, it) }

    private fun settings(defaults: KeyValueStore, centre: SignOutCentre = SignOutCentre()) = PlaybackSettings(defaults, centre)

    /** A trim survives the relaunch that reads it back. */
    @Test
    fun trimRoundTrips() {
        val defaults = InMemoryKeyValueStore()
        val settings = settings(defaults)
        settings.setVolumeTrim(-3, "book-a")
        settings.setVolumeTrim(5, "book-b")

        val relaunched = settings(defaults)
        assertEquals(-3, relaunched.volumeTrim("book-a"))
        assertEquals(5, relaunched.volumeTrim("book-b"))
        assertEquals(0, relaunched.volumeTrim("never-touched"))
    }

    /** A trim off the end of the range is clamped before it is stored. */
    @Test
    fun snappedOnTheWayIn() {
        val defaults = InMemoryKeyValueStore()
        val settings = settings(defaults)
        settings.setVolumeTrim(12, "book")
        assertEquals(8, settings.volumeTrim("book"))
        settings.setVolumeTrim(-12, "book")
        assertEquals(-8, settings.volumeTrim("book"))
        settings.setVolumeTrim(3, "book")
        assertEquals(3, settings.volumeTrim("book"))
        assertEquals("the live value was clamped but the stored one was not", 3, settings(defaults).volumeTrim("book"))
    }

    /** Returning a book to the recorded level removes it rather than storing a zero. */
    @Test
    fun zeroRemovesTheKey() {
        val defaults = InMemoryKeyValueStore()
        val settings = settings(defaults)
        settings.setVolumeTrim(2, "book")
        assertEquals(2, settings.bookVolumeTrims["book"])

        settings.setVolumeTrim(0, "book")
        assertNull("a zero is not a preference", settings.bookVolumeTrims["book"])
        assertTrue(settings.bookVolumeTrims.isEmpty())
        assertTrue(settings(defaults).bookVolumeTrims.isEmpty())
    }

    /** Signing out clears the live dictionary, not only the stored one. */
    @Test
    fun signOutClearsTheTrims() {
        val defaults = InMemoryKeyValueStore()
        write(mapOf("book" to -30), legacyKey, defaults)
        // A centre of this test's own, so the sign-out reaches no other suite.
        val centre = SignOutCentre()
        val settings = settings(defaults, centre)
        settings.setVolumeTrim(-2, "book")
        assertFalse(settings.bookVolumeTrims.isEmpty())

        centre.post(emptySet())

        assertTrue("the next account inherits this book's level", settings.bookVolumeTrims.isEmpty())
        assertTrue(settings(defaults).bookVolumeTrims.isEmpty())
        // And the percentages a shipped build would still read.
        assertNull(read(legacyKey, defaults))
    }

    /** A book keeps the level it was already playing at, through the upgrade off percentages. */
    @Test
    fun migrationKeepsTheLevel() {
        val defaults = InMemoryKeyValueStore()
        val percentages = mapOf("a" to -50, "b" to -30, "c" to -25, "d" to 30, "e" to 50, "f" to 5)
        write(percentages, legacyKey, defaults)

        val settings = settings(defaults)
        for ((book, percent) in percentages) {
            val wasPlayingAt = 1 + percent.toFloat() / 100
            val nowPlaysAt = VolumeTrim.gain(settings.volumeTrim(book))
            val shift = abs(20 * log10(nowPlaysAt / wasPlayingAt))
            assertTrue("$book was at $percent% and moved by $shift dB", shift < 0.5)
        }
        // +5% is 0.42 dB, which rounds to the recorded level.
        assertEquals(0, settings.volumeTrim("f"))
        assertNull(settings.bookVolumeTrims["f"])
    }

    /** The upgrade runs once and leaves the old levels where they are. */
    @Test
    fun migrationRunsOnce() {
        val defaults = InMemoryKeyValueStore()
        write(mapOf("book" to -50), legacyKey, defaults)

        val first = settings(defaults)
        assertEquals(-6, first.volumeTrim("book"))
        assertEquals("the converted levels were not written down", mapOf("book" to -6), read(decibelKey, defaults))
        assertEquals("a downgrade would find nothing to read", mapOf("book" to -50), read(legacyKey, defaults))

        first.setVolumeTrim(2, "book")
        val second = settings(defaults)
        assertEquals(2, second.volumeTrim("book"))
        assertEquals("the old key is read, never written", mapOf("book" to -50), read(legacyKey, defaults))

        second.setVolumeTrim(0, "book")
        assertTrue(settings(defaults).bookVolumeTrims.isEmpty())
    }

    /** With no old levels the upgrade writes nothing. */
    @Test
    fun migrationSkippedWithoutLegacyLevels() {
        val defaults = InMemoryKeyValueStore()
        val settings = settings(defaults)
        assertTrue(settings.bookVolumeTrims.isEmpty())
        assertNull("a reader with nothing stored got a key full of nothing", read(decibelKey, defaults))
        assertNull(read(legacyKey, defaults))
    }

    /** A stored level the slider cannot draw is clamped on the way out of defaults. */
    @Test
    fun storedLevelsAreSanitised() {
        val defaults = InMemoryKeyValueStore()
        write(mapOf("loud" to 40, "quiet" to -40, "none" to 0), decibelKey, defaults)

        val settings = settings(defaults)
        assertEquals(8, settings.volumeTrim("loud"))
        assertEquals(-8, settings.volumeTrim("quiet"))
        assertNull("a zero is not a preference", settings.bookVolumeTrims["none"])
    }
}

/**
 * Telling a reader their book cannot be made louder. Ported from
 * `VolumeTrimReachTests.swift`.
 */
class VolumeTrimReachTest : AppSuite() {
    /** Only a player that has answered no says no. */
    @Test
    fun canBeLouder() {
        for ((carriesGain, expected) in listOf(null to true, true to true, false to false)) {
            assertEquals(expected, VolumeTrimReach.canBeLouder(carriesGain))
        }
    }

    /** The caption appears for that one state and no other. */
    @Test
    fun captionOnlyWhereItIsTrue() {
        assertNull(VolumeTrimReach.caption(null))
        assertNull(VolumeTrimReach.caption(true))
        val caption = VolumeTrimReach.caption(false)
        assertNotNull(caption)
        assertTrue(caption!!.contains("quieter"))
    }

    /** The spoken value warns above as-recorded and stays quiet at or below it. */
    @Test
    fun spokenValue() {
        assertEquals("3 decibels louder", VolumeTrimReach.spoken(3, true))
        assertEquals("3 decibels louder", VolumeTrimReach.spoken(3, null))
        assertEquals("3 decibels louder, but this book can only be made quieter", VolumeTrimReach.spoken(3, false))
        assertEquals("1 decibel louder, but this book can only be made quieter", VolumeTrimReach.spoken(1, false))
        assertEquals("as recorded", VolumeTrimReach.spoken(0, false))
        assertEquals("6 decibels quieter", VolumeTrimReach.spoken(-6, false))
        assertEquals("8 decibels louder, but this book can only be made quieter", VolumeTrimReach.spoken(Int.MAX_VALUE, false))
        assertEquals("8 decibels quieter", VolumeTrimReach.spoken(Int.MIN_VALUE, false))
    }

    /** The warning is on exactly the rungs that cannot be heard. */
    @Test
    fun everyRung() {
        for (level in VolumeTrim.ladder) {
            val spoken = VolumeTrimReach.spoken(level, false)
            val warns = spoken.contains("can only be made quieter")
            assertEquals("$level dB spoke as $spoken", level > 0, warns)
            assertEquals(VolumeTrim.spoken(level), VolumeTrimReach.spoken(level, true))
        }
    }
}
