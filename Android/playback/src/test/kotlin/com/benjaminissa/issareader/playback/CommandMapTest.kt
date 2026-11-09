package com.benjaminissa.issareader.playback

import com.benjaminissa.issareader.core.IssaJson
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

// Ported from `PlaybackTests.swift` (`CommandMapTests`).

/**
 * What a button does when nobody has said otherwise.
 *
 * The rule these encode is blunt on purpose: **no default on any surface moves
 * a whole chapter.** A chapter is tens of minutes, and a control that jumps one
 * unasked — on a lock screen, on headphones, on a steering wheel — loses a
 * listener's place outright. Chapter stays one pick away in Settings.
 */
class CommandMapTest {
    private fun encode(map: CommandMap): String = IssaJson.encodeToString(CommandMap.serializer(), map)

    private fun decode(json: String): CommandMap = IssaJson.decodeFromString(CommandMap.serializer(), json)

    /** No default on any surface moves a whole chapter. */
    @Test
    fun noChapterDefaults() {
        // Asserted as a property rather than as a list of expected values,
        // because a list is exactly what the next edit to the table outgrows
        // without anybody noticing.
        assertFalse(CommandMap.defaultsIncludeAChapterJump)
    }

    /** Forward and back are time skips, and the intervals are 15 back / 30 forward. */
    @Test
    fun skipDefaults() {
        val map = CommandMap()
        assertEquals(PlaybackAction.SKIP_FORWARD, map.action(PlaybackControl.TAP_FORWARD, ControlSurface.PHONE))
        assertEquals(PlaybackAction.SKIP_BACKWARD, map.action(PlaybackControl.TAP_BACKWARD, ControlSurface.PHONE))
        assertEquals(PlaybackAction.SKIP_FORWARD, map.action(PlaybackControl.TAP_FORWARD, ControlSurface.CAR))
        assertEquals(PlaybackAction.SKIP_BACKWARD, map.action(PlaybackControl.TAP_BACKWARD, ControlSurface.CAR))
        assertEquals(
            PlaybackAction.SKIP_FORWARD,
            map.action(PlaybackControl.DOUBLE_TAP_FORWARD, ControlSurface.HEADPHONES),
        )
        assertEquals(
            PlaybackAction.SKIP_BACKWARD,
            map.action(PlaybackControl.DOUBLE_TAP_BACKWARD, ControlSurface.HEADPHONES),
        )
        assertEquals(30.0, map.skipForwardInterval, 0.0)
        assertEquals(15.0, map.skipBackwardInterval, 0.0)
    }

    /** Hold moves by paragraph, which is a unit and not a chapter. */
    @Test
    fun holdDefaults() {
        val map = CommandMap()
        assertEquals(PlaybackAction.NEXT_PARAGRAPH, map.action(PlaybackControl.HOLD_FORWARD, ControlSurface.PHONE))
        assertEquals(PlaybackAction.PREVIOUS_PARAGRAPH, map.action(PlaybackControl.HOLD_BACKWARD, ControlSurface.PHONE))
    }

    /** The phone leaves the track buttons alone so the lock screen draws the skips. */
    @Test
    fun phoneDoesNotClaimTrackCommands() {
        val map = CommandMap()
        // The whole point: with nothing bound to the wheel, the system has no
        // track command to draw and falls back to the interval skips.
        assertFalse(map.usesTrackCommands(ControlSurface.PHONE))
        assertFalse(map.usesTrackCommands(ControlSurface.HEADPHONES))
    }

    /** The car binds the wheel, because an unbound wheel is a dead button at speed. */
    @Test
    fun carClaimsTrackCommands() {
        val map = CommandMap()
        assertTrue(map.usesTrackCommands(ControlSurface.CAR))
        assertEquals(PlaybackAction.SKIP_FORWARD, map.action(PlaybackControl.WHEEL_NEXT, ControlSurface.CAR))
        assertEquals(PlaybackAction.SKIP_BACKWARD, map.action(PlaybackControl.WHEEL_PREVIOUS, ControlSurface.CAR))
    }

