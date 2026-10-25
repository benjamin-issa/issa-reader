package com.benjaminissa.issareader.render

import com.benjaminissa.issareader.core.IssaJson
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

private fun decodeStyle(json: String): ReaderStyle = IssaJson.decodeFromString(ReaderStyle.serializer(), json)
private fun encodeStyle(style: ReaderStyle): String = IssaJson.encodeToString(ReaderStyle.serializer(), style)
private fun encodedObject(style: ReaderStyle): JsonObject = IssaJson.parseToJsonElement(encodeStyle(style)).jsonObject

/**
 * Reader preferences survive a new field. Ported from
 * `ReaderStyleMigrationTests.swift`.
 *
 * Readers have set a font, a theme and margins. The settings store decodes the
 * stored blob and falls back to a fresh `ReaderStyle()` on any failure — so a
 * new field decoded the ordinary way would throw on every existing blob and
 * silently reset all of it. The blobs here are the Swift client's own shapes,
 * so a setting written by one client is read by the other.
 */
class ReaderStyleMigrationTest {
    /** A blob exactly as it was written before `progressDisplay` existed. */
    private val legacy = """
        {
          "fontFamily": "Newsreader",
          "fontSize": 22,
          "lineSpacing": "roomy",
          "theme": "night",
          "justified": true,
          "pageMargin": 32,
          "highlightGranularity": "word",
          "followNarration": false,
          "turnPagesMidSentence": true,
          "tapToPlay": false
        }
    """.trimIndent()

    @Test
    fun `a blob this build writes is still readable by the build before it`() {
        // A reader who moves back a build must not silently lose their
        // justification: the old build reads only `justified`, so this one
        // keeps writing it. `always` is the only case that build can express.
        fun legacyBool(justification: ReaderStyle.Justification): Boolean =
            encodedObject(ReaderStyle(justification = justification))["justified"]!!.jsonPrimitive.boolean
        assertEquals(true, legacyBool(ReaderStyle.Justification.ALWAYS))
        assertEquals(false, legacyBool(ReaderStyle.Justification.NEVER))
        assertEquals(false, legacyBool(ReaderStyle.Justification.FOLLOW_BOOK))

        // And the new key is still there, so this build round-trips exactly.
        val restored = decodeStyle(encodeStyle(ReaderStyle(justification = ReaderStyle.Justification.NEVER)))
        assertEquals(ReaderStyle.Justification.NEVER, restored.justification)
    }

    @Test
    fun `a blob saved before the new field still decodes, keeping every setting`() {
        val style = decodeStyle(legacy)
        assertEquals(22.0, style.fontSize, 0.0)
        assertEquals(ReaderTheme.NIGHT, style.theme)
        assertEquals(ReaderStyle.Justification.ALWAYS, style.justification)
        assertEquals(32.0, style.pageMargin, 0.0)
        assertEquals(ReaderStyle.LineSpacing.ROOMY, style.lineSpacing)
        assertEquals(ReaderStyle.HighlightGranularity.WORD, style.highlightGranularity)
        assertFalse(style.followNarration)
        assertTrue(style.turnPagesMidSentence)
        assertFalse(style.tapToPlay)
        // And the new fields take their defaults rather than failing the decode.
        assertEquals(ReaderStyle.ProgressDisplay.BOOK, style.progressDisplay)
        assertEquals(emptyMap<ReaderTheme, HighlighterChoice>(), style.highlighters)
    }

