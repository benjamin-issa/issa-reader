package com.benjaminissa.issareader.app.ui.reader

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import com.benjaminissa.issareader.app.model.PlaybackSettings
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.render.ReaderStyle
import com.benjaminissa.issareader.render.android.ReaderFonts
import com.benjaminissa.issareader.ui.ButtonRow
import com.benjaminissa.issareader.ui.Metrics
import com.benjaminissa.issareader.ui.PaperList
import com.benjaminissa.issareader.ui.PaperRowContent
import com.benjaminissa.issareader.ui.ThemePicker
import com.benjaminissa.issareader.ui.paperSection

/**
 * One book's own typography, reached from "Aa" in the reader.
 *
 * Edits are stored as a *departure* from the reading settings rather than as a
 * whole style, so a book that only changes its face still follows a later
 * change to the global line spacing. "Use my defaults" removes the departure
 * entirely rather than copying today's defaults into it.
 *
 * Only an edit the reader makes is written back. The iPhone seeded its copy
 * of the style and then had to tell that seed apart from an edit — merely
 * opening the sheet once re-derived the override and, when the global
 * settings had caught up with a book's own choice, deleted it outright.
 *
 * @param publisherFamily the face this book embeds, when it has a usable one.
 * @param onChange applies the resolved style to the open reader.
 */
@Composable
fun BookTypographyView(
    book: Book,
    settings: PlaybackSettings,
    fonts: ReaderFonts,
    publisherFamily: String?,
    publisherNote: String,
    onChange: () -> Unit,
    onDone: () -> Unit,
) {
    val context = LocalContext.current
    var style by remember(book.uuid) { mutableStateOf(settings.style(book.uuid)) }
    var customFamilies by remember { mutableStateOf(CustomFonts.families()) }

    fun edit(edited: ReaderStyle) {
        style = edited
        if (edited == settings.style(book.uuid)) return
        settings.setOverride(settings.readerStyle.difference(edited), book.uuid)
        onChange()
    }

    val importer = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        uri ?: return@rememberLauncherForActivityResult
        val typeface = FontImport.adopt(context, uri, fonts)?.let(FontImport::typeface) ?: return@rememberLauncherForActivityResult
        customFamilies = CustomFonts.families()
        edit(style.copy(typeface = typeface))
    }

    val override = settings.override(book.uuid)
    val footer = when {
        override == null || override.isEmpty ->
            "This book follows your reading settings. Change anything here and it keeps its own."
        override.count == 1 -> "This book keeps 1 setting of its own."
        else -> "This book keeps ${override.count} settings of its own."
    }

    Column(Modifier.fillMaxWidth()) {
        SheetInlineTitle(book.title, onDone)
        PaperList(contentPadding = PaddingValues(bottom = Metrics.spacing32)) {
            // Bound to the global value, not to this sheet's style: a book's
            // override carries typeface, size, spacing and justification and
            // nothing else, so a theme written through it would appear to work
            // and then not persist.
            paperSection(key = "theme", header = "Page colour", footer = "Applies to every book, unlike the settings below.") {
                row {
                    PaperRowContent {
                        ThemePicker(settings.readerStyle.theme, onSelect = {
                            settings.readerStyle = settings.readerStyle.copy(theme = it)
                            onChange()
                        })
                    }
                }
            }
            paperSection(key = "book", header = "This book", footer = footer) {
                typographyControls(
                    style = style,
                    onStyle = ::edit,
                    publisherFamily = publisherFamily,
                    publisherNote = publisherNote,
                    customFamilies = customFamilies,
                    onImport = { importer.launch(FontImport.mimeTypes) },
                )
            }
            if (override != null && !override.isEmpty) {
                paperSection(key = "defaults") {
                    row {
                        ButtonRow("Use my defaults", destructive = true, onClick = {
                            settings.setOverride(null, book.uuid)
                            style = settings.readerStyle
                            onChange()
                        })
                    }
                }
            }
        }
    }
}

/** The pure half of the sheet's import, for the suites. */
object BookTypography {
    /**
     * The face to select for a picked file, or null when the import was
     * refused — which [FontImport.notice] says under "Add a font…".
     *
     * Resolved the way the reading settings resolve it: a file of a family the
     * app ships is answered with that family, and was once set here as a
     * custom face — the book set in the app's own face under no row of the
     * picker, listed as a face of the reader's that is not theirs.
     */
    fun importedTypeface(fileName: String, bytes: ByteArray, fonts: ReaderFonts): ReaderStyle.Typeface? =
        FontImport.adopt(fileName, bytes, fonts)?.let(FontImport::typeface)
}