    /** Binding the wheel brings the track commands back. */
    @Test
    fun bindingTheWheelReenablesTrackCommands() {
        var map = CommandMap()
        assertFalse(map.usesTrackCommands(ControlSurface.PHONE))
        map = map.withBinding(PlaybackAction.NEXT_CHAPTER, PlaybackControl.WHEEL_NEXT, ControlSurface.PHONE)
        assertTrue(map.usesTrackCommands(ControlSurface.PHONE))
        // And unbinding takes them away again.
        map = map.withBinding(PlaybackAction.NONE, PlaybackControl.WHEEL_NEXT, ControlSurface.PHONE)
        assertFalse(map.usesTrackCommands(ControlSurface.PHONE))
    }

    /** Rebinding one surface leaves the others alone. */
    @Test
    fun rebinding() {
        val map = CommandMap().withBinding(PlaybackAction.NEXT_CHAPTER, PlaybackControl.WHEEL_NEXT, ControlSurface.CAR)
        assertEquals(PlaybackAction.NEXT_CHAPTER, map.action(PlaybackControl.WHEEL_NEXT, ControlSurface.CAR))
        assertEquals(PlaybackAction.NONE, map.action(PlaybackControl.WHEEL_NEXT, ControlSurface.PHONE))
        assertEquals(PlaybackAction.SKIP_FORWARD, map.action(PlaybackControl.TAP_FORWARD, ControlSurface.CAR))
    }

    /** An unbound control does nothing rather than falling back. */
    @Test
    fun unbound() {
        var map = CommandMap(bindings = emptyMap())
        assertEquals(PlaybackAction.NONE, map.action(PlaybackControl.TAP_FORWARD, ControlSurface.PHONE))
        map = map.withBinding(PlaybackAction.PLAY_PAUSE, PlaybackControl.TAP_FORWARD, ControlSurface.PHONE)
        assertEquals(PlaybackAction.PLAY_PAUSE, map.action(PlaybackControl.TAP_FORWARD, ControlSurface.PHONE))
    }

    /** The Controls picker offers only actions something actually performs. */
    @Test
    fun assignableActions() {
        // `SLEEP_TIMER` was bindable while neither coordinator performed it: a
        // dead steering-wheel button, configured in good faith.
        assertFalse(PlaybackAction.SLEEP_TIMER in PlaybackAction.assignable)
        // The discrete pair exists for the system's own play/pause commands; a
        // button already has the toggle.
        assertFalse(PlaybackAction.PLAY in PlaybackAction.assignable)
        assertFalse(PlaybackAction.PAUSE in PlaybackAction.assignable)
        // Unbinding must stay possible, and the everyday actions must remain.
        assertTrue(PlaybackAction.NONE in PlaybackAction.assignable)
        assertTrue(PlaybackAction.PLAY_PAUSE in PlaybackAction.assignable)
        assertTrue(PlaybackAction.NEXT_CHAPTER in PlaybackAction.assignable)
    }

    /** Survives a round trip through the serializer, so settings persist. */
    @Test
    fun codable() {
        val map = CommandMap()
            .withBinding(PlaybackAction.SLEEP_TIMER, PlaybackControl.HOLD_BACKWARD, ControlSurface.HEADPHONES)
            .copy(skipForwardInterval = 45.0)
        val decoded = decode(encode(map))
        assertEquals(map, decoded)
        assertEquals(PlaybackAction.SLEEP_TIMER, decoded.action(PlaybackControl.HOLD_BACKWARD, ControlSurface.HEADPHONES))
        assertEquals(45.0, decoded.skipForwardInterval, 0.0)
    }

