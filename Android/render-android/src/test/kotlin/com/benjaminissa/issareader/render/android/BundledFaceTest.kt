package com.benjaminissa.issareader.render.android

import android.graphics.Paint
import com.benjaminissa.issareader.render.ReaderStyle
import com.benjaminissa.issareader.ui.IssaFonts
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Every advertised face must actually be there, under the name we advertise.
 * Ported from `BundledFaceTests.swift`.
 *
 * `BundledFace.family` is also the string persisted in
 * `ReaderStyle.Typeface.Bundled` — so a typo is not a cosmetic problem. It
 * resolves to nothing, the body face falls silently through to the default,
 * and the picker offers a choice that does nothing at all. The files are
 * `PublicSans.ttf` and `SourceSerif4-Regular.ttf` while the families are
 * "Public Sans" and "Source Serif 4", so this is a live trap.
 *
 * Where the Swift suite compares CoreText font names, this compares the member
 * resolved *and* what it draws: a real bold sets a sample wider than the
 * regular, and a real italic sets it differently from the upright.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36])
class BundledFaceTest {
    private val sample = "Hamburgefonstiv quick brown fox"

    private fun width(face: ResolvedFace): Float =
        Paint().apply { typeface = face.typeface; textSize = 40f }.measureText(sample)

    @Test
    fun `every advertised face resolves under the name it is advertised by`() {
        for (face in IssaFonts.allFaces) {
            val resolved = testFonts.upright(face.family, 18.0)
            assertNotNull("nothing registered under the family \"${face.family}\"", resolved)
            assertEquals(face.family, resolved!!.family)
            assertTrue("${face.family} measures nothing", width(resolved) > 0)
        }
    }

    /**
     * Not merely "a bold came back". A family with no bold member hands back
     * the upright, so a book set in it would render `<strong>` as body text
     * with nothing to show for it.
     */
    @Test
    fun `every face carries a real bold`() {
        for (face in IssaFonts.allFaces) {
            val regular = testFonts.upright(face.family, 18.0)!!
            val bold = testFonts.withBold(regular, 18.0)
            assertNotEquals("${face.family} has no bold member", regular.member, bold.member)
            assertTrue(bold.isBold)
            assertTrue("${face.family}'s bold sets no wider than its regular", width(bold) > width(regular))
        }
    }

    @Test
    fun `every face that claims an italic has one`() {
        for (face in IssaFonts.allFaces) {
            val regular = testFonts.upright(face.family, 18.0)!!
            val italic = testFonts.withItalic(regular, 18.0)
            if (face.hasItalic) {
                assertNotEquals("${face.family} claims an italic but resolves to ${italic.member}", regular.member, italic.member)
                assertTrue(italic.isItalic)
                assertNotEquals("${face.family}'s italic draws as its upright", width(regular), width(italic))
            } else {
                // Lexend ships none at any weight, and nothing here fakes one.
                // The upright face is the honest answer.
                assertEquals(regular.member, italic.member)
                assertTrue(!italic.isItalic)
            }
        }
    }

    /**
     * Bold layered on italic must keep the italic. AppKit's
     * `withSymbolicTraits(_:)` *replaces* the traits, so a bare bold there
     * stripped the italic — `<strong><em>` text rendered bold upright on the
     * Mac. The order matters: italic first and bold second, the path a nested
     * emphasis takes.
     */
    @Test
    fun `bold layered on an italic face keeps the italic`() {
        for (face in IssaFonts.allFaces.filter { it.hasItalic }) {
            val regular = testFonts.upright(face.family, 18.0)!!
            val boldItalic = testFonts.withBold(testFonts.withItalic(regular, 18.0), 18.0)
            assertTrue("${face.family}: applying bold stripped the italic — resolved ${boldItalic.member}", boldItalic.isItalic)
            assertTrue(boldItalic.isBold)
        }
    }

    @Test
    fun `the default face is one of the faces actually shipped`() {
        assertTrue(IssaFonts.allFaces.any { it.family == ReaderStyle.DEFAULT_FAMILY })
        // Still shipped, because the app's own UI serif is set in it and
        // because anyone moved off it must be able to pick it back.
        assertTrue(IssaFonts.allFaces.any { it.family == ReaderStyle.LEGACY_DEFAULT_FAMILY })
    }

    @Test
    fun `no family is offered twice — a picker cannot carry one tag in two sections`() {
        val families = IssaFonts.allFaces.map { it.family }
        assertEquals(families.size, families.toSet().size)
    }

    @Test
    fun `every face ships the licence it is bound by`() {
        for (face in IssaFonts.allFaces) {
            val text = IssaFonts.licence(RuntimeEnvironment.getApplication(), face)
            assertNotNull("no OFL file bundled for ${face.family}", text)
            assertTrue(text!!.contains("SIL OPEN FONT LICENSE"))
        }
    }

    /**
     * The variable files are given their weight: Public Sans's file defaults
     * to Thin, so the regular asked for without one would set hairline text.
     */
    @Test
    fun `a variable face's regular is not its thinnest`() {
        val regular = testFonts.upright("Public Sans", 18.0)!!
        assertTrue(regular.member.contains("'wght' 400"))
        val newsreader = testFonts.upright("Newsreader", 34.0)!!
        assertTrue("optical size follows the point size", newsreader.member.contains("'opsz' 34"))
    }

    /**
     * A book with no usable face still sets its text in something deliberate:
     * the app's default, not the system's.
     */
    @Test
    fun `a book with no usable face falls back to the app face`() {
        val style = ReaderStyle(typeface = ReaderStyle.Typeface.Publisher)
        assertNull(style.resolvedFamily)
        assertEquals(ReaderStyle.DEFAULT_FAMILY, testFonts.bodyFace(style, italic = false, bold = false, scale = 1.0).family)
        // And a name nothing answers to falls back the same way.
        val unknown = ReaderStyle(typeface = ReaderStyle.Typeface.Custom("Not A Face"))
        assertEquals(ReaderStyle.DEFAULT_FAMILY, testFonts.bodyFace(unknown, italic = true, bold = false, scale = 1.0).family)
    }

    /** Family names are matched as `IssaFonts.bundledFace` matches them: whatever case they arrive in. */
    @Test
    fun `a family is found whatever its case`() {
        assertEquals("Source Serif 4", testFonts.upright("source serif 4", 18.0)?.family)
    }
}