    /**
     * Five fields were read with a bare `try` on the Swift side, so one value
     * of the wrong type threw the whole blob away and the store reset every
     * preference.
     */
    @Test
    fun `a field of the wrong type costs that field, not the blob`() {
        for ((key, damaged) in listOf(
            "fontSize" to "\"18\"",
            "pageMargin" to "\"wide\"",
            "followNarration" to "\"yes\"",
            "turnPagesMidSentence" to "\"no\"",
            "tapToPlay" to "{}",
        )) {
            // Every other field set away from its default, so a reset shows.
            val fields = listOf(
                "\"theme\": \"night\"", "\"lineSpacing\": \"roomy\"", "\"fontSize\": 22",
                "\"pageMargin\": 32", "\"followNarration\": false",
                "\"turnPagesMidSentence\": true", "\"tapToPlay\": false",
            ).filter { !it.startsWith("\"$key\"") } + "\"$key\": $damaged"
            val style = decodeStyle("{" + fields.joinToString(", ") + "}")
            assertEquals(key, ReaderTheme.NIGHT, style.theme)
            assertEquals(key, ReaderStyle.LineSpacing.ROOMY, style.lineSpacing)
            val fallback = ReaderStyle()
            assertEquals(key, if (key == "fontSize") fallback.fontSize else 22.0, style.fontSize, 0.0)
            assertEquals(key, if (key == "pageMargin") fallback.pageMargin else 32.0, style.pageMargin, 0.0)
            assertEquals(key, if (key == "followNarration") fallback.followNarration else false, style.followNarration)
            assertEquals(key, if (key == "turnPagesMidSentence") fallback.turnPagesMidSentence else true, style.turnPagesMidSentence)
            assertEquals(key, if (key == "tapToPlay") fallback.tapToPlay else false, style.tapToPlay)
        }
    }

    /**
     * Nothing downstream bounds these: the page lays out at whatever size it
     * is given, and the Text size stepper's label does `Int(size)`, which traps
     * on the Swift side on anything past `Int.max`.
     */
    @Test
    fun `an absurd size or margin is brought into range`() {
        val huge = decodeStyle("""{"fontSize": 1e300, "pageMargin": 1e300}""")
        assertEquals(ReaderStyle.fontSizeRange.endInclusive, huge.fontSize, 0.0)
        assertEquals(ReaderStyle.pageMarginRange.endInclusive, huge.pageMargin, 0.0)
        val tiny = decodeStyle("""{"fontSize": -4, "pageMargin": -50}""")
        assertEquals(ReaderStyle.fontSizeRange.start, tiny.fontSize, 0.0)
        assertEquals(0.0, tiny.pageMargin, 0.0)
        // Every size the app can set is inside the range and left exactly.
        for (size in listOf(12.0, 18.0, 32.0, 40.0)) {
            assertEquals(size, ReaderStyle.clampedLength(size, ReaderStyle.fontSizeRange)!!, 0.0)
        }
        assertNull(ReaderStyle.clampedLength(Double.POSITIVE_INFINITY, ReaderStyle.fontSizeRange))
        assertNull(ReaderStyle.clampedLength(Double.NaN, ReaderStyle.fontSizeRange))
    }

    @Test
    fun `an empty object decodes to the defaults rather than throwing`() {
        assertEquals(ReaderStyle(), decodeStyle("{}"))
    }

    @Test
    fun `the new field round-trips when it is present`() {
        val style = ReaderStyle(progressDisplay = ReaderStyle.ProgressDisplay.CHAPTER_PAGE, fontSize = 19.0)
        val decoded = decodeStyle(encodeStyle(style))
        assertEquals(ReaderStyle.ProgressDisplay.CHAPTER_PAGE, decoded.progressDisplay)
        assertEquals(19.0, decoded.fontSize, 0.0)
        assertEquals(style, decoded)
    }

    /** An unknown value must not throw either — a blob written by a newer build should degrade, not wipe the reader's settings. */
    @Test
    fun `an unrecognised value falls back instead of failing the whole blob`() {
        val style = decodeStyle("""{"fontSize": 21, "progressDisplay": "somethingNew"}""")
        assertEquals(21.0, style.fontSize, 0.0)
        assertEquals(ReaderStyle.ProgressDisplay.BOOK, style.progressDisplay)
    }

    // A highlighter per page colour

