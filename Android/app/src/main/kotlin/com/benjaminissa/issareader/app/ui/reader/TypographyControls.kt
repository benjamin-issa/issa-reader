package com.benjaminissa.issareader.app.ui.reader

import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.dp
import com.benjaminissa.issareader.app.model.CustomFonts
import com.benjaminissa.issareader.app.model.FontImport
import com.benjaminissa.issareader.app.ui.settings.PickerGroup
import com.benjaminissa.issareader.app.ui.settings.SectionedPickerRow
import com.benjaminissa.issareader.app.ui.settings.SegmentedRow
import com.benjaminissa.issareader.render.ReaderStyle
import com.benjaminissa.issareader.ui.ButtonRow
import com.benjaminissa.issareader.ui.IssaFonts
import com.benjaminissa.issareader.ui.Palette
import com.benjaminissa.issareader.ui.PaperRowContent
import com.benjaminissa.issareader.ui.PaperSectionScope
import com.benjaminissa.issareader.ui.PickerRow
import com.benjaminissa.issareader.ui.StepperRow
import com.benjaminissa.issareader.ui.Symbols
import com.benjaminissa.issareader.ui.Typography

/**
 * The typography controls, shared by the global settings and the per-book
 * sheet, as rows of one grouped section.
 *
 * One set of rows rather than two, so that "Aa" in the reader and "Reading &
 * highlights" in Settings cannot drift apart — they are the same choices,
 * made at different scopes.
 *
 * @param publisherFamily the face this book embeds, when there is a usable one.
 * @param publisherNote what to say about the book's own face when it cannot be used.
 * @param customFamilies imported faces, refreshed when one is added.
 * @param importNotice what the last import could not do, said under "Add a font…".
 * @param onImport opens the document picker; null where importing is not offered.
 */
fun PaperSectionScope.typographyControls(
    style: ReaderStyle,
    onStyle: (ReaderStyle) -> Unit,
    publisherFamily: String? = null,
    publisherNote: String? = null,
    customFamilies: List<String> = emptyList(),
    importNotice: FontImport.Notice? = null,
    onImport: (() -> Unit)? = null,
) {
    val listed = FontImport.listedCustomFamilies(customFamilies)
    // Grouped, because "which face is easiest for me to read" and "which face
    // do I like" are different questions, and the accessibility ones are
    // worth finding without reading the whole list.
    row {
        SectionedPickerRow(
            "Typeface",
            selection = TypographyControls.typefaceSelection(style.typeface, publisherFamily, listed),
            groups = TypographyControls.groups(publisherFamily, listed),
            label = TypographyControls::title,
            onSelect = { onStyle(style.copy(typeface = it)) },
        )
    }
    if (publisherNote != null && publisherFamily == null) {
        row { Caption(publisherNote) }
    }
    // Said rather than left to be discovered mid-chapter. Lexend ships no
    // italic at any weight, and the renderer will not fake one.
    TypographyControls.italicNote(style)?.let { note -> row { Caption(note) } }
    if (onImport != null) {
        row(dividerStart = 54.dp) {
            ButtonRow(
                "Add a font…",
                onClick = {
                    importNotice?.clear()
                    onImport()
                },
                icon = Symbols.plusCircle,
            )
        }
        // Said, because the picker closing with nothing changed looked
        // exactly like an import that worked and had not refreshed.
        importNotice?.message?.let { failure -> row { Caption(failure, alert = true) } }
    }
    row {
        StepperRow(
            "Text size",
            value = style.fontSize,
            range = TypographyControls.textSizeRange,
            onValueChange = { onStyle(style.copy(fontSize = it)) },
            format = { "${it.toInt()}pt" },
        )
    }
    row {
        SegmentedRow(
            options = ReaderStyle.LineSpacing.entries,
            selection = style.lineSpacing,
            label = { it.rawValue.replaceFirstChar(Char::uppercaseChar) },
            onSelect = { onStyle(style.copy(lineSpacing = it)) },
        )
    }
    // Three positions rather than two, because a book has an opinion here and
    // a switch could not say whose wins. A row with the choice on the right,
    // rather than a segmented control: "Follow the book" is a phrase, and
    // three of those do not fit across a phone.
    row {
        PickerRow(
            "Justify text",
            selection = style.justification,
            options = ReaderStyle.Justification.entries,
            label = { it.title },
            onSelect = { onStyle(style.copy(justification = it)) },
        )
    }
}

/** The pure rules behind the controls, kept apart so they can be tested. */
object TypographyControls {
    /** Text size in points, as the stepper offers it. */
    val textSizeRange: ClosedFloatingPointRange<Double> = 12.0..32.0

    /**
     * Keeps a selection that is no longer offered from clearing the picker.
     * A book set in the publisher's face, reopened on a book that has none —
     * or set in an imported face whose file is no longer registered — would
     * otherwise show nothing chosen and lose the setting on the next touch.
     * Settings has no book, so no publisher's face, and a default set to one
     * shows the app's own.
     */
    fun typefaceSelection(typeface: ReaderStyle.Typeface, publisherFamily: String?, listed: List<String>): ReaderStyle.Typeface {
        if (typeface == ReaderStyle.Typeface.Publisher && publisherFamily == null) {
            return ReaderStyle.Typeface.Bundled(ReaderStyle.DEFAULT_FAMILY)
        }
        if (typeface is ReaderStyle.Typeface.Custom) {
            // A bundled family chosen as an import is the bundled row.
            CustomFonts.bundledFamily(typeface.name)?.let { return ReaderStyle.Typeface.Bundled(it) }
            if (typeface.name !in listed) return ReaderStyle.Typeface.Bundled(ReaderStyle.DEFAULT_FAMILY)
        }
        return typeface
    }

    /**
     * The picker's groups, as the iPhone's sectioned picker has them: Reading
     * (the publisher's face first, when the book has a usable one),
     * Accessibility, and "Your fonts" once the reader has imported one.
     */
    internal fun groups(publisherFamily: String?, listed: List<String>): List<PickerGroup<ReaderStyle.Typeface>> = listOfNotNull(
        PickerGroup(
            "Reading",
            listOfNotNull(if (publisherFamily != null) ReaderStyle.Typeface.Publisher else null) +
                IssaFonts.readingFaces.map { ReaderStyle.Typeface.Bundled(it.family) },
        ),
        PickerGroup("Accessibility", IssaFonts.accessibilityFaces.map { ReaderStyle.Typeface.Bundled(it.family) }),
        if (listed.isNotEmpty()) PickerGroup("Your fonts", listed.map { ReaderStyle.Typeface.Custom(it) }) else null,
    )

    /** What the picker's row says for a typeface. */
    fun title(typeface: ReaderStyle.Typeface): String = when (typeface) {
        ReaderStyle.Typeface.Publisher -> "Publisher's font"
        is ReaderStyle.Typeface.Bundled -> IssaFonts.bundledFace(typeface.name)?.title ?: typeface.name
        is ReaderStyle.Typeface.Custom -> typeface.name
    }

    /** The sentence under the picker for a face that ships no italic, or null. */
    fun italicNote(style: ReaderStyle): String? {
        val family = (style.typeface as? ReaderStyle.Typeface.Bundled)?.name ?: return null
        val face = IssaFonts.allFaces.firstOrNull { it.family == family } ?: return null
        return if (face.hasItalic) null else "${face.title} has no italic, so emphasis is set upright."
    }
}

@Composable
private fun Caption(text: String, alert: Boolean = false) {
    PaperRowContent { Text(text, style = Typography.caption, color = if (alert) Palette.alert else Palette.inkTertiary) }
}
