package com.benjaminissa.issareader.app.ui.settings

import androidx.compose.material3.Text
import com.benjaminissa.issareader.render.ReaderStyle
import com.benjaminissa.issareader.ui.IssaFonts
import com.benjaminissa.issareader.ui.Palette
import com.benjaminissa.issareader.ui.PaperRowContent
import com.benjaminissa.issareader.ui.PaperSectionScope
import com.benjaminissa.issareader.ui.PickerRow
import com.benjaminissa.issareader.ui.StepperRow
import com.benjaminissa.issareader.ui.Typography

/**
 * The typography defaults, as Settings › Reading & highlights shows them:
 * the half of Swift's `TypographyControls` that Settings needs.
 *
 * The Swift view is shared with the reader's "Aa" sheet, so that the two
 * cannot drift apart. The reader's own port draws that sheet; this is the
 * Settings side, where there is no book and so no publisher's face.
 *
 * Swift offers "Add a font…" here as well. Android has no font import yet
 * (`CustomFonts` and `FontImport` are not ported), so the row and its "Your
 * fonts" group are left out rather than offering a button that does nothing.
 */
internal object ReadingDefaultsControls {
    /** Text size in points, as the stepper offers it. */
    val textSizeRange: ClosedFloatingPointRange<Double> = 12.0..32.0

    /**
     * Keeps a selection that is no longer offered from clearing the picker.
     *
     * A default set to the publisher's face — there is no book here — or to
     * an imported face this device does not have would otherwise show an
     * empty picker and lose the setting on the next touch. A bundled family
     * chosen as an import is the bundled row.
     */
    fun typefaceSelection(style: ReaderStyle, customFamilies: List<String> = emptyList()): ReaderStyle.Typeface =
        when (val typeface = style.typeface) {
            ReaderStyle.Typeface.Publisher -> ReaderStyle.Typeface.Bundled(ReaderStyle.DEFAULT_FAMILY)
            is ReaderStyle.Typeface.Custom -> {
                val bundled = IssaFonts.bundledFace(typeface.name)
                when {
                    bundled != null -> ReaderStyle.Typeface.Bundled(bundled.family)
                    typeface.name !in listedCustomFamilies(customFamilies) -> ReaderStyle.Typeface.Bundled(ReaderStyle.DEFAULT_FAMILY)
                    else -> typeface
                }
            }
            is ReaderStyle.Typeface.Bundled -> typeface
        }

    /**
     * Imported faces less any family the app ships: a copy of Literata
     * registers as Literata, and listing it again under "Your fonts" offered
     * one face twice.
     */
    fun listedCustomFamilies(families: List<String>): List<String> = families.filter { IssaFonts.bundledFace(it) == null }

    /** What the picker calls a typeface. */
    fun title(typeface: ReaderStyle.Typeface): String = when (typeface) {
        ReaderStyle.Typeface.Publisher -> "Publisher's font"
        is ReaderStyle.Typeface.Bundled -> IssaFonts.bundledFace(typeface.name)?.title ?: typeface.name
        is ReaderStyle.Typeface.Custom -> typeface.name
    }

    /**
     * The sentence under the picker for a face that ships no italic, or null.
     * Said rather than left to be discovered mid-chapter.
     */
    fun italicNote(style: ReaderStyle): String? {
        val family = (style.typeface as? ReaderStyle.Typeface.Bundled)?.name ?: return null
        val face = IssaFonts.allFaces.firstOrNull { it.family == family } ?: return null
        return if (face.hasItalic) null else "${face.title} has no italic, so emphasis is set upright."
    }
}

/**
 * The rows: typeface, the italic note where it applies, text size, line
 * spacing and justification.
 */
internal fun PaperSectionScope.readingDefaultsControls(style: ReaderStyle, onStyleChange: (ReaderStyle) -> Unit) {
    // Grouped, because "which face is easiest for me to read" and "which face
    // do I like" are different questions, and the accessibility ones are worth
    // finding without reading the whole list.
    row {
        SectionedPickerRow(
            "Typeface",
            selection = ReadingDefaultsControls.typefaceSelection(style),
            groups = listOf(
                PickerGroup("Reading", IssaFonts.readingFaces.map { ReaderStyle.Typeface.Bundled(it.family) }),
                PickerGroup("Accessibility", IssaFonts.accessibilityFaces.map { ReaderStyle.Typeface.Bundled(it.family) }),
            ),
            label = ReadingDefaultsControls::title,
            onSelect = { onStyleChange(style.copy(typeface = it)) },
        )
    }
    ReadingDefaultsControls.italicNote(style)?.let { note ->
        row { PaperRowContent { Text(note, style = Typography.caption, color = Palette.inkTertiary) } }
    }
    row {
        StepperRow(
            "Text size",
            value = style.fontSize,
            range = ReadingDefaultsControls.textSizeRange,
            onValueChange = { onStyleChange(style.copy(fontSize = it)) },
            format = { "${it.toInt()}pt" },
        )
    }
    row {
        SegmentedRow(
            options = ReaderStyle.LineSpacing.entries,
            selection = style.lineSpacing,
            label = { it.rawValue.replaceFirstChar(Char::uppercaseChar) },
            onSelect = { onStyleChange(style.copy(lineSpacing = it)) },
        )
    }
    // Three positions rather than two, because a book has an opinion here and
    // a switch could not say whose wins. A row with the choice on the right
    // rather than a segmented control: "Follow the book" is a phrase, and
    // three of those do not fit across a phone.
    row {
        PickerRow(
            "Justify text",
            selection = style.justification,
            options = ReaderStyle.Justification.entries,
            label = { it.title },
            onSelect = { onStyleChange(style.copy(justification = it)) },
        )
    }
}
