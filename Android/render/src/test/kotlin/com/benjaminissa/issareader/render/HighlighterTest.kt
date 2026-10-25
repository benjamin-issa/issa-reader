package com.benjaminissa.issareader.render

import com.benjaminissa.issareader.core.IssaJson
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/**
 * The highlighter tables, and the promise that choosing nothing changes
 * nothing. Ported from IssaUI's `HighlighterTests.swift` (the types live in
 * `:render` on Android; the Compose side is in `:ui`).
 */
class HighlighterTest {
    @Test
    fun `each page colour offers four swatches, and the light and dark grounds share nothing`() {
        assertEquals(
            listOf(HighlighterPreset.TANGERINE, HighlighterPreset.MOSS, HighlighterPreset.ROSE, HighlighterPreset.PLUM),
            ReaderTheme.PAPER.highlighterPresets,
        )
        assertEquals(ReaderTheme.PAPER.highlighterPresets, ReaderTheme.SEPIA.highlighterPresets)
        assertEquals(
            listOf(HighlighterPreset.AMBER, HighlighterPreset.SAGE, HighlighterPreset.BLUSH, HighlighterPreset.IRIS),
            ReaderTheme.NIGHT.highlighterPresets,
        )
        assertEquals(ReaderTheme.NIGHT.highlighterPresets, ReaderTheme.SLATE.highlighterPresets)
        assertTrue(ReaderTheme.PAPER.highlighterPresets.intersect(ReaderTheme.NIGHT.highlighterPresets.toSet()).isEmpty())
        val offered = ReaderTheme.entries.flatMap { it.highlighterPresets }.toSet()
        assertEquals(HighlighterPreset.entries.toSet(), offered)
    }

    @Test
    fun `the swatches are the colours the design named`() {
        val expected = mapOf(
            HighlighterPreset.TANGERINE to 0xE2853A, HighlighterPreset.MOSS to 0x7C8A5A,
            HighlighterPreset.ROSE to 0xC46A6A, HighlighterPreset.PLUM to 0x8A6AA8,
            HighlighterPreset.AMBER to 0xEE9B57, HighlighterPreset.SAGE to 0x9DAE74,
            HighlighterPreset.BLUSH to 0xD98C8C, HighlighterPreset.IRIS to 0xA88AC6,
        )
        for ((preset, hex) in expected) assertEquals(preset.name, hex, preset.hex)
    }

    @Test
    fun `every swatch has a name to read out`() {
        for (preset in HighlighterPreset.entries) {
            assertTrue(preset.title.isNotEmpty() && preset.title.first().isUpperCase())
        }
    }

    @Test
    fun `the default is the design's, per ground`() {
        assertEquals(0xE2853A, ReaderTheme.PAPER.defaultHighlighter.hex)
        assertEquals(0xE2853A, ReaderTheme.SEPIA.defaultHighlighter.hex)
        assertEquals(0xEE9B57, ReaderTheme.NIGHT.defaultHighlighter.hex)
        assertEquals(0xEE9B57, ReaderTheme.SLATE.defaultHighlighter.hex)
        for (theme in ReaderTheme.entries) assertEquals(theme.defaultHighlighter, theme.highlighterPresets.first())
    }

    @Test
    fun `choosing nothing resolves to exactly the page's own highlight`() {
        for (theme in ReaderTheme.entries) {
            assertEquals(theme.highlight, theme.highlightColor(HighlighterChoice.Preset(theme.defaultHighlighter)))
            assertEquals(theme.highlight, theme.highlightColor(null))
        }
    }

    @Test
    fun `a preset is laid down at the ground's own strength`() {
        for (theme in ReaderTheme.entries) {
            val expected = if (theme.isDark) 0.30 else 0.22
            assertEquals(expected, theme.highlightAlpha, 0.0)
            for (preset in theme.highlighterPresets) {
                val color = theme.highlightColor(HighlighterChoice.Preset(preset))
                assertTrue(abs(color.alpha - expected) < 0.005)
                assertTrue(abs(color.red - ((preset.hex shr 16) and 0xFF) / 255.0) < 0.005)
                assertTrue(abs(color.green - ((preset.hex shr 8) and 0xFF) / 255.0) < 0.005)
                assertTrue(abs(color.blue - (preset.hex and 0xFF) / 255.0) < 0.005)
            }
        }
    }

