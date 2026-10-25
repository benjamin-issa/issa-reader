package com.benjaminissa.issareader.render.android

import com.benjaminissa.issareader.epub.EpubPackage
import com.benjaminissa.issareader.render.ReaderStyle
import com.benjaminissa.issareader.testing.Fixtures
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * A book set in its own face, and a reader's imported one: the two faces that
 * are not names the app knows in advance. The finding is `:epub`'s
 * `EpubFontResolver`; this is the registering and the setting of a page in it.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36])
class PublisherFaceTest {
    private fun book(name: String) = EpubPackage.open(Fixtures.epub("$name.epub"))

    @Test
    fun `a book's own face is registered under its family and sets the page`() {
        val fonts = ReaderFonts(RuntimeEnvironment.getApplication())
        val family = fonts.registerPublisherFace(book("embedded-font"))
        assertEquals("Publisher Serif", family)
        val style = ReaderStyle(typeface = ReaderStyle.Typeface.Publisher, publisherFamily = family)
        val face = fonts.bodyFace(style, italic = false, bold = false, scale = 1.0)
        assertEquals("Publisher Serif", face.family)
    }

    /** The text face, not the display face declared before it: the whole book in the drop-cap font is what a naive reader does. */
    @Test
    fun `the running text's face is the one registered`() {
        val fonts = ReaderFonts(RuntimeEnvironment.getApplication())
        assertEquals("Running Text", fonts.registerPublisherFace(book("two-fonts")))
    }

    /** A book that ships nothing usable is set in the app's default face, as one that ships nothing at all is. */
    @Test
    fun `an unusable or missing face is no face`() {
        val fonts = ReaderFonts(RuntimeEnvironment.getApplication())
        for (name in listOf("alice", "woff-font", "obfuscated-font")) {
            assertNull(name, fonts.registerPublisherFace(book(name)))
        }
        val style = ReaderStyle(typeface = ReaderStyle.Typeface.Publisher)
        assertEquals(ReaderStyle.DEFAULT_FAMILY, fonts.bodyFace(style, italic = true, bold = false, scale = 1.0).family)
    }

    /**
     * A reader's own face, from a file. With only an upright member, emphasis
     * in it is upright — never a synthesised oblique — and bold is the upright
     * too, which is the honest answer for a family that has none.
     */
    @Test
    fun `an imported face with one member sets every run in that member`() {
        val fonts = ReaderFonts(RuntimeEnvironment.getApplication())
        val bytes = book("embedded-font").archive.read("OEBPS/fonts/Body.ttf")
        fonts.register("My Face", regular = bytes)
        val style = ReaderStyle(typeface = ReaderStyle.Typeface.Custom("My Face"))
        val plain = fonts.bodyFace(style, italic = false, bold = false, scale = 1.0)
        val emphasis = fonts.bodyFace(style, italic = true, bold = true, scale = 1.0)
        assertEquals("My Face", plain.family)
        assertEquals(plain.member, emphasis.member)
        assertTrue(!emphasis.isItalic && !emphasis.isBold)
        assertTrue(fonts.hasFamily("my face"))
    }
}