    /**
     * A blob is a file, and a file can say anything.
     *
     * Every screen draws these as a whole number of seconds, and nothing sat
     * between preferences and those labels, so `1e300` in the blob would be
     * printed — or crash the conversion, as it did on iOS. The decoder is the
     * one choke point, which is why the clamp is there and this asks it
     * directly.
     */
    @Test
    fun absurdStoredIntervals() {
        val stored = listOf(
            1e300, -1e300, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY, Double.NaN, 0.0, 1.0, 4.9, 10_000.0,
            -45.0, Long.MAX_VALUE.toDouble(), Long.MIN_VALUE.toDouble(), 121.0, 120.0, 5.0,
        )
        for (value in stored) {
            val legal = CommandMap.legalInterval(value, 30.0)
            assertTrue("$value came back as $legal", legal in CommandMap.intervalRange)
            // Which is the whole point: every screen prints this.
            assertTrue(legal.toInt() >= 5)
            assertTrue(legal.toInt() <= 120)
        }
    }

    /** An interval the blob does not carry keeps the shipped default. */
    @Test
    fun missingIntervalKeepsTheDefault() {
        val decoded = decode("{}")
        assertEquals(30.0, decoded.skipForwardInterval, 0.0)
        assertEquals(15.0, decoded.skipBackwardInterval, 0.0)
        assertEquals(30.0, CommandMap.legalInterval(null, 30.0), 0.0)
        // A NaN survives Swift's `max`, so the clamp alone would let it through.
        assertEquals(15.0, CommandMap.legalInterval(Double.NaN, 15.0), 0.0)
    }

    /**
     * The stepper's range and the decoder's are one value, so a setting cannot
     * be offered and then quietly moved by the next launch.
     */
    @Test
    fun stepperAndDecoderAgree() {
        var seconds = CommandMap.intervalRange.start
        while (seconds <= CommandMap.intervalRange.endInclusive) {
            val map = CommandMap().copy(skipForwardInterval = seconds)
            val decoded = decode(encode(map))
            assertEquals("${seconds}s did not survive a relaunch", seconds, decoded.skipForwardInterval, 0.0)
            seconds += 5
        }
    }

    // Migration
    //
    // Anyone who has already opened the app has the old table sitting in
    // preferences, so changing `defaultBindings` alone reaches nobody.

    /**
     * A map as an older build wrote it: the old table, and no version field at
     * all — which is the shape that actually exists on the reader's phone.
     */
    private fun storedByOldBuild(bindings: Map<ControlSurface, Map<PlaybackControl, PlaybackAction>>): String {
        val data = encode(CommandMap(bindings = bindings, bindingsVersion = 0))
        val element = IssaJson.parseToJsonElement(data).jsonObject
        return JsonObject(element - "bindingsVersion").toString()
    }

    /** An install carrying the old chapter bindings is moved onto the new ones. */
    @Test
    fun migratesLegacyBindings() {
        val map = decode(storedByOldBuild(CommandMap.legacyBindings))

        // The reported complaint, gone: nothing reachable jumps a chapter.
        assertEquals(PlaybackAction.NONE, map.action(PlaybackControl.WHEEL_NEXT, ControlSurface.PHONE))
        assertEquals(PlaybackAction.NONE, map.action(PlaybackControl.WHEEL_PREVIOUS, ControlSurface.PHONE))
        assertEquals(PlaybackAction.NONE, map.action(PlaybackControl.WHEEL_NEXT, ControlSurface.HEADPHONES))
        assertEquals(PlaybackAction.NEXT_PARAGRAPH, map.action(PlaybackControl.HOLD_FORWARD, ControlSurface.PHONE))
        assertFalse(map.usesTrackCommands(ControlSurface.PHONE))
        assertEquals(CommandMap.CURRENT_BINDINGS_VERSION, map.bindingsVersion)
    }

