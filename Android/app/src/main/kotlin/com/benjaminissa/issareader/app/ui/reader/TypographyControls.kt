package com.benjaminissa.issareader.app.ui.reader

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.benjaminissa.issareader.render.ReaderStyle
import com.benjaminissa.issareader.ui.ButtonRow
import com.benjaminissa.issareader.ui.IssaFonts
import com.benjaminissa.issareader.ui.Metrics
import com.benjaminissa.issareader.ui.Palette
import com.benjaminissa.issareader.ui.PaperRowContent
import com.benjaminissa.issareader.ui.PaperRowFrame
import com.benjaminissa.issareader.ui.PaperSectionScope
import com.benjaminissa.issareader.ui.PickerRow
import com.benjaminissa.issareader.ui.SectionHeaderText
import com.benjaminissa.issareader.ui.StepperRow
import com.benjaminissa.issareader.ui.Symbols
import com.benjaminissa.issareader.ui.SystemText
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
 * @param onImport opens the document picker; null where importing is not offered.
 */
fun PaperSectionScope.typographyControls(
    style: ReaderStyle,
    onStyle: (ReaderStyle) -> Unit,
    publisherFamily: String? = null,
    publisherNote: String? = null,
    customFamilies: List<String> = emptyList(),
    onImport: (() -> Unit)? = null,
) {
    val listed = TypographyControls.listedCustomFamilies(customFamilies)
    // Grouped, because "which face is easiest for me to read" and "which face
    // do I like" are different questions, and the accessibility ones are
    // worth finding without reading the whole list.
    row {
        TypefacePickerRow(
            selection = TypographyControls.typefaceSelection(style.typeface, publisherFamily, listed),
            publisherFamily = publisherFamily,
            customFamilies = listed,
            onSelect = { onStyle(style.copy(typeface = it)) },
        )
    }
    if (publisherNote != null && publisherFamily == null) {
        row { Caption(publisherNote) }
    }
    // Said rather than left to be discovered mid-chapter. Lexend ships no
    // italic at any weight, and the renderer will not fake one.
    val typeface = style.typeface
    if (typeface is ReaderStyle.Typeface.Bundled) {
        val face = IssaFonts.allFaces.firstOrNull { it.family == typeface.name }
        if (face != null && !face.hasItalic) row { Caption("${face.title} has no italic, so emphasis is set upright.") }
    }
    if (onImport != null) {
        row(dividerStart = 54.dp) {
            ButtonRow(
                "Add a font…",
                onClick = {
                    FontImport.notice.clear()
                    onImport()
                },
                icon = Symbols.plusCircle,
            )
        }
        // Said, because the picker closing with nothing changed looked
        // exactly like an import that worked and had not refreshed.
        FontImport.notice.message?.let { failure -> row { Caption(failure, color = { Palette.alert }) } }
    }
    row {
        StepperRow(
            "Text size",
            value = style.fontSize,
            range = 12.0..32.0,
            onValueChange = { onStyle(style.copy(fontSize = it)) },
            format = { "${it.toInt()}pt" },
        )
    }
    row { LineSpacingControl(style.lineSpacing) { onStyle(style.copy(lineSpacing = it)) } }
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
    /**
     * Imported faces less any family the app ships: a copy of Literata
     * imported by the reader registers as Literata — the app's own — and
     * listing it again under "Your fonts" offered one face twice.
     */
    fun listedCustomFamilies(families: List<String>): List<String> =
        families.filter { CustomFonts.bundledFamily(it) == null }

    /**
     * Keeps a selection that is no longer offered from clearing the picker.
     * A book set in the publisher's face, reopened on a book that has none —
     * or set in an imported face whose file is no longer registered — would
     * otherwise show nothing chosen and lose the setting on the next touch.
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

    /** What the picker's row says for a typeface. */
    fun title(typeface: ReaderStyle.Typeface): String = when (typeface) {
        ReaderStyle.Typeface.Publisher -> "Publisher's font"
        is ReaderStyle.Typeface.Bundled -> IssaFonts.bundledFace(typeface.name)?.title ?: typeface.name
        is ReaderStyle.Typeface.Custom -> typeface.name
    }
}

