package com.benjaminissa.issareader.render.android

import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** What a page says when it is read aloud. Ported from `SpokenPageTests.swift`. */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36])
class SpokenPageTest {
    /**
     * An illustration is an object-replacement character, which no screen
     * reader can pronounce. Without its alt text a full-page plate is a page
     * with one silent glyph on it.
     */
    @Test
    fun `an illustration is spoken as its alternative text`() {
        val chapter = handBuilt(
            listOf(
                "Before. " to { this },
                "\uFFFC" to { copy(imageAlt = "Peter flying over London") },
                " After." to { this },
            ),
        )
        val layout = laidOut(chapter, 320.0, 200.0)
        val spoken = layout.spokenText(layout.pages.first())
        assertTrue(spoken, spoken.contains("Peter flying over London"))
        assertFalse(spoken.contains("\uFFFC"))
    }

    /** A book that gives no alt text still must not leave a silent gap in the middle of a sentence. */
    @Test
    fun `an illustration with no alt text is still announced`() {
        val layout = laidOut(handBuilt(listOf("Before. \uFFFC After." to { this })), 320.0, 200.0)
        val spoken = layout.spokenText(layout.pages.first())
        assertTrue(spoken.contains("Image."))
        assertFalse(spoken.contains("\uFFFC"))
    }

    /** The spoken page must not include a paragraph that began on an earlier one: a sighted reader is not looking at it. */
    @Test
    fun `a page speaks only what is painted on it`() {
        val body = (1..40).joinToString("\n\n") { "Sentence number $it of the chapter, long enough to wrap a line or two." }
        val layout = laidOut(handBuilt(listOf(body to { this })), 320.0, 200.0)
        assertTrue(layout.pages.size > 1)
        for (page in layout.pages) {
            val painted = layout.paintedCharacterRange(page)
            assertTrue(painted.location >= page.characterRange.location)
            assertTrue(painted.end <= page.characterRange.end + 1)
        }
        // Consecutive pages must not both speak the same opening words.
        val first = layout.spokenText(layout.pages[0])
        val second = layout.spokenText(layout.pages[1])
        assertTrue(first.isNotEmpty())
        assertTrue(second.isNotEmpty())
        assertNotEquals(first, second)
    }

    @Test
    fun `a page with nothing on it speaks nothing rather than crashing`() {
        val layout = laidOut(handBuilt(emptyList()), 320.0, 200.0)
        val page = layout.pages.firstOrNull() ?: return
        assertTrue(layout.spokenText(page).isEmpty())
    }

    /** A plate parsed from a book: its character and the line break after it are one alt-text stretch, spoken once. */
    @Test
    fun `a parsed plate is spoken once, by its alt text`() {
        val chapter = parse(
            "<html><body><p>Before.</p><img src=\"p.png\" alt=\"A map of the island\"/><p>After.</p></body></html>",
            loadImage = { com.benjaminissa.issareader.render.SizedArtwork(100.0, 60.0) },
        )
        val layout = laidOut(chapter, 320.0, 560.0)
        val spoken = layout.spokenText(layout.pages.first())
        assertTrue(spoken, spoken.contains("Image: A map of the island. "))
        assertTrue(spoken.indexOf("A map") == spoken.lastIndexOf("A map"))
    }
}
