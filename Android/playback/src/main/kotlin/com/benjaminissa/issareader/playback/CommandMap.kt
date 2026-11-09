package com.benjaminissa.issareader.playback

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.descriptors.buildClassSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.put

/**
 * What a control does when pressed.
 *
 * The brief asks for the phone's own forward/back controls, and a car's
 * steering-wheel buttons, to be reassignable. Everything a control can do is
 * enumerated here so the mapping is data rather than scattered branches.
 *
 * [rawValue] is Swift's raw value, which is what a stored map spells.
 */
enum class PlaybackAction(val rawValue: String) {
    PLAY_PAUSE("playPause"),
    SKIP_FORWARD("skipForward"),
    SKIP_BACKWARD("skipBackward"),
    NEXT_SENTENCE("nextSentence"),
    PREVIOUS_SENTENCE("previousSentence"),
    NEXT_PARAGRAPH("nextParagraph"),
    PREVIOUS_PARAGRAPH("previousParagraph"),
    NEXT_CHAPTER("nextChapter"),
    PREVIOUS_CHAPTER("previousChapter"),
    SPEED_UP("speedUp"),
    SPEED_DOWN("speedDown"),
    SLEEP_TIMER("sleepTimer"),

    /**
     * The system's discrete play and pause, as the lock screen, Android Auto
     * and a paired watch send them. Not offered as bindings — [PLAY_PAUSE]
     * already covers what a button should do — but they exist so a "play"
     * command can mean "make sure audio is running" rather than "flip whatever
     * the flag says"; see [CommandRouter.activate].
     */
    PLAY("play"),
    PAUSE("pause"),
    NONE("none"),
    ;

    val title: String
        get() = when (this) {
            PLAY_PAUSE -> "Play / pause"
            SKIP_FORWARD -> "Skip forward"
            SKIP_BACKWARD -> "Skip back"
            NEXT_SENTENCE -> "Next sentence"
            PREVIOUS_SENTENCE -> "Previous sentence"
            NEXT_PARAGRAPH -> "Next paragraph"
            PREVIOUS_PARAGRAPH -> "Previous paragraph"
            NEXT_CHAPTER -> "Next chapter"
            PREVIOUS_CHAPTER -> "Previous chapter"
            SPEED_UP -> "Speed up"
            SPEED_DOWN -> "Slow down"
            SLEEP_TIMER -> "Sleep timer"
            PLAY -> "Play"
            PAUSE -> "Pause"
            NONE -> "Nothing"
        }

    /**
     * Whether this action moves the listener a whole chapter.
     *
     * Named rather than compared inline because it is the thing a default must
     * never be: a chapter jump that nobody asked for loses a listener's place
     * far more thoroughly than any number of seconds can.
     */
    val isChapterJump: Boolean get() = this == NEXT_CHAPTER || this == PREVIOUS_CHAPTER

    companion object {
        /**
         * The actions the Controls screen offers for binding.
         *
         * Not `entries`. [PLAY] and [PAUSE] exist for the system's discrete
         * commands, and a button already has [PLAY_PAUSE]; [SLEEP_TIMER] has no
         * handler in either coordinator, so offering it made a binding that read
         * back correctly and did nothing at all — a setting that cannot be wrong
         * because it is never consulted. A stored map carrying one of these still
         * decodes and still shows in the picker; it just cannot be chosen anew.
         */
        val assignable: List<PlaybackAction>
            get() = entries.filter { it != PLAY && it != PAUSE && it != SLEEP_TIMER }

        fun fromRawValue(raw: String): PlaybackAction? = entries.firstOrNull { it.rawValue == raw }
    }
}

/**
 * A physical control that can be bound to an action.
 *
 * The double-tap and hold controls are defined and stored, but **nothing
 * fires them** — the system's remote commands have no event distinct from a
 * double tap (headphones' double and triple press arrive as next/previous
 * track, already covered by [WHEEL_NEXT]/[WHEEL_PREVIOUS]), and a real "hold"
 * is a continuous, accelerating scrub, not a single discrete action. So a
 * binding on one of these has no effect anywhere and they are not offered in
 * the Controls screen. Kept rather than removed outright so a stored
 * [CommandMap] from an earlier build — which may still carry a binding on one —
 * decodes without special-casing; see [CommandMap.migrated].
 */
