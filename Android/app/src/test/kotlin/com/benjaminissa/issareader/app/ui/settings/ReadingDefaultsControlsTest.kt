package com.benjaminissa.issareader.app.ui.settings

import com.benjaminissa.issareader.render.ReaderStyle
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The typography defaults' rules: the Settings half of Swift's
 * `TypographyControls`, with `FontImportTests.bundledFamiliesAreNotListed`.
 */
class ReadingDefaultsControlsTest {
    /** A copy of Literata imported by the reader registers as Literata, and listing it again offered one face twice. */
    @Test
    fun `a family the app ships is not listed under Your fonts, in any case`() {
        assertEquals(listOf("My Own Face"), ReadingDefaultsControls.listedCustomFamilies(listOf("Literata", "lexend", "My Own Face")))
    }

    /** No book here, so no publisher's face: a default set to one shows the app's own rather than an empty picker. */
    @Test
    fun `a selection no longer offered falls back rather than clearing the picker`() {
        val default = ReaderStyle.Typeface.Bundled(ReaderStyle.DEFAULT_FAMILY)
        assertEquals(default, ReadingDefaultsControls.typefaceSelection(ReaderStyle(typeface = ReaderStyle.Typeface.Publisher)))
        assertEquals(default, ReadingDefaultsControls.typefaceSelection(ReaderStyle(typeface = ReaderStyle.Typeface.Custom("Gone Face"))))
        assertEquals(
            ReaderStyle.Typeface.Bundled("Lexend"),
            ReadingDefaultsControls.typefaceSelection(ReaderStyle(typeface = ReaderStyle.Typeface.Custom("LEXEND"))),
        )
        assertEquals(
            ReaderStyle.Typeface.Custom("Mine"),
            ReadingDefaultsControls.typefaceSelection(ReaderStyle(typeface = ReaderStyle.Typeface.Custom("Mine")), customFamilies = listOf("Mine")),
        )
    }

    @Test
    fun `only a face with no italic is said to have none`() {
        assertEquals(
            "Lexend has no italic, so emphasis is set upright.",
            ReadingDefaultsControls.italicNote(ReaderStyle(typeface = ReaderStyle.Typeface.Bundled("Lexend"))),
        )
        assertNull(ReadingDefaultsControls.italicNote(ReaderStyle(typeface = ReaderStyle.Typeface.Bundled("Literata"))))
    }
}