@Composable
private fun Caption(text: String, color: @Composable () -> androidx.compose.ui.graphics.Color = { Palette.inkTertiary }) {
    PaperRowContent { Text(text, style = Typography.caption, color = color()) }
}

/**
 * The typeface menu: the iPhone's sectioned picker, as a Material menu with a
 * quiet heading over each group.
 */
@Composable
private fun TypefacePickerRow(
    selection: ReaderStyle.Typeface,
    publisherFamily: String?,
    customFamilies: List<String>,
    onSelect: (ReaderStyle.Typeface) -> Unit,
) {
    var open by remember { mutableStateOf(false) }
    Box {
        PaperRowFrame(onClick = { open = true }) {
            Text("Typeface", style = SystemText.body, color = Palette.ink, modifier = Modifier.weight(1f))
            Text(
                TypographyControls.title(selection),
                style = SystemText.body,
                color = Palette.tangerine,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Icon(painterResource(Symbols.chevronUpChevronDown), contentDescription = null, tint = Palette.tangerine, modifier = Modifier.size(16.dp))
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }, containerColor = Palette.surface) {
            @Composable
            fun option(title: String, typeface: ReaderStyle.Typeface) {
                DropdownMenuItem(
                    text = { Text(title, style = SystemText.body, color = Palette.ink) },
                    trailingIcon = if (typeface == selection) {
                        { Icon(painterResource(Symbols.checkmark), contentDescription = "Selected", tint = Palette.tangerine) }
                    } else {
                        null
                    },
                    onClick = {
                        open = false
                        onSelect(typeface)
                    },
                )
            }
            Heading("Reading")
            if (publisherFamily != null) option("Publisher's font", ReaderStyle.Typeface.Publisher)
            for (face in IssaFonts.readingFaces) option(face.title, ReaderStyle.Typeface.Bundled(face.family))
            Heading("Accessibility")
            for (face in IssaFonts.accessibilityFaces) option(face.title, ReaderStyle.Typeface.Bundled(face.family))
            if (customFamilies.isNotEmpty()) {
                Heading("Your fonts")
                for (family in customFamilies) option(family, ReaderStyle.Typeface.Custom(family))
            }
        }
    }
}

@Composable
private fun Heading(title: String) {
    SectionHeaderText(title, Modifier.padding(start = Metrics.spacing12, end = Metrics.spacing12, top = Metrics.spacing8, bottom = Metrics.spacing4))
}

/** Tight, Normal, Roomy: Material's segmented buttons in the palette. */
@Composable
private fun LineSpacingControl(selection: ReaderStyle.LineSpacing, onSelect: (ReaderStyle.LineSpacing) -> Unit) {
    PaperRowContent {
        val options = ReaderStyle.LineSpacing.entries
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(vertical = 2.dp)) {
            options.forEachIndexed { index, spacing ->
                SegmentedButton(
                    selected = spacing == selection,
                    onClick = { onSelect(spacing) },
                    shape = SegmentedButtonDefaults.itemShape(index, options.size),
                    icon = {},
                    colors = SegmentedButtonDefaults.colors(
                        activeContainerColor = Palette.tangerine.copy(alpha = 0.16f),
                        activeContentColor = Palette.ink,
                        activeBorderColor = Palette.borderStrong,
                        inactiveContainerColor = Palette.surfaceRaised,
                        inactiveContentColor = Palette.ink,
                        inactiveBorderColor = Palette.borderStrong,
                    ),
                    modifier = Modifier.weight(1f),
                    label = {
                        Text(spacing.rawValue.replaceFirstChar { it.uppercase() }, style = SystemText.subheadline, maxLines = 1)
                    },
                )
            }
        }
    }
}
