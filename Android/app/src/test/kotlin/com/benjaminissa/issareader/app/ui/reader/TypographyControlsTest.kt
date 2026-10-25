package com.benjaminissa.issareader.app.ui.reader

import com.benjaminissa.issareader.render.ReaderStyle
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The typography controls' rules, which the reader's Aa sheet and Settings ›
 * Reading share: Swift's `TypographyControls`. Its
 * `FontImportTests.bundledFamiliesAreNotListed` is `FontImportTest`'s.
 */
class TypographyControlsTest {
    /**
     * Settings has no book, so no publisher's face: a default set to one shows
     * the app's own rather than an empty picker, and so does an imported face
     * this device no longer has.
     */
    @Test
    fun `a selection no longer offered falls back rather than clearing the picker`() {
        val default = ReaderStyle.Typeface.Bundled(ReaderStyle.DEFAULT_FAMILY)
        assertEquals(default, TypographyControls.typefaceSelection(ReaderStyle.Typeface.Publisher, publisherFamily = null, listed = emptyList()))
        assertEquals(default, TypographyControls.typefaceSelection(ReaderStyle.Typeface.Custom("Gone Face"), publisherFamily = null, listed = emptyList()))
        assertEquals(
            ReaderStyle.Typeface.Bundled("Lexend"),
            TypographyControls.typefaceSelection(ReaderStyle.Typeface.Custom("LEXEND"), publisherFamily = null, listed = emptyList()),
        )
        assertEquals(
            ReaderStyle.Typeface.Custom("Mine"),
            TypographyControls.typefaceSelection(ReaderStyle.Typeface.Custom("Mine"), publisherFamily = null, listed = listOf("Mine")),
        )
        assertEquals(
            "a book with a face of its own keeps it",
            ReaderStyle.Typeface.Publisher,
            TypographyControls.typefaceSelection(ReaderStyle.Typeface.Publisher, publisherFamily = "Minion Pro", listed = emptyList()),
        )
    }

    @Test
    fun `only a face with no italic is said to have none`() {
        assertEquals(
            "Lexend has no italic, so emphasis is set upright.",
            TypographyControls.italicNote(ReaderStyle(typeface = ReaderStyle.Typeface.Bundled("Lexend"))),
        )
        assertNull(TypographyControls.italicNote(ReaderStyle(typeface = ReaderStyle.Typeface.Bundled("Literata"))))
    }

    /** The publisher's face leads Reading only when the book has one; "Your fonts" appears once there is one. */
    @Test
    fun `the picker's groups follow what there is to offer`() {
        val plain = TypographyControls.groups(publisherFamily = null, listed = emptyList())
        assertEquals(listOf("Reading", "Accessibility"), plain.map { it.title })
        assertEquals(false, ReaderStyle.Typeface.Publisher in plain[0].options)

        val book = TypographyControls.groups(publisherFamily = "Minion Pro", listed = listOf("Mine"))
        assertEquals(listOf("Reading", "Accessibility", "Your fonts"), book.map { it.title })
        assertEquals(ReaderStyle.Typeface.Publisher, book[0].options.first())
        assertEquals(listOf(ReaderStyle.Typeface.Custom("Mine")), book[2].options)
    }
}