    @Test
    fun `the highlighters round-trip, presets and mixed colours alike`() {
        val tint = HighlightTint(red = 0.2, green = 0.45, blue = 0.8, alpha = 0.5)
        val style = ReaderStyle(
            highlighters = mapOf(
                ReaderTheme.PAPER to HighlighterChoice.Preset(HighlighterPreset.MOSS),
                ReaderTheme.NIGHT to HighlighterChoice.Custom(tint),
            ),
        )
        val decoded = decodeStyle(encodeStyle(style))
        assertEquals(style.highlighters, decoded.highlighters)
        assertEquals(style, decoded)
        // Keyed by the page colour's own name, so the blob can be read — and
        // decoded one entry at a time, which is what the next test needs.
        assertEquals(listOf("night", "paper"), encodedObject(style)["highlighters"]!!.jsonObject.keys.sorted())
    }

    /**
     * The whole point of decoding this field one page colour at a time: a
     * preset name a newer build introduced must cost that page colour its
     * highlighter, and nothing else in the reader's settings.
     */
    @Test
    fun `one unreadable highlighter costs one page colour, not the blob`() {
        val style = decodeStyle(
            """
            {
              "fontSize": 23,
              "theme": "slate",
              "justified": true,
              "highlighters": {
                "paper": {"preset": "unicorn"},
                "night": {"preset": "sage"}
              }
            }
            """.trimIndent(),
        )
        assertEquals(mapOf(ReaderTheme.NIGHT to HighlighterChoice.Preset(HighlighterPreset.SAGE)), style.highlighters)
        assertEquals(23.0, style.fontSize, 0.0)
        assertEquals(ReaderTheme.SLATE, style.theme)
        assertEquals(ReaderStyle.Justification.ALWAYS, style.justification)
    }

    /** And a `highlighters` that is not an object at all must not reset the font, the theme and the margins on the way past. */
    @Test
    fun `a highlighters field of the wrong shape decodes to none`() {
        val style = decodeStyle("""{"fontSize": 20, "highlighters": "garbage"}""")
        assertEquals(emptyMap<ReaderTheme, HighlighterChoice>(), style.highlighters)
        assertEquals(20.0, style.fontSize, 0.0)
    }

    @Test
    fun `nothing chosen is written as nothing, so an untouched blob is unchanged`() {
        assertNull(encodedObject(ReaderStyle())["highlighters"])
    }

    // Which colour the page paints

    @Test
    fun `the highlight follows the page colour in force`() {
        val highlighters = mapOf(
            ReaderTheme.PAPER to HighlighterChoice.Preset(HighlighterPreset.PLUM),
            ReaderTheme.NIGHT to HighlighterChoice.Preset(HighlighterPreset.IRIS),
        )
        val style = ReaderStyle(highlighters = highlighters)
        assertEquals(
            ReaderTheme.PAPER.highlightColor(HighlighterChoice.Preset(HighlighterPreset.PLUM)),
            style.copy(theme = ReaderTheme.PAPER).highlightColor,
        )
        assertEquals(
            ReaderTheme.NIGHT.highlightColor(HighlighterChoice.Preset(HighlighterPreset.IRIS)),
            style.copy(theme = ReaderTheme.NIGHT).highlightColor,
        )
        // Sepia was never given one, so it keeps its own default.
        assertEquals(ReaderTheme.SEPIA.highlight, style.copy(theme = ReaderTheme.SEPIA).highlightColor)
    }

    @Test
    fun `a page colour with no highlighter of its own falls back to the theme's`() {
        for (theme in ReaderTheme.entries) assertEquals(theme.highlight, ReaderStyle(theme = theme).highlightColor)
    }