enum class PlaybackControl(val rawValue: String) {
    TAP_FORWARD("tapForward"),
    TAP_BACKWARD("tapBackward"),
    DOUBLE_TAP_FORWARD("doubleTapForward"),
    DOUBLE_TAP_BACKWARD("doubleTapBackward"),
    HOLD_FORWARD("holdForward"),
    HOLD_BACKWARD("holdBackward"),

    /**
     * The head unit's next/previous track buttons, which is also where a
     * steering wheel's `»` and `«` are routed by the car — and where
     * headphones' double- and triple-press land.
     */
    WHEEL_NEXT("wheelNext"),
    WHEEL_PREVIOUS("wheelPrevious"),
    ;

    val title: String
        get() = when (this) {
            TAP_FORWARD -> "Tap forward"
            TAP_BACKWARD -> "Tap back"
            DOUBLE_TAP_FORWARD -> "Double-tap forward"
            DOUBLE_TAP_BACKWARD -> "Double-tap back"
            HOLD_FORWARD -> "Hold forward"
            HOLD_BACKWARD -> "Hold back"
            WHEEL_NEXT -> "Wheel »"
            WHEEL_PREVIOUS -> "Wheel «"
        }

    companion object {
        fun fromRawValue(raw: String): PlaybackControl? = entries.firstOrNull { it.rawValue == raw }
    }
}

/**
 * Where a control lives. The same physical gesture can mean different things
 * in the car than it does on headphones, which is the point of separating them.
 *
 * The car is Android Auto here, as it is CarPlay on iOS. It is stored as
 * `car`, and a stored map that says `carPlay` — the Swift spelling — is read as
 * the car too, so a setting means the same thing whichever client wrote it.
 */
enum class ControlSurface(val rawValue: String) {
    PHONE("phone"),
    CAR("car"),
    HEADPHONES("headphones"),
    ;

    val title: String
        get() = when (this) {
            PHONE -> "Phone"
            CAR -> "Android Auto"
            HEADPHONES -> "Headphones"
        }

    companion object {
        fun fromRawValue(raw: String): ControlSurface? = when (raw) {
            // The Swift client's name for the car surface.
            "carPlay" -> CAR
            else -> entries.firstOrNull { it.rawValue == raw }
        }
    }
}

/**
 * The user's control assignments, per surface.
 *
 * A value: [withBinding] answers a new map rather than changing this one.
 */