    /** A binding the reader chose themselves survives the migration. */
    @Test
    fun migrationKeepsDeliberateChoices() {
        val legacy = CommandMap.legacyBindings.toMutableMap()
        // Two deliberate departures from the old table. The second is itself a
        // chapter jump, and must survive precisely because they asked for it —
        // the rule is "never by default", not "never".
        legacy[ControlSurface.PHONE] = legacy.getValue(ControlSurface.PHONE) +
            (PlaybackControl.WHEEL_NEXT to PlaybackAction.SLEEP_TIMER)
        legacy[ControlSurface.HEADPHONES] = legacy.getValue(ControlSurface.HEADPHONES) +
            (PlaybackControl.WHEEL_NEXT to PlaybackAction.PREVIOUS_CHAPTER)
        val map = decode(storedByOldBuild(legacy))

        assertEquals(PlaybackAction.SLEEP_TIMER, map.action(PlaybackControl.WHEEL_NEXT, ControlSurface.PHONE))
        assertEquals(PlaybackAction.PREVIOUS_CHAPTER, map.action(PlaybackControl.WHEEL_NEXT, ControlSurface.HEADPHONES))
        // …while the ones they never touched still move to the new defaults.
        assertEquals(PlaybackAction.NEXT_PARAGRAPH, map.action(PlaybackControl.HOLD_FORWARD, ControlSurface.PHONE))
        assertEquals(PlaybackAction.NONE, map.action(PlaybackControl.WHEEL_PREVIOUS, ControlSurface.PHONE))
        assertEquals(PlaybackAction.NONE, map.action(PlaybackControl.WHEEL_PREVIOUS, ControlSurface.HEADPHONES))
        // And having kept a wheel binding, they keep the track buttons too.
        assertTrue(map.usesTrackCommands(ControlSurface.PHONE))
        assertTrue(map.usesTrackCommands(ControlSurface.HEADPHONES))
    }

    /**
     * A binding the migration *would* move, chosen on purpose: the wheel's
     * "next" on the phone set to next chapter, which is its legacy value and
     * which `migrated` strips back to nothing. The tap control this used to
     * bind was not on its legacy value, so it survived whether or not the
     * version gate ran, and the gate went untested.
     */
    @Test
    fun doesNotRemigrate() {
        val map = CommandMap().withBinding(PlaybackAction.NEXT_CHAPTER, PlaybackControl.WHEEL_NEXT, ControlSurface.PHONE)
        assertNull(
            "the binding has to be one a migration would remove, or this proves nothing",
            CommandMap.migrated(map.bindings)[ControlSurface.PHONE]?.get(PlaybackControl.WHEEL_NEXT),
        )
        val decoded = decode(encode(map))
        assertEquals(
            "a reader's own wheel binding was stripped on relaunch",
            PlaybackAction.NEXT_CHAPTER, decoded.action(PlaybackControl.WHEEL_NEXT, ControlSurface.PHONE),
        )
    }

    // Android's own

    /**
     * The car surface is stored as `car`, and a map that says `carPlay` — the
     * Swift client's spelling — reads as the car too, so a setting means the
     * same thing whichever client wrote it.
     */
    @Test
    fun theCarSurfaceReadsEitherSpelling() {
        val written = encode(CommandMap())
        assertTrue(written.contains("\"car\""))
        assertFalse(written.contains("carPlay"))

        val swift = """
            {"bindings":["carPlay",["wheelNext","nextChapter"],"phone",["tapForward","playPause"]],
             "skipForwardInterval":45,"skipBackwardInterval":10,"bindingsVersion":1}
        """.trimIndent()
        val map = decode(swift)
        assertEquals(PlaybackAction.NEXT_CHAPTER, map.action(PlaybackControl.WHEEL_NEXT, ControlSurface.CAR))
        assertEquals(PlaybackAction.PLAY_PAUSE, map.action(PlaybackControl.TAP_FORWARD, ControlSurface.PHONE))
        assertEquals(45.0, map.skipForwardInterval, 0.0)
        assertEquals(10.0, map.skipBackwardInterval, 0.0)
        assertEquals("Android Auto", ControlSurface.CAR.title)
    }
}
