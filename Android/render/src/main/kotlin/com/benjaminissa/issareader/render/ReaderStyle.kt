package com.benjaminissa.issareader.render

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.descriptors.buildClassSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.put

/**
 * Typography and layout the reader applies, matching the design's
 * "Reading & highlights" controls.
 *
 * Stored as one JSON blob with the keys the Swift client writes, so a setting
 * means the same thing on both: `typeface` as one string (`"bundled:Literata"`),
 * the enums by their Swift raw values, `highlighters` keyed by page colour.
 * Fonts themselves are applied by `:render-android`; this holds only the
 * choice.
 */
@Serializable(with = ReaderStyle.Serializer::class)
data class ReaderStyle(
    val typeface: Typeface = Typeface.Bundled(DEFAULT_FAMILY),
    val fontSize: Double = 18.0,
    val lineSpacing: LineSpacing = LineSpacing.NORMAL,
    val theme: ReaderTheme = ReaderTheme.PAPER,
    /**
     * Who decides whether a page is justified: the book, or the reader.
     *
     * This was a `Bool`, and a `Bool` cannot tell "I want ragged text" from "I
     * have never touched this" — which matters now that a book's own
     * `text-align` is read. Most trade fiction asks to be justified, and a
     * reader who has expressed no view should see the book as its publisher
     * set it; a reader who has expressed one should be obeyed everywhere.
     *
     * Only justification. Where a book centres an epigraph or ranges a
     * signature line right, that is structure rather than taste and is honoured
     * under every case here — see [ChapterParser.alignment].
     */
    val justification: Justification = Justification.FOLLOW_BOOK,
    val pageMargin: Double = 24.0,
    val highlightGranularity: HighlightGranularity = HighlightGranularity.SENTENCE,
    /** Keep the narrated sentence on screen while audio plays. */
    val followNarration: Boolean = true,
    /**
     * Allow a page to turn part-way through a sentence rather than waiting
     * for it to finish.
     */
    val turnPagesMidSentence: Boolean = false,
    /**
     * Double-tapping a narrated sentence starts the audio there.
     *
     * Only ever consulted for a book that has narration. A single tap can no
     * longer do this: it was indistinguishable from a page turn, and because
     * it was tested first it made "tap left to go back" unreachable over any
     * narrated text.
     */
    val tapToPlay: Boolean = true,
    /** What the always-visible progress readout shows. */
    val progressDisplay: ProgressDisplay = ProgressDisplay.BOOK,
    /**
     * One highlighter per page colour, for the sentence being read aloud.
     *
     * Sparse, like [ReaderStyleOverride]: a page colour absent from here is
     * using its default, which is what [ReaderTheme.highlight] already paints.
     * Storing all four resolved would freeze today's defaults into everyone's
     * settings and make a later change to the table reach nobody.
     */
    val highlighters: Map<ReaderTheme, HighlighterChoice> = emptyMap(),
    /**
     * The family the current book embeds, once found.
     *
     * Not persisted: it belongs to the book, not to the reader's settings, and
     * the reader may open a different book tomorrow. It *is* part of equality,
     * so discovering it mid-open re-parses the chapter into the new face,
     * which is exactly what should happen.
     */
    val publisherFamily: String? = null,
) {
    enum class LineSpacing(val rawValue: String) {
        TIGHT("tight"),
        NORMAL("normal"),
        ROOMY("roomy"),
        ;

        /**
         * Multiples of the font's natural line height. A serif reading face
         * already carries generous internal leading, so these sit lower than a
         * UI stack would use — 1.45 reads as airy, not comfortable.
         */
        val multiple: Double
            get() = when (this) {
                TIGHT -> 1.05
                NORMAL -> 1.20
                ROOMY -> 1.42
            }

        companion object {
            fun fromRawValue(raw: String): LineSpacing? = entries.firstOrNull { it.rawValue == raw }
        }
    }

    /**
     * Granularity of the read-along highlight, from the design's Word /
     * Sentence / Line control.
     */
    enum class HighlightGranularity(val rawValue: String) {
        WORD("word"),
        SENTENCE("sentence"),
        LINE("line"),
        ;

        companion object {
            fun fromRawValue(raw: String): HighlightGranularity? = entries.firstOrNull { it.rawValue == raw }
        }
    }

    /**
     * Which face the page is set in.
     *
     * A choice rather than a family name, because two of the three options
     * are not names the app knows in advance: a custom face comes from a file
     * the reader supplied, and the publisher's comes from inside the book.
     *
     * Encoded as one string so an unknown case decodes to a default rather
     * than failing the whole settings blob — the same reason [ReaderStyle]
     * decodes field by field.
     */
    @Serializable(with = Typeface.Serializer::class)
    sealed interface Typeface {
        /** Whatever the book itself asks for, where it ships a usable font. */
        data object Publisher : Typeface

        /** One of the faces the app ships. */
        data class Bundled(val name: String) : Typeface

        /** A face the reader installed or imported. */
        data class Custom(val name: String) : Typeface

        /** The persisted spelling, the Swift client's `raw`. */
        val raw: String
            get() = when (this) {
                Publisher -> "publisher"
                is Bundled -> "bundled:$name"
                is Custom -> "custom:$name"
            }

        /** The family name to ask for, where there is one in advance. */
        val familyName: String?
            get() = when (this) {
                Publisher -> null
                is Bundled -> name
                is Custom -> name
            }

        companion object {
            fun fromRaw(raw: String): Typeface = when {
                raw == "publisher" -> Publisher
                raw.startsWith("custom:") -> Custom(raw.substring(7))
                raw.startsWith("bundled:") -> Bundled(raw.substring(8))
                else -> Bundled(raw)
            }
        }

        object Serializer : KSerializer<Typeface> {
            override val descriptor: SerialDescriptor =
                PrimitiveSerialDescriptor("ReaderStyle.Typeface", PrimitiveKind.STRING)

            override fun serialize(encoder: Encoder, value: Typeface) = encoder.encodeString(value.raw)

            override fun deserialize(decoder: Decoder): Typeface = fromRaw(decoder.decodeString())
        }
    }

    enum class Justification(val rawValue: String, val title: String) {
        /** The book's own `text-align`, and ragged where it asks for nothing. */
        FOLLOW_BOOK("followBook", "Follow the book"),
        ALWAYS("always", "Always"),
        NEVER("never", "Never"),
        ;

        companion object {
            fun fromRawValue(raw: String): Justification? = entries.firstOrNull { it.rawValue == raw }
        }
    }

    enum class ProgressDisplay(val rawValue: String, val title: String) {
        BOOK("book", "Book percentage"),
        CHAPTER_PAGE("chapterPage", "Page in chapter"),
        ;

        companion object {
            fun fromRawValue(raw: String): ProgressDisplay? = entries.firstOrNull { it.rawValue == raw }
        }
    }

    /**
     * The face this book is actually set in, once the choice is resolved.
     *
     * `null` for [Typeface.Publisher] until the book has been opened and its
     * own font found — and permanently, for a book that ships none.
     */
    val resolvedFamily: String?
        get() = when (typeface) {
            Typeface.Publisher -> publisherFamily
            is Typeface.Bundled -> typeface.name
            is Typeface.Custom -> typeface.name
        }

    /**
     * The fill behind the narrated sentence, for the page colour in force.
     *
     * Resolved here rather than at each call site so the phone, the tablet and
     * the television all ask one question and get one answer — and so a page
     * colour with no highlighter of its own still lands on
     * [ReaderTheme.highlight] rather than on a second copy of that rule.
     */
    val highlightColor: Rgba get() = theme.highlightColor(highlighters[theme])

    /**
     * Moves a style still sitting on the old default face onto the new one.
     *
     * `readerStyle` is persisted as one blob whenever *any* reading setting
     * changes, so nearly every existing reader has `bundled:Newsreader` stored
     * whether they ever chose it or not, and simply changing [DEFAULT_FAMILY]
     * would have reached none of them. Run once, behind a flag.
     *
     * The cost, accepted deliberately: someone who really did pick Newsreader
     * is moved too, because nothing recorded the difference between a choice
     * and a default. They can pick it back, and it is still in the list.
     */
    fun replacingLegacyDefaultFace(): ReaderStyle {
        if (typeface != Typeface.Bundled(LEGACY_DEFAULT_FAMILY)) return this
        return copy(typeface = Typeface.Bundled(DEFAULT_FAMILY))
    }

    /** This style with one book's overrides laid over it. */
    fun applying(override: ReaderStyleOverride?): ReaderStyle {
        if (override == null) return this
        return copy(
            typeface = override.typeface ?: typeface,
            fontSize = override.fontSize ?: fontSize,
            lineSpacing = override.lineSpacing ?: lineSpacing,
            justification = override.justification ?: justification,
        )
    }

    /**
     * The override that would turn `this` into [other], for the fields a book
     * may set. Fields that already match are left unset, so a book only takes
     * ownership of what the reader actually changed.
     */
    fun difference(other: ReaderStyle): ReaderStyleOverride = ReaderStyleOverride(
        typeface = if (other.typeface == typeface) null else other.typeface,
        fontSize = if (other.fontSize == fontSize) null else other.fontSize,
        lineSpacing = if (other.lineSpacing == lineSpacing) null else other.lineSpacing,
        justification = if (other.justification == justification) null else other.justification,
    )

    companion object {
        /** The face the app sets a page in when nothing else is chosen. */
        const val DEFAULT_FAMILY = "Literata"

        /**
         * The face this used to be, kept so the one-time move off it can
         * recognise its own work. Still bundled, still offered, and still the
         * app's own UI serif — this is only about what a *book* is set in by
         * default.
         */
        const val LEGACY_DEFAULT_FAMILY = "Newsreader"

        /**
         * The text sizes a stored setting may hold. Wider than the Text size
         * stepper's 12...32 and the television's fixed 40, so no size anyone
         * chose is moved; narrow enough that a page always has a line on it.
         */
        val fontSizeRange: ClosedFloatingPointRange<Double> = 8.0..96.0

        /** The page margins a stored setting may hold. */
        val pageMarginRange: ClosedFloatingPointRange<Double> = 0.0..200.0

        /**
         * A stored length, bounded to [range], or `null` when there is none to
         * use — absent, of the wrong type, or not a finite number.
         */
        fun clampedLength(value: Double?, range: ClosedFloatingPointRange<Double>): Double? {
            if (value == null || !value.isFinite()) return null
            return minOf(maxOf(value, range.start), range.endInclusive)
        }
    }

    /**
     * Decoded field by field, with a default for anything absent.
     *
     * The generated decoder fails the whole blob when a field is missing or of
     * the wrong type, and the settings store falls back to a fresh
     * `ReaderStyle()` on failure — so adding a property the ordinary way would
     * silently reset the font, theme, margins and every read-along toggle of
     * everyone already running the app.
     */
    object Serializer : KSerializer<ReaderStyle> {
        override val descriptor: SerialDescriptor = buildClassSerialDescriptor("ReaderStyle")

        /**
         * Written out by hand because `publisherFamily` must not be persisted:
         * it is a property of the open book, and storing it would set the next
         * book in the last one's face.
         */
        override fun serialize(encoder: Encoder, value: ReaderStyle) {
            val json = encoder as? JsonEncoder ?: throw SerializationException("ReaderStyle is written as JSON")
            json.encodeJsonElement(
                buildJsonObject {
                    put("typeface", value.typeface.raw)
                    put("fontSize", value.fontSize)
                    put("lineSpacing", value.lineSpacing.rawValue)
                    put("theme", value.theme.rawValue)
                    put("justification", value.justification.rawValue)
                    // The key this replaced, written as well as the new one for
                    // a release. A build that predates the three-position
                    // setting reads only this, and without it a reader who
                    // moves back a build finds their justification silently
                    // gone. That build had a switch, so it can be told
                    // "justified" or "not", and both `never` and `followBook`
                    // are honestly "not" — following the book is a thing it
                    // cannot do. Coming back up reads `followBook` rather than
                    // the `never` someone may have chosen, which is the most an
                    // older writer can say.
                    put("justified", value.justification == Justification.ALWAYS)
                    put("pageMargin", value.pageMargin)
                    put("highlightGranularity", value.highlightGranularity.rawValue)
                    put("followNarration", value.followNarration)
                    put("turnPagesMidSentence", value.turnPagesMidSentence)
                    put("tapToPlay", value.tapToPlay)
                    put("progressDisplay", value.progressDisplay.rawValue)
                    // Written only when there is something to write, so a reader
                    // who has touched no highlighter leaves the same blob as
                    // before this existed.
                    if (value.highlighters.isNotEmpty()) {
                        put(
                            "highlighters",
                            JsonObject(
                                value.highlighters.entries.associate { (theme, choice) ->
                                    theme.rawValue to json.json.encodeToJsonElement(HighlighterChoice.Serializer, choice)
                                },
                            ),
                        )
                    }
                },
            )
        }

        override fun deserialize(decoder: Decoder): ReaderStyle {
            val json = decoder as? JsonDecoder ?: throw SerializationException("ReaderStyle is read from JSON")
            val container = json.decodeJsonElement() as? JsonObject
                ?: throw SerializationException("ReaderStyle is not an object")
            val fallback = ReaderStyle()
            // `typeface` replaced `fontFamily`. A blob written before it still
            // names a family, and that family is what the reader chose — so it
            // becomes a bundled typeface rather than being reset to the default.
            val typeface = container.string("typeface")?.let(Typeface::fromRaw)
                ?: container.string("fontFamily")?.let { Typeface.Bundled(it) }
                ?: fallback.typeface
            // `justification` replaced `justified`. A reader who deliberately
            // turned justification on keeps it everywhere; a stored `false` is
            // the untouched default of a control that only ever had two
            // positions, so it becomes "follow the book" rather than a
            // standing refusal.
            val justification = container.string("justification")?.let(Justification::fromRawValue)
                ?: container.boolean("justified")?.let { if (it) Justification.ALWAYS else Justification.FOLLOW_BOOK }
                ?: fallback.justification
            return ReaderStyle(
                typeface = typeface,
                // Every field forgiving: a value of the wrong type —
                // `"fontSize": "18"`, `"tapToPlay": "yes"` — costs that field
                // its default, not every preference the reader has. And the two
                // lengths are bounded, because nothing downstream is: a stored
                // `1e300` laid every page out at that size and trapped the Text
                // size stepper's label on every open of the sheet.
                fontSize = clampedLength(container.number("fontSize"), fontSizeRange) ?: fallback.fontSize,
                lineSpacing = container.string("lineSpacing")?.let(LineSpacing::fromRawValue) ?: fallback.lineSpacing,
                theme = container.string("theme")?.let(ReaderTheme::fromRawValue) ?: fallback.theme,
                justification = justification,
                pageMargin = clampedLength(container.number("pageMargin"), pageMarginRange) ?: fallback.pageMargin,
                highlightGranularity = container.string("highlightGranularity")
                    ?.let(HighlightGranularity::fromRawValue) ?: fallback.highlightGranularity,
                followNarration = container.boolean("followNarration") ?: fallback.followNarration,
                turnPagesMidSentence = container.boolean("turnPagesMidSentence") ?: fallback.turnPagesMidSentence,
                tapToPlay = container.boolean("tapToPlay") ?: fallback.tapToPlay,
                progressDisplay = container.string("progressDisplay")?.let(ProgressDisplay::fromRawValue)
                    ?: fallback.progressDisplay,
                highlighters = decodeHighlighters(json, container["highlighters"]),
                // Belongs to the book being read, not to the settings blob.
                publisherFamily = null,
            )
        }

        /**
         * Reads the highlighters one page colour at a time.
         *
         * Two refusals, both deliberate. A `highlighters` that is not an object
         * at all — a string, a number, a blob half-written by a crash — is no
         * highlighters, rather than a throw that resets every reading
         * preference the reader has. And a single unreadable choice — a preset
         * name a newer build introduced — costs *that* page colour its
         * highlighter and leaves the other three, and the font, and the
         * margins, exactly as they were.
         */
        private fun decodeHighlighters(json: JsonDecoder, element: JsonElement?): Map<ReaderTheme, HighlighterChoice> {
            val nested = element as? JsonObject ?: return emptyMap()
            val chosen = LinkedHashMap<ReaderTheme, HighlighterChoice>()
            for ((key, value) in nested) {
                val theme = ReaderTheme.fromRawValue(key) ?: continue
                val choice = try {
                    json.json.decodeFromJsonElement(HighlighterChoice.Serializer, value)
                } catch (_: SerializationException) {
                    continue
                } catch (_: IllegalArgumentException) {
                    continue
                }
                chosen[theme] = choice
            }
            return chosen
        }
    }
}

/**
 * A JSON string under [key], or `null` for anything else — absent, `null`, a
 * number, an object. `decodeIfPresent(String.self)` under `try?`.
 */
internal fun JsonObject.string(key: String): String? {
    val primitive = this[key] as? JsonPrimitive ?: return null
    return if (primitive.isString) primitive.content else null
}

/** A JSON number under [key]; a string that looks like one is not one, as `JSONDecoder` has it. */
internal fun JsonObject.number(key: String): Double? {
    val primitive = this[key] as? JsonPrimitive ?: return null
    if (primitive.isString) return null
    return primitive.doubleOrNull
}

/** A JSON `true` or `false` under [key]; neither `"yes"` nor `1` is one. */
internal fun JsonObject.boolean(key: String): Boolean? {
    val primitive = this[key] as? JsonPrimitive ?: return null
    if (primitive.isString) return null
    return primitive.booleanOrNull
}