    @Test
    fun `a custom colour keeps its own opacity`() {
        val tint = HighlightTint(red = 0.1, green = 0.6, blue = 0.9, alpha = 0.55)
        for (theme in ReaderTheme.entries) {
            assertEquals(Rgba(0.1, 0.6, 0.9, 0.55), theme.highlightColor(HighlighterChoice.Custom(tint)))
        }
    }

    @Test
    fun `a tint clamps whatever it is handed`() {
        val over = HighlightTint(red = 4.0, green = -1.0, blue = 0.5, alpha = 99.0)
        assertEquals(listOf(1.0, 0.0, 0.5, 1.0), listOf(over.red, over.green, over.blue, over.alpha))
        val bad = HighlightTint(Double.NaN, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY, Double.NaN)
        assertEquals(listOf(0.0, 0.0, 0.0, 0.0), listOf(bad.red, bad.green, bad.blue, bad.alpha))
    }

    @Test
    fun `a tint round-trips`() {
        val tint = HighlightTint(0.25, 0.5, 0.75, 0.4)
        assertEquals(tint, IssaJson.decodeFromString(HighlightTint.Serializer, IssaJson.encodeToString(HighlightTint.Serializer, tint)))
    }

    @Test
    fun `a blob carrying nonsense decodes to a colour that can be drawn`() {
        val tint = IssaJson.decodeFromString(HighlightTint.Serializer, """{"red":"nan","green":-3,"blue":1.5,"alpha":0.4}""")
        assertEquals(0.0, tint.red, 0.0)
        assertEquals(0.0, tint.green, 0.0)
        assertEquals(1.0, tint.blue, 0.0)
        assertEquals(0.4, tint.alpha, 0.0)
    }

    @Test
    fun `and so does one nested in the choice that carries it`() {
        val choice = IssaJson.decodeFromString(HighlighterChoice.Serializer, """{"custom":{"red":7,"green":0.5,"blue":"-inf","alpha":2}}""")
        val tint = (choice as HighlighterChoice.Custom).tint
        assertEquals(listOf(1.0, 0.5, 0.0, 1.0), listOf(tint.red, tint.green, tint.blue, tint.alpha))
    }

    @Test
    fun `a preset is written by name`() {
        val text = IssaJson.encodeToString(HighlighterChoice.Serializer, HighlighterChoice.Preset(HighlighterPreset.MOSS))
        val obj = IssaJson.parseToJsonElement(text).jsonObject
        assertEquals("moss", obj["preset"]!!.jsonPrimitive.content)
        assertEquals(1, obj.size)
        assertEquals(HighlighterChoice.Preset(HighlighterPreset.MOSS), IssaJson.decodeFromString(HighlighterChoice.Serializer, text))
    }

    @Test
    fun `a custom colour is written as its four components`() {
        val tint = HighlightTint(0.1, 0.2, 0.3, 0.4)
        val text = IssaJson.encodeToString(HighlighterChoice.Serializer, HighlighterChoice.Custom(tint))
        val obj = IssaJson.parseToJsonElement(text).jsonObject
        val custom = obj["custom"] as JsonObject
        assertEquals(1, obj.size)
        assertEquals(4, custom.size)
        assertEquals(0.1, custom["red"]!!.jsonPrimitive.double, 0.0)
        assertEquals(0.4, custom["alpha"]!!.jsonPrimitive.double, 0.0)
        assertEquals(HighlighterChoice.Custom(tint), IssaJson.decodeFromString(HighlighterChoice.Serializer, text))
    }

    @Test
    fun `every preset survives the round trip`() {
        for (preset in HighlighterPreset.entries) {
            val text = IssaJson.encodeToString(HighlighterChoice.Serializer, HighlighterChoice.Preset(preset))
            assertEquals(HighlighterChoice.Preset(preset), IssaJson.decodeFromString(HighlighterChoice.Serializer, text))
        }
    }

    @Test(expected = SerializationException::class)
    fun `a preset name this build does not know throws`() {
        IssaJson.decodeFromString(HighlighterChoice.Serializer, """{"preset":"unicorn"}""")
    }

    @Test(expected = SerializationException::class)
    fun `a choice that is neither shape throws`() {
        IssaJson.decodeFromString(HighlighterChoice.Serializer, "{}")
    }
}