    /** A book's own overrides are about type, not colour, so the highlighter is a global value that passes straight through both directions. */
    @Test
    fun `a per-book override neither carries nor loses a highlighter`() {
        val global = ReaderStyle(highlighters = mapOf(ReaderTheme.PAPER to HighlighterChoice.Preset(HighlighterPreset.ROSE)))
        val edited = global.copy(fontSize = 26.0)
        val difference = global.difference(edited)
        assertEquals(26.0, difference.fontSize!!, 0.0)
        assertEquals(global.highlighters, global.applying(difference).highlighters)
        assertEquals(26.0, global.applying(difference).fontSize, 0.0)
    }

    /** The blob's keys and their spellings are the Swift client's, so either can read the other's. */
    @Test
    fun `the blob is written in the Swift client's shape`() {
        val written = encodedObject(ReaderStyle())
        assertEquals(
            setOf(
                "typeface", "fontSize", "lineSpacing", "theme", "justification", "justified", "pageMargin",
                "highlightGranularity", "followNarration", "turnPagesMidSentence", "tapToPlay", "progressDisplay",
            ),
            written.keys,
        )
        assertEquals("bundled:Literata", written["typeface"]!!.jsonPrimitive.content)
        assertEquals("followBook", written["justification"]!!.jsonPrimitive.content)
        assertEquals("paper", written["theme"]!!.jsonPrimitive.content)
        // A blob as the Swift `JSONEncoder` writes one, whole numbers and all.
        val swift = """{"typeface":"custom:My Face","fontSize":21,"lineSpacing":"tight","theme":"sepia",""" +
            """"justification":"never","justified":false,"pageMargin":16,"highlightGranularity":"line",""" +
            """"followNarration":true,"turnPagesMidSentence":false,"tapToPlay":true,"progressDisplay":"chapterPage"}"""
        assertEquals(
            ReaderStyle(
                typeface = ReaderStyle.Typeface.Custom("My Face"), fontSize = 21.0, lineSpacing = ReaderStyle.LineSpacing.TIGHT,
                theme = ReaderTheme.SEPIA, justification = ReaderStyle.Justification.NEVER, pageMargin = 16.0,
                highlightGranularity = ReaderStyle.HighlightGranularity.LINE,
                progressDisplay = ReaderStyle.ProgressDisplay.CHAPTER_PAGE,
            ),
            decodeStyle(swift),
        )
    }
}

/**
 * Per-book typography, stored as a departure from the reading settings.
 * Ported from `ReaderStyleOverrideTests.swift`.
 *
 * The sparseness is the whole design: a book that changed its face must still
 * follow a later change to the global line spacing, which storing a resolved
 * style would silently freeze.
 */
class ReaderStyleOverrideTest {
    private fun decode(json: String): ReaderStyleOverride = IssaJson.decodeFromString(ReaderStyleOverride.serializer(), json)

    @Test
    fun `a book with no override reads exactly as the defaults`() {
        val defaults = ReaderStyle()
        assertEquals(defaults, defaults.applying(null))
        assertEquals(defaults, defaults.applying(ReaderStyleOverride()))
    }

    @Test
    fun `an override changes only what it names`() {
        val defaults = ReaderStyle(typeface = ReaderStyle.Typeface.Bundled("Newsreader"), fontSize = 18.0)
        val resolved = defaults.applying(ReaderStyleOverride(fontSize = 24.0))
        assertEquals(24.0, resolved.fontSize, 0.0)
        assertEquals(ReaderStyle.Typeface.Bundled("Newsreader"), resolved.typeface)
        assertEquals(defaults.lineSpacing, resolved.lineSpacing)
        assertEquals(defaults.justification, resolved.justification)
    }

    /**
     * The reason for storing a difference rather than a style. The reader sets
     * one book in a bigger size, then later changes their default line
     * spacing — and that book must follow.
     */
    @Test
    fun `a later change to the defaults still reaches an overridden book`() {
        val override = ReaderStyleOverride(fontSize = 24.0)
        val defaults = ReaderStyle(fontSize = 18.0, lineSpacing = ReaderStyle.LineSpacing.NORMAL)
        assertEquals(ReaderStyle.LineSpacing.NORMAL, defaults.applying(override).lineSpacing)
        val changed = defaults.copy(lineSpacing = ReaderStyle.LineSpacing.ROOMY)
        assertEquals(ReaderStyle.LineSpacing.ROOMY, changed.applying(override).lineSpacing)
        assertEquals("the book keeps what it set", 24.0, changed.applying(override).fontSize, 0.0)
    }

