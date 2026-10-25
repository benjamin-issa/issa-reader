package com.benjaminissa.issareader.render

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.descriptors.buildClassSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * One book's departure from the reading settings.
 *
 * Sparse on purpose: every field is optional, and only the ones set are
 * applied. A book that overrides nothing but its face still follows a later
 * change to the global line spacing — which storing a whole resolved style
 * would silently freeze.
 */
@Serializable(with = ReaderStyleOverride.Serializer::class)
data class ReaderStyleOverride(
    val typeface: ReaderStyle.Typeface? = null,
    val fontSize: Double? = null,
    val lineSpacing: ReaderStyle.LineSpacing? = null,
    /**
     * Unset means "whatever my reading settings say" — which may itself be
     * "follow the book". Set means this book departs from that, in one of the
     * three directions the global setting also offers.
     */
    val justification: ReaderStyle.Justification? = null,
) {
    /**
     * Whether this book has anything of its own left.
     *
     * An override that overrides nothing is deleted rather than stored, so
     * "use my defaults" leaves no trace to go stale.
     */
    val isEmpty: Boolean get() = typeface == null && fontSize == null && lineSpacing == null && justification == null

    /** Which fields the reader has taken control of, for the sheet to show. */
    val count: Int
        get() = listOf(typeface != null, fontSize != null, lineSpacing != null, justification != null).count { it }

    /** The same move as [ReaderStyle.replacingLegacyDefaultFace], for a book that took the old default as its own. */
    fun replacingLegacyDefaultFace(): ReaderStyleOverride {
        if (typeface != ReaderStyle.Typeface.Bundled(ReaderStyle.LEGACY_DEFAULT_FAMILY)) return this
        return copy(typeface = ReaderStyle.Typeface.Bundled(ReaderStyle.DEFAULT_FAMILY))
    }

    /**
     * Decoded field by field, every field forgiving.
     *
     * Not the generated decoder, and the reason is one level up: the settings
     * store decodes the whole `Map<String, ReaderStyleOverride>` at once, so
     * one book carrying a value this build does not recognise — a typeface
     * since removed, a case a newer build wrote — would throw out *every*
     * book's typography. It is the rule `ReaderStyle` decodes by, applied to
     * the per-book blob.
     */
    object Serializer : KSerializer<ReaderStyleOverride> {
        override val descriptor: SerialDescriptor = buildClassSerialDescriptor("ReaderStyleOverride")

        override fun serialize(encoder: Encoder, value: ReaderStyleOverride) {
            val json = encoder as? JsonEncoder ?: throw SerializationException("ReaderStyleOverride is written as JSON")
            json.encodeJsonElement(
                buildJsonObject {
                    value.typeface?.let { put("typeface", it.raw) }
                    value.fontSize?.let { put("fontSize", it) }
                    value.lineSpacing?.let { put("lineSpacing", it.rawValue) }
                    value.justification?.let { put("justification", it.rawValue) }
                    // The key this replaced, written as well, as `ReaderStyle`
                    // does for the global setting. The build before the
                    // three-position setting reads only `justified`; without it
                    // a reader who moves back a build sees their per-book
                    // justification as unset, and the first time that build
                    // saves any book's typography the whole map is written back
                    // without it, so moving up again finds it gone for good.
                    // `always` and `never` are a switch's two positions and
                    // round-trip exactly (the decoder below reads a legacy
                    // `false` as `never`); following the book is a thing that
                    // build cannot do, so it is left unsaid there, which is
                    // what it would have written itself.
                    when (value.justification) {
                        ReaderStyle.Justification.ALWAYS -> put("justified", true)
                        ReaderStyle.Justification.NEVER -> put("justified", false)
                        ReaderStyle.Justification.FOLLOW_BOOK, null -> {}
                    }
                },
            )
        }

        override fun deserialize(decoder: Decoder): ReaderStyleOverride {
            val json = decoder as? JsonDecoder ?: throw SerializationException("ReaderStyleOverride is read from JSON")
            val container = json.decodeJsonElement() as? JsonObject
                ?: throw SerializationException("ReaderStyleOverride is not an object")
            // `justification` replaced `justified`, and reads the old key the
            // same way `ReaderStyle` does: a book explicitly set to justified
            // stays justified, and one explicitly set ragged keeps that too —
            // unlike the global setting, a value here was always a deliberate
            // act.
            val justification = container.string("justification")?.let(ReaderStyle.Justification::fromRawValue)
                ?: container.boolean("justified")?.let {
                    if (it) ReaderStyle.Justification.ALWAYS else ReaderStyle.Justification.NEVER
                }
            return ReaderStyleOverride(
                typeface = container.string("typeface")?.let(ReaderStyle.Typeface::fromRaw),
                // Bounded like the global size, for the same reason: a stored
                // `1e300` reached the page and the Text size stepper's label
                // unchecked.
                fontSize = ReaderStyle.clampedLength(container.number("fontSize"), ReaderStyle.fontSizeRange),
                lineSpacing = container.string("lineSpacing")?.let(ReaderStyle.LineSpacing::fromRawValue),
                justification = justification,
            )
        }
    }
}