@Serializable(with = CommandMap.Serializer::class)
data class CommandMap(
    val bindings: Map<ControlSurface, Map<PlaybackControl, PlaybackAction>> = defaultBindings,
    /** Seconds for the skip actions, shown on the buttons themselves. */
    val skipForwardInterval: Double = 30.0,
    val skipBackwardInterval: Double = 15.0,
    /**
     * Which generation of [defaultBindings] a stored map was seeded from.
     *
     * Without it a change to the shipped defaults is invisible to everyone who
     * has already launched the app, because their choices — including the ones
     * they never actually made — are already on disk.
     */
    val bindingsVersion: Int = CURRENT_BINDINGS_VERSION,
) {
    fun action(control: PlaybackControl, surface: ControlSurface): PlaybackAction =
        bindings[surface]?.get(control) ?: PlaybackAction.NONE

    /** This map with [control] on [surface] bound to [action], at the current version. */
    fun withBinding(action: PlaybackAction, control: PlaybackControl, surface: ControlSurface): CommandMap {
        val updated = bindings.toMutableMap()
        updated[surface] = (bindings[surface] ?: emptyMap()) + (control to action)
        return copy(bindings = updated, bindingsVersion = CURRENT_BINDINGS_VERSION)
    }

    /**
     * Whether the system's next/previous **track** commands should be offered
     * at all on this surface.
     *
     * This is what decides which transport the system draws. With the track
     * commands offered it shows `⏮ ⏭` and hides the interval skips; without
     * them it shows `⏪15` and `⏩30`. Since nothing on the phone or on
     * headphones is bound to the wheel by default, the lock screen draws the
     * skips — and a listener who deliberately binds the wheel to chapter, or to
     * anything else, gets the track buttons back along with it.
     */
    fun usesTrackCommands(surface: ControlSurface): Boolean =
        action(PlaybackControl.WHEEL_NEXT, surface) != PlaybackAction.NONE ||
            action(PlaybackControl.WHEEL_PREVIOUS, surface) != PlaybackAction.NONE

    companion object {
        /**
         * Bumped whenever [defaultBindings] changes in a way existing installs
         * must pick up. 1: forward and back stopped meaning "chapter".
         */
        const val CURRENT_BINDINGS_VERSION: Int = 1

        /**
         * What a skip interval may be, stated once so the stepper that offers
         * them and the decoder that reads them back cannot disagree.
         *
         * The bound matters because every screen that draws one draws it as a
         * whole number of seconds, and the stored value comes straight out of
         * preferences with nothing between the blob and the label — so `1e300`
         * in the file would be printed, or overflow the conversion. Clamping
         * here rather than at each label keeps them in step.
         */
        val intervalRange: ClosedFloatingPointRange<Double> = 5.0..120.0

        /**
         * A stored interval, or the shipped default where the blob has none or
         * holds something that is not a length.
         *
         * Non-finite goes to the default rather than to a bound: Swift's `max`
         * with a NaN hands the NaN straight back, so the clamp alone would let
         * one through, and neither end of the range is a more honest reading of
         * "not a number" than the value the app ships with.
         */
        fun legalInterval(stored: Double?, default: Double): Double {
            if (stored == null || !stored.isFinite()) return default
            return minOf(maxOf(stored, intervalRange.start), intervalRange.endInclusive)
        }

        /** Whether any default on any surface moves a whole chapter. */
        val defaultsIncludeAChapterJump: Boolean
            get() = defaultBindings.values.any { surface -> surface.values.any { it.isChapterJump } }

        /**
         * Defaults chosen for what an audiobook listener expects: **every**
         * forward/back control moves by an interval of time.
         *
         * Moving by a chapter stays available on every control — it is one pick
         * in Settings → Controls — but it is never what a button does unasked. A
         * chapter is tens of minutes; a control that jumps one by accident, on a
         * lock screen or a steering wheel, loses a listener's place outright.
         *
         * The wheel is deliberately unbound on the phone and on headphones. That
         * is not an omission: it is what keeps `⏪15`/`⏩30` on the lock screen
         * instead of `⏮`/`⏭`. See [usesTrackCommands].
         */
        val defaultBindings: Map<ControlSurface, Map<PlaybackControl, PlaybackAction>> = mapOf(
            ControlSurface.PHONE to mapOf(
                PlaybackControl.TAP_FORWARD to PlaybackAction.SKIP_FORWARD,
                PlaybackControl.TAP_BACKWARD to PlaybackAction.SKIP_BACKWARD,
                PlaybackControl.DOUBLE_TAP_FORWARD to PlaybackAction.NEXT_SENTENCE,
                PlaybackControl.DOUBLE_TAP_BACKWARD to PlaybackAction.PREVIOUS_SENTENCE,
                PlaybackControl.HOLD_FORWARD to PlaybackAction.NEXT_PARAGRAPH,
                PlaybackControl.HOLD_BACKWARD to PlaybackAction.PREVIOUS_PARAGRAPH,
            ),
            ControlSurface.CAR to mapOf(
                PlaybackControl.TAP_FORWARD to PlaybackAction.SKIP_FORWARD,
                PlaybackControl.TAP_BACKWARD to PlaybackAction.SKIP_BACKWARD,
                // Bound, because in the car the wheel is the control that
                // matters and an unbound one is a dead button at 70mph. The car
                // draws its own transport, so offering the track commands here
                // costs nothing on the lock screen.
                PlaybackControl.WHEEL_NEXT to PlaybackAction.SKIP_FORWARD,
                PlaybackControl.WHEEL_PREVIOUS to PlaybackAction.SKIP_BACKWARD,
                PlaybackControl.HOLD_FORWARD to PlaybackAction.NEXT_PARAGRAPH,
                PlaybackControl.HOLD_BACKWARD to PlaybackAction.PREVIOUS_PARAGRAPH,
            ),
            ControlSurface.HEADPHONES to mapOf(
                PlaybackControl.TAP_FORWARD to PlaybackAction.PLAY_PAUSE,
                PlaybackControl.DOUBLE_TAP_FORWARD to PlaybackAction.SKIP_FORWARD,
                PlaybackControl.DOUBLE_TAP_BACKWARD to PlaybackAction.SKIP_BACKWARD,
            ),
        )

        /**
         * The table shipped before version 1.
         *
         * Kept only so migration can tell a binding a reader chose from one they
         * merely inherited. Re-seeding wholesale would throw away real choices;
         * leaving stored values alone would mean the fix reached nobody who had
         * already opened the app.
         */
        internal val legacyBindings: Map<ControlSurface, Map<PlaybackControl, PlaybackAction>> = mapOf(
            ControlSurface.PHONE to mapOf(
                PlaybackControl.TAP_FORWARD to PlaybackAction.SKIP_FORWARD,
                PlaybackControl.TAP_BACKWARD to PlaybackAction.SKIP_BACKWARD,
                PlaybackControl.DOUBLE_TAP_FORWARD to PlaybackAction.NEXT_SENTENCE,
                PlaybackControl.DOUBLE_TAP_BACKWARD to PlaybackAction.PREVIOUS_SENTENCE,
                PlaybackControl.HOLD_FORWARD to PlaybackAction.NEXT_CHAPTER,
                PlaybackControl.HOLD_BACKWARD to PlaybackAction.PREVIOUS_CHAPTER,
                PlaybackControl.WHEEL_NEXT to PlaybackAction.NEXT_CHAPTER,
                PlaybackControl.WHEEL_PREVIOUS to PlaybackAction.PREVIOUS_CHAPTER,
            ),
            ControlSurface.CAR to mapOf(
                PlaybackControl.TAP_FORWARD to PlaybackAction.SKIP_FORWARD,
                PlaybackControl.TAP_BACKWARD to PlaybackAction.SKIP_BACKWARD,
                PlaybackControl.WHEEL_NEXT to PlaybackAction.NEXT_PARAGRAPH,
                PlaybackControl.WHEEL_PREVIOUS to PlaybackAction.PREVIOUS_PARAGRAPH,
                PlaybackControl.HOLD_FORWARD to PlaybackAction.NEXT_CHAPTER,
                PlaybackControl.HOLD_BACKWARD to PlaybackAction.PREVIOUS_CHAPTER,
            ),
            ControlSurface.HEADPHONES to mapOf(
                PlaybackControl.TAP_FORWARD to PlaybackAction.PLAY_PAUSE,
                PlaybackControl.DOUBLE_TAP_FORWARD to PlaybackAction.SKIP_FORWARD,
                PlaybackControl.DOUBLE_TAP_BACKWARD to PlaybackAction.SKIP_BACKWARD,
                PlaybackControl.WHEEL_NEXT to PlaybackAction.NEXT_CHAPTER,
                PlaybackControl.WHEEL_PREVIOUS to PlaybackAction.PREVIOUS_CHAPTER,
            ),
        )

        /**
         * Moves a stored table onto the current defaults, one control at a time.
         *
         * A control still sitting on the value it shipped with is replaced; one
         * the reader changed is left exactly as they left it, chapter jumps
         * included.
         */
        internal fun migrated(
            stored: Map<ControlSurface, Map<PlaybackControl, PlaybackAction>>,
        ): Map<ControlSurface, Map<PlaybackControl, PlaybackAction>> {
            val result = LinkedHashMap<ControlSurface, MutableMap<PlaybackControl, PlaybackAction>>()
            for ((surface, controls) in stored) result[surface] = LinkedHashMap(controls)
            for (surface in ControlSurface.entries) {
                for (control in PlaybackControl.entries) {
                    val inherited = legacyBindings[surface]?.get(control) ?: PlaybackAction.NONE
                    val current = stored[surface]?.get(control) ?: PlaybackAction.NONE
                    if (current != inherited) continue
                    val replacement = defaultBindings[surface]?.get(control)
                    if (replacement != null) {
                        result.getOrPut(surface) { LinkedHashMap() }[control] = replacement
                    } else {
                        // Swift's `result[surface]?.removeValue(forKey:)`: a
                        // surface that was never stored stays absent.
                        result[surface]?.remove(control)
                    }
                }
            }
            return result
        }
    }

    /**
     * The JSON shape the Swift client's `Codable` writes, and the leniency it
     * reads with.
     *
     * Decoding is where migration happens, because this type is read back from
     * preferences on every launch and there is no other choke point. Every
     * field is optional on the way in: a value stored by an older build is
     * missing `bindingsVersion` entirely, and throwing on that would reset a
     * reader's whole configuration.
     *
     * The bindings are written as Swift encodes a dictionary whose keys are
     * enums — an array alternating key and value — and read either that way or
     * as a JSON object keyed by raw value.
     */
    object Serializer : KSerializer<CommandMap> {
        override val descriptor: SerialDescriptor =
            buildClassSerialDescriptor("com.benjaminissa.issareader.playback.CommandMap")

        override fun serialize(encoder: Encoder, value: CommandMap) {
            val json = encoder as? JsonEncoder ?: throw SerializationException("CommandMap is written as JSON only")
            json.encodeJsonElement(
                buildJsonObject {
                    put(
                        "bindings",
                        buildJsonArray {
                            for ((surface, controls) in value.bindings) {
                                add(JsonPrimitive(surface.rawValue))
                                add(
                                    buildJsonArray {
                                        for ((control, action) in controls) {
                                            add(JsonPrimitive(control.rawValue))
                                            add(JsonPrimitive(action.rawValue))
                                        }
                                    },
                                )
                            }
                        },
                    )
                    put("skipForwardInterval", value.skipForwardInterval)
                    put("skipBackwardInterval", value.skipBackwardInterval)
                    put("bindingsVersion", value.bindingsVersion)
                },
            )
        }

        override fun deserialize(decoder: Decoder): CommandMap {
            val json = decoder as? JsonDecoder ?: throw SerializationException("CommandMap is read as JSON only")
            val root = json.decodeJsonElement() as? JsonObject
                ?: throw SerializationException("CommandMap is not an object")
            val stored = root["bindings"]?.takeUnless { it is JsonNull }?.let(::decodeBindings) ?: defaultBindings
            // Clamped on the way in, not merely defaulted. This is the only
            // place a stored interval enters the app, and every screen that
            // draws one draws it as a whole number.
            val forward = legalInterval(number(root, "skipForwardInterval"), 30.0)
            val backward = legalInterval(number(root, "skipBackwardInterval"), 15.0)
            val version = root["bindingsVersion"]?.takeUnless { it is JsonNull }?.let {
                (it as? JsonPrimitive)?.takeIf { primitive -> !primitive.isString }?.intOrNull
                    ?: throw SerializationException("bindingsVersion is not an integer")
            } ?: 0
            return CommandMap(
                bindings = if (version < CURRENT_BINDINGS_VERSION) migrated(stored) else stored,
                skipForwardInterval = forward,
                skipBackwardInterval = backward,
                bindingsVersion = CURRENT_BINDINGS_VERSION,
            )
        }

        private fun number(root: JsonObject, key: String): Double? {
            val element = root[key] ?: return null
            if (element is JsonNull) return null
            val primitive = element as? JsonPrimitive
            if (primitive == null || primitive.isString) throw SerializationException("$key is not a number")
            return primitive.doubleOrNull ?: throw SerializationException("$key is not a number")
        }

        private fun decodeBindings(element: JsonElement): Map<ControlSurface, Map<PlaybackControl, PlaybackAction>> {
            val result = LinkedHashMap<ControlSurface, Map<PlaybackControl, PlaybackAction>>()
            for ((key, value) in pairs(element)) {
                val surface = ControlSurface.fromRawValue(key)
                    ?: throw SerializationException("unknown control surface $key")
                val controls = LinkedHashMap<PlaybackControl, PlaybackAction>()
                for ((controlKey, actionValue) in pairs(value)) {
                    val control = PlaybackControl.fromRawValue(controlKey)
                        ?: throw SerializationException("unknown control $controlKey")
                    val raw = (actionValue as? JsonPrimitive)?.takeIf { it.isString }?.content
                        ?: throw SerializationException("an action is not a string")
                    controls[control] = PlaybackAction.fromRawValue(raw)
                        ?: throw SerializationException("unknown action $raw")
                }
                result[surface] = controls
            }
            return result
        }

        /** A dictionary as Swift writes one with enum keys, or as an object. */
        private fun pairs(element: JsonElement): List<Pair<String, JsonElement>> = when (element) {
            is JsonObject -> element.entries.map { it.key to it.value }
            is JsonArray -> {
                if (element.size % 2 != 0) throw SerializationException("a dictionary with an odd number of elements")
                element.chunked(2).map { (key, value) ->
                    val name = (key as? JsonPrimitive)?.takeIf { it.isString }?.content
                        ?: throw SerializationException("a dictionary key is not a string")
                    name to value
                }
            }
            else -> throw SerializationException("a dictionary is neither an array nor an object")
        }
    }
}