    @Test
    fun `a difference records only the fields that actually differ`() {
        val defaults = ReaderStyle(typeface = ReaderStyle.Typeface.Bundled("Newsreader"), fontSize = 18.0)
        val difference = defaults.difference(defaults.copy(fontSize = 22.0))
        assertEquals(22.0, difference.fontSize!!, 0.0)
        assertNull(difference.typeface)
        assertEquals(1, difference.count)
    }

    @Test
    fun `editing a book back to the defaults leaves nothing behind`() {
        assertTrue(ReaderStyle().difference(ReaderStyle()).isEmpty)
    }

    @Test
    fun `a round trip through storage keeps the override intact`() {
        val override = ReaderStyleOverride(
            typeface = ReaderStyle.Typeface.Custom("Some Imported Face"), fontSize = 21.0,
            justification = ReaderStyle.Justification.ALWAYS,
        )
        val encoded = IssaJson.encodeToString(ReaderStyleOverride.serializer(), override)
        assertEquals(override, decode(encoded))
    }

    /** The per-book switch before it had three positions. A book set ragged was a deliberate act, so it stays ragged rather than following the book. */
    @Test
    fun `a stored justified switch becomes the matching justification`() {
        assertEquals(ReaderStyle.Justification.NEVER, decode("""{"justified": false}""").justification)
        assertEquals(ReaderStyle.Justification.ALWAYS, decode("""{"justified": true}""").justification)
        assertEquals(19.0, decode("""{"justified": false, "fontSize": 19}""").fontSize!!, 0.0)
        assertNull(decode("""{"fontSize": 19}""").justification)
    }

    @Test
    fun `an absurd per-book size is brought into range, not trusted`() {
        assertEquals(ReaderStyle.fontSizeRange.endInclusive, decode("""{"fontSize": 1e300}""").fontSize!!, 0.0)
        assertEquals(21.0, decode("""{"fontSize": 21}""").fontSize!!, 0.0)
    }

    /**
     * A reader who moves back a build must not lose a book's justification:
     * the older build reads only `justified`, and the first time it saves any
     * book's typography it writes the whole map back without the newer key.
     * Ported from `ReaderStyleOverrideDowngradeTests`, with 1.1.1's struct as
     * the shape it reads: the four keys it knew, `justified` a switch.
     */
    @Test
    fun `the map this build writes round-trips through 1_1_1's shape`() {
        val written = mapOf(
            "ragged" to ReaderStyleOverride(justification = ReaderStyle.Justification.NEVER),
            "justified" to ReaderStyleOverride(justification = ReaderStyle.Justification.ALWAYS),
            "follows" to ReaderStyleOverride(fontSize = 20.0, justification = ReaderStyle.Justification.FOLLOW_BOOK),
            "size-and-justified" to ReaderStyleOverride(fontSize = 21.0, justification = ReaderStyle.Justification.ALWAYS),
            "face" to ReaderStyleOverride(typeface = ReaderStyle.Typeface.Custom("Some Face")),
        )
        val serializer = MapSerializer(String.serializer(), ReaderStyleOverride.serializer())
        val blob = IssaJson.parseToJsonElement(IssaJson.encodeToString(serializer, written)).jsonObject

        // What 1.1.1 sees: a switch, set or unset.
        fun justified(key: String): Boolean? = blob[key]!!.jsonObject["justified"]?.jsonPrimitive?.boolean
        assertEquals(false, justified("ragged"))
        assertEquals(true, justified("justified"))
        assertNull("following the book is not a thing it can say", justified("follows"))
        assertEquals(true, justified("size-and-justified"))
        assertNull(justified("face"))

        // 1.1.1 saves the map — any book's change does — keeping only the keys
        // it knows, and this build reads it back: the newer key is gone, and
        // the switch carries it.
        val known = setOf("typeface", "fontSize", "lineSpacing", "justified")
        val rewritten = JsonObject(blob.mapValues { (_, value) -> JsonObject(value.jsonObject.filterKeys { it in known }) })
        val back = IssaJson.decodeFromJsonElement(serializer, rewritten)
        assertEquals(ReaderStyle.Justification.NEVER, back["ragged"]?.justification)
        assertEquals(ReaderStyle.Justification.ALWAYS, back["justified"]?.justification)
        assertEquals(written["size-and-justified"], back["size-and-justified"])
        assertEquals(written["face"], back["face"])
        assertEquals(20.0, back["follows"]?.fontSize!!, 0.0)
    }

