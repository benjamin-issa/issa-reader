package com.benjaminissa.issareader.render

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.descriptors.buildClassSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/*
 * The colour the reader has chosen for the sentence being read aloud, and the
 * curated set it is chosen from.
 *
 * Per *page colour*, not per book. A highlighter that reads as a warm marker
 * pen on cream is a muddy smear on near-black, so the choice belongs to the
 * ground it is painted on: someone who reads on Paper by day and Night by bed
 * can set each once and never think about it again.
 *
 * Beside `ReaderTheme` rather than in the UI: the theme owns what the page
 * looks like, and `ReaderTheme.highlight` is *defined* by the default preset
 * here, so the swatch a reader sees and the colour the page paints when they
 * have chosen nothing cannot drift apart.
 */

/**
 * A resolved sRGB colour the reader mixed, stored rather than referenced, so
 * it does not change because the device went into dark theme overnight.
 *
 * Clamped on the way in — including on the way in from a decoded blob, which
 * is why the serializer is written by hand. A NaN component reaching a canvas
 * fill reads on the page as the whole marked sentence disappearing.
 */
@Serializable(with = HighlightTint.Serializer::class)
class HighlightTint(red: Double, green: Double, blue: Double, alpha: Double) {
    val red: Double = clamped(red)
    val green: Double = clamped(green)
    val blue: Double = clamped(blue)
    val alpha: Double = clamped(alpha)

    val rgba: Rgba get() = Rgba(red, green, blue, alpha)

    override fun equals(other: Any?): Boolean =
        other is HighlightTint && red == other.red && green == other.green && blue == other.blue && alpha == other.alpha

    override fun hashCode(): Int = listOf(red, green, blue, alpha).hashCode()

    override fun toString(): String = "HighlightTint(red=$red, green=$green, blue=$blue, alpha=$alpha)"

    companion object {
        /** Anything that is not a number at all has no honest place on the range, and zero at least draws. */
        private fun clamped(value: Double): Double = if (value.isFinite()) value.coerceIn(0.0, 1.0) else 0.0
    }

    object Serializer : KSerializer<HighlightTint> {
        override val descriptor: SerialDescriptor = buildClassSerialDescriptor("HighlightTint")

        override fun serialize(encoder: Encoder, value: HighlightTint) {
            val json = encoder as JsonEncoder
            json.encodeJsonElement(
                buildJsonObject {
                    put("red", value.red)
                    put("green", value.green)
                    put("blue", value.blue)
                    put("alpha", value.alpha)
                },
            )
        }

        override fun deserialize(decoder: Decoder): HighlightTint {
            val element = (decoder as JsonDecoder).decodeJsonElement().jsonObject
            fun component(key: String): Double {
                val primitive = element[key]?.jsonPrimitive ?: throw SerializationException("HighlightTint is missing $key")
                return primitive.doubleOrNull ?: when (primitive.contentOrNull?.lowercase()) {
                    // How Foundation writes the non-conforming floats.
                    "nan" -> Double.NaN
                    "inf" -> Double.POSITIVE_INFINITY
                    "-inf" -> Double.NEGATIVE_INFINITY
                    else -> throw SerializationException("HighlightTint.$key is not a number")
                }
            }
            return HighlightTint(component("red"), component("green"), component("blue"), component("alpha"))
        }
    }
}

/**
 * The eight highlighters the app offers — four for a light page, four for a
 * dark one, those same hues lifted so they still read against near-black.
 *
 * Stored by name, never by value: a blob that records `"tangerine"` follows the
 * table, where one that recorded `0xE2853A` would freeze today's colour into
 * every reader's settings for ever.
 */
@Serializable
enum class HighlighterPreset(val hex: Int, val title: String) {
    // Light grounds — Paper and Sepia.
    @SerialName("tangerine") TANGERINE(0xE2853A, "Tangerine"),
    @SerialName("moss") MOSS(0x7C8A5A, "Moss"),
    @SerialName("rose") ROSE(0xC46A6A, "Rose"),
    @SerialName("plum") PLUM(0x8A6AA8, "Plum"),

    // Dark grounds — Night and Slate.
    @SerialName("amber") AMBER(0xEE9B57, "Amber"),
    @SerialName("sage") SAGE(0x9DAE74, "Sage"),
    @SerialName("blush") BLUSH(0xD98C8C, "Blush"),
    @SerialName("iris") IRIS(0xA88AC6, "Iris"),
    ;

    val rawValue: String get() = name.lowercase()

    companion object {
        fun fromRawValue(raw: String): HighlighterPreset? = entries.firstOrNull { it.rawValue == raw }
    }
}

/**
 * One page colour's highlighter: a swatch from the table, or a colour mixed in
 * the colour picker.
 *
 * Written by hand so the two cases keep the shapes the Swift client writes —
 * `{"preset":"moss"}` and `{"custom":{…}}`. An unrecognised preset name
 * *throws* on purpose: the caller decodes one theme at a time, so a name this
 * build does not know costs that page colour its highlighter and nothing else,
 * rather than silently guessing a colour the reader never chose.
 */
@Serializable(with = HighlighterChoice.Serializer::class)
sealed interface HighlighterChoice {
    data class Preset(val preset: HighlighterPreset) : HighlighterChoice
    data class Custom(val tint: HighlightTint) : HighlighterChoice

    object Serializer : KSerializer<HighlighterChoice> {
        override val descriptor: SerialDescriptor = buildClassSerialDescriptor("HighlighterChoice")

        override fun serialize(encoder: Encoder, value: HighlighterChoice) {
            val json = encoder as JsonEncoder
            val element: JsonElement = when (value) {
                is Preset -> JsonObject(mapOf("preset" to JsonPrimitive(value.preset.rawValue)))
                is Custom -> JsonObject(mapOf("custom" to json.json.encodeToJsonElement(HighlightTint.Serializer, value.tint)))
            }
            json.encodeJsonElement(element)
        }

        override fun deserialize(decoder: Decoder): HighlighterChoice {
            val json = decoder as JsonDecoder
            val element = json.decodeJsonElement().jsonObject
            element["preset"]?.let { raw ->
                val name = raw.jsonPrimitive.content
                val preset = HighlighterPreset.fromRawValue(name)
                    ?: throw SerializationException("Unknown highlighter preset “$name”.")
                return Preset(preset)
            }
            val custom = element["custom"] ?: throw SerializationException("A highlighter choice is neither a preset nor a custom colour.")
            return Custom(json.json.decodeFromJsonElement(HighlightTint.Serializer, custom))
        }
    }
}
