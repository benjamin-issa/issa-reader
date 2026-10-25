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
import com.benjaminissa.issareader.app.model.FontImport
import com.benjaminissa.issareader.app.model.PlaybackSettings
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.render.ReaderStyle
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
 * @param fontImport "Add a font…": the app's one, which Settings shares.
 * @param publisherFamily the face this book embeds, when it has a usable one.
 * @param onChange applies the resolved style to the open reader.
 */
@Composable
fun BookTypographyView(
    book: Book,
    settings: PlaybackSettings,
    fontImport: FontImport,
    publisherFamily: String?,
    publisherNote: String,
    onChange: () -> Unit,
    onDone: () -> Unit,
) {
    var style by remember(book.uuid) { mutableStateOf(settings.style(book.uuid)) }
    var customFamilies by remember(fontImport) { mutableStateOf(fontImport.customFonts.families()) }

    fun edit(edited: ReaderStyle) {
        style = edited
        if (edited == settings.style(book.uuid)) return
        settings.setOverride(settings.readerStyle.difference(edited), book.uuid)
        onChange()
    }

    // A refusal says itself, under "Add a font…". A file of a family the app
    // ships selects the app's own row (`FontImport.importedTypeface`).
    val importer = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        uri ?: return@rememberLauncherForActivityResult
        val typeface = fontImport.importedTypeface(uri) ?: return@rememberLauncherForActivityResult
        customFamilies = fontImport.customFonts.families()
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
                    importNotice = fontImport.notice,
                    onImport = { importer.launch(FontImport.contentTypes) },
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