    @Test
    fun `this build writes the switch only where it means something`() {
        fun legacy(justification: ReaderStyle.Justification?): Boolean? {
            val encoded = IssaJson.encodeToString(
                ReaderStyleOverride.serializer(), ReaderStyleOverride(fontSize = 20.0, justification = justification),
            )
            return IssaJson.parseToJsonElement(encoded).jsonObject["justified"]?.jsonPrimitive?.boolean
        }
        assertEquals(true, legacy(ReaderStyle.Justification.ALWAYS))
        assertEquals(false, legacy(ReaderStyle.Justification.NEVER))
        assertNull(legacy(ReaderStyle.Justification.FOLLOW_BOOK))
        assertNull(legacy(null))
    }
}

/**
 * Choosing a typeface. Ported from `ReaderStyleOverrideTests.swift`'s
 * `TypefaceTests`; the bundled face's resolution is `:render-android`'s
 * `BundledFaceTest`.
 *
 * `typeface` replaced `fontFamily`, and the settings blob on a reader's device
 * still names a family.
 */
class TypefaceTest {
    @Test
    fun `a settings blob written before typeface keeps the face it named`() {
        val style = decodeStyle("""{"fontFamily":"Public Sans","fontSize":21,"justified":true}""")
        assertEquals(ReaderStyle.Typeface.Bundled("Public Sans"), style.typeface)
        assertEquals("the rest of the blob must survive too", 21.0, style.fontSize, 0.0)
        assertEquals(ReaderStyle.Justification.ALWAYS, style.justification)
    }

    @Test
    fun `a blob naming neither falls back to the app's own face`() {
        assertEquals(ReaderStyle.Typeface.Bundled(ReaderStyle.DEFAULT_FAMILY), decodeStyle("{}").typeface)
    }

    @Test
    fun `every case survives a round trip`() {
        for (typeface in listOf(
            ReaderStyle.Typeface.Publisher,
            ReaderStyle.Typeface.Bundled("Newsreader"),
            ReaderStyle.Typeface.Custom("A Face With Spaces"),
        )) {
            assertEquals(typeface, decodeStyle(encodeStyle(ReaderStyle(typeface = typeface))).typeface)
        }
    }

    /** A face named "publisher", or one whose name contains a colon, must not be confused with the tag that encodes the case. */
    @Test
    fun `an awkward family name is not mistaken for a case`() {
        for (name in listOf("publisher", "custom:thing", "bundled:other")) {
            val typeface = ReaderStyle.Typeface.Custom(name)
            assertEquals(typeface, decodeStyle(encodeStyle(ReaderStyle(typeface = typeface))).typeface)
        }
    }

    /** The publisher's face is a property of the book, not of the settings. Persisting it would set the next book in the last one's font. */
    @Test
    fun `the publisher's family is never written to settings`() {
        val style = ReaderStyle(typeface = ReaderStyle.Typeface.Publisher, publisherFamily = "Some Book Face")
        val encoded = encodeStyle(style)
        assertFalse("Some Book Face" in encoded)
        assertNull(decodeStyle(encoded).publisherFamily)
    }

    @Test
    fun `a book with no usable face has no family until one is found`() {
        val style = ReaderStyle(typeface = ReaderStyle.Typeface.Publisher)
        assertNull(style.resolvedFamily)
        assertEquals("Found Face", style.copy(publisherFamily = "Found Face").resolvedFamily)
        assertEquals("Lexend", ReaderStyle(typeface = ReaderStyle.Typeface.Bundled("Lexend")).resolvedFamily)
    }
}

/**
 * Moving existing readers onto the new default face. Ported from
 * `DefaultFaceMigrationTests.swift`.
 *
 * The whole style is persisted as one blob the first time any reading
 * preference changes, so nearly every existing reader has the old default
 * written down whether they picked it or not — and changing the default alone
 * would have reached none of them. This is the one-time move that does.
 */
class DefaultFaceMigrationTest {
    private val legacyFace = ReaderStyle.Typeface.Bundled(ReaderStyle.LEGACY_DEFAULT_FAMILY)

    @Test
    fun `a style still on the old default moves to the new one`() {
        assertEquals(
            ReaderStyle.Typeface.Bundled(ReaderStyle.DEFAULT_FAMILY),
            ReaderStyle(typeface = legacyFace).replacingLegacyDefaultFace().typeface,
        )
    }

    /** Everything else is a choice somebody made, and a migration that reads "replace the face" rather than "replace *that* face" would erase all of them. */
    @Test
    fun `nothing else is touched`() {
        for (typeface in listOf(
            ReaderStyle.Typeface.Publisher,
            ReaderStyle.Typeface.Bundled("Public Sans"),
            ReaderStyle.Typeface.Bundled("OpenDyslexic"),
            ReaderStyle.Typeface.Bundled(ReaderStyle.DEFAULT_FAMILY),
            ReaderStyle.Typeface.Custom("A Face The Reader Imported"),
        )) {
            assertEquals(typeface, ReaderStyle(typeface = typeface).replacingLegacyDefaultFace().typeface)
        }
    }

    @Test
    fun `only the face moves — every other setting is carried through`() {
        val moved = ReaderStyle(
            typeface = legacyFace, fontSize = 27.0, lineSpacing = ReaderStyle.LineSpacing.ROOMY,
            theme = ReaderTheme.NIGHT, justification = ReaderStyle.Justification.ALWAYS,
        ).replacingLegacyDefaultFace()
        assertEquals(27.0, moved.fontSize, 0.0)
        assertEquals(ReaderStyle.LineSpacing.ROOMY, moved.lineSpacing)
        assertEquals(ReaderTheme.NIGHT, moved.theme)
        assertEquals(ReaderStyle.Justification.ALWAYS, moved.justification)
    }

    /** A migration that is not idempotent is a migration that cannot be re-run after a bug, which is when you most want to. */
    @Test
    fun `running it twice changes nothing the second time`() {
        val once = ReaderStyle(typeface = legacyFace).replacingLegacyDefaultFace()
        assertEquals(once, once.replacingLegacyDefaultFace())
    }

    @Test
    fun `a book that took the old default as its own is moved too`() {
        assertEquals(
            ReaderStyle.Typeface.Bundled(ReaderStyle.DEFAULT_FAMILY),
            ReaderStyleOverride(typeface = legacyFace).replacingLegacyDefaultFace().typeface,
        )
    }

    /**
     * A book that departs only in size must not acquire a face it never had:
     * setting `typeface` on it would freeze the global face for that book and
     * stop it following a later change.
     */
    @Test
    fun `a book that never chose a face does not gain one`() {
        val moved = ReaderStyleOverride(fontSize = 24.0).replacingLegacyDefaultFace()
        assertNull(moved.typeface)
        assertEquals(24.0, moved.fontSize!!, 0.0)
    }
}
