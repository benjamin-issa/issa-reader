package com.benjaminissa.issareader.app.ui.settings

import android.content.Context
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import com.benjaminissa.issareader.app.model.FontImport
import com.benjaminissa.issareader.app.model.PlaybackSettings
import com.benjaminissa.issareader.app.ui.reader.HighlightSample
import com.benjaminissa.issareader.app.ui.reader.typographyControls
import com.benjaminissa.issareader.app.ui.shell.LocalAppEnvironment
import com.benjaminissa.issareader.render.PageTurn
import com.benjaminissa.issareader.render.PageTurnStyle
import com.benjaminissa.issareader.render.ReaderStyle
import com.benjaminissa.issareader.render.ReaderTheme
import com.benjaminissa.issareader.ui.ButtonRow
import com.benjaminissa.issareader.ui.HighlighterPicker
import com.benjaminissa.issareader.ui.NavigationRow
import com.benjaminissa.issareader.ui.Palette
import com.benjaminissa.issareader.ui.PaperRowContent
import com.benjaminissa.issareader.ui.PickerRow
import com.benjaminissa.issareader.ui.Symbols
import com.benjaminissa.issareader.ui.ThemePicker
import com.benjaminissa.issareader.ui.ToggleRow
import com.benjaminissa.issareader.ui.Typography
import com.benjaminissa.issareader.ui.color
import com.benjaminissa.issareader.ui.paperSection

/**
 * Page colour, highlighter, type, pages and read-along: `ReadingSettingsView.swift`.
 *
 * @param reduceMotion whether the system has removed animations; read from
 *   the device when not given.
 * @param fontImport "Add a font…" and the faces it imported: the app's one,
 *   which a book's own sheet shares. Null where importing is not offered.
 */
@Composable
internal fun ReadingSettingsScreen(
    settings: PlaybackSettings,
    onBack: (() -> Unit)?,
    onOpenLicences: () -> Unit,
    reduceMotion: Boolean? = null,
    largeTitle: Boolean = true,
    fontImport: FontImport? = LocalAppEnvironment.current.fontImport,
) {
    val context = LocalContext.current
    val motionRemoved = reduceMotion ?: remember(context) { ReadingSettings.animationsRemoved(context) }
    val style = settings.readerStyle
    val theme = style.theme
    var customFamilies by remember(fontImport) { mutableStateOf(fontImport?.customFonts?.families().orEmpty()) }
    // A refusal says itself, under "Add a font…". An import is selected
    // straight away: importing a font and then having to find it in a list is
    // a step with no purpose — as the app's own face when the file was a copy
    // of one.
    val importer = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        val fonts = fontImport ?: return@rememberLauncherForActivityResult
        uri ?: return@rememberLauncherForActivityResult
        val family = fonts.adopt(uri) ?: return@rememberLauncherForActivityResult
        customFamilies = fonts.customFonts.families()
        settings.readerStyle = settings.readerStyle.copy(typeface = FontImport.typeface(family))
    }

    SettingsPage(title = "Reading", onBack = onBack, largeTitle = largeTitle) {
        paperSection(
            key = "highlighter",
            header = "Highlighter",
            footer = "The same control is in the reader under Aa. Page colour is one setting for every book, not a per-book choice like the type. Each page colour remembers its own highlighter for the sentence being read aloud.",
        ) {
            row { Caption("Page colour — ${theme.title}") }
            row {
                PaperRowContent {
                    ThemePicker(selection = theme, onSelect = { settings.readerStyle = settings.readerStyle.copy(theme = it) })
                }
            }
            row { Caption("Highlighter on ${theme.title}") }
            row {
                PaperRowContent {
                    HighlighterPicker(
                        theme = theme,
                        selection = style.highlighters[theme],
                        onSelect = { settings.readerStyle = ReadingSettings.choosingHighlighter(settings.readerStyle, theme, it) },
                    )
                }
            }
            row {
                PaperRowContent {
                    HighlightSample(theme = theme, highlight = style.highlightColor.color, fontFamily = style.resolvedFamily)
                }
            }
            // Only once this page colour has departed from its default, so the
            // row is an answer to "how do I undo this" rather than a permanent
            // piece of furniture offering to undo nothing.
            if (style.highlighters[theme] != null) {
                row {
                    ButtonRow("Use default for ${theme.title}", onClick = {
                        settings.readerStyle = ReadingSettings.choosingHighlighter(settings.readerStyle, theme, null)
                    })
                }
            }
        }

        paperSection(
            key = "type",
            header = "Type",
            footer = "These are your defaults. Any book can depart from them — open it and tap Aa.",
        ) {
            // The publisher's font is a per-book choice — there is no book
            // here — so the picker offers the app's faces and any the reader
            // imported.
            typographyControls(
                style = style,
                onStyle = { settings.readerStyle = it },
                customFamilies = customFamilies,
                importNotice = fontImport?.notice,
                onImport = if (fontImport != null) ({ importer.launch(FontImport.contentTypes) }) else null,
            )
        }

        paperSection(key = "pages", header = "Pages", footer = ReadingSettings.pagesNote(motionRemoved)) {
            row {
                // Shown as None and left alone underneath, so the reader's own
                // choice is still there when animations come back.
                PickerRow(
                    "Page turn",
                    selection = PageTurn.effectiveStyle(settings.pageTurn, reduceMotion = motionRemoved),
                    options = PageTurnStyle.entries,
                    label = { it.title },
                    onSelect = { settings.pageTurn = it },
                    enabled = !motionRemoved,
                )
            }
        }

        paperSection(
            key = "readAlong",
            header = "Read-along",
            footer = "“Follow narration” keeps the spoken sentence on screen. Turning pages mid-sentence flips as soon as the text runs off, rather than waiting for the sentence to finish. Double-tapping a sentence starts the narration there.",
        ) {
            row {
                SegmentedRow(
                    options = ReaderStyle.HighlightGranularity.entries,
                    selection = style.highlightGranularity,
                    label = { it.rawValue.replaceFirstChar(Char::uppercaseChar) },
                    onSelect = { settings.readerStyle = settings.readerStyle.copy(highlightGranularity = it) },
                )
            }
            row {
                ToggleRow("Follow narration", style.followNarration, { settings.readerStyle = settings.readerStyle.copy(followNarration = it) })
            }
            row {
                ToggleRow("Turn pages mid-sentence", style.turnPagesMidSentence, { settings.readerStyle = settings.readerStyle.copy(turnPagesMidSentence = it) })
            }
            row {
                ToggleRow("Double-tap a sentence to play it", style.tapToPlay, { settings.readerStyle = settings.readerStyle.copy(tapToPlay = it) })
            }
            row {
                PickerRow(
                    "Progress shows",
                    selection = style.progressDisplay,
                    options = ReaderStyle.ProgressDisplay.entries,
                    label = { it.title },
                    onSelect = { settings.readerStyle = settings.readerStyle.copy(progressDisplay = it) },
                )
            }
        }

        paperSection(key = "licences") {
            row { NavigationRow("Fonts & licences", onOpenLicences, icon = Symbols.textformatAlt) }
        }
    }
}

/**
 * A quiet line naming what the control under it applies to. Both swatch rows
 * are wordless, and stacked in one section they read as eight anonymous
 * circles; naming the page colour in each also says the second row belongs
 * to whichever paper the first has chosen.
 */
@Composable
private fun Caption(text: String) {
    PaperRowContent { Text(text, style = Typography.subhead, color = Palette.inkSecondary) }
}

/** The screen's rules, without the screen. */
internal object ReadingSettings {
    /**
     * Android's Reduce Motion: "Remove animations", which sets the animator
     * duration scale to zero.
     */
    fun animationsRemoved(context: Context): Boolean =
        runCatching { Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f }
            .getOrDefault(false)

    /**
     * The Pages section's note, which says first why the picker cannot be used
     * when it cannot — a disabled control with no reason given reads as broken.
     */
    fun pagesNote(animationsRemoved: Boolean): String {
        val styles = "Slide moves the next page in beside the current one. Cover slides the page away over the next. None changes the page instantly."
        if (!animationsRemoved) return styles
        return "Remove animations is on, so pages change instantly. To choose how they move, turn it off in Settings › Accessibility › Color and motion. $styles"
    }

    /**
     * One page colour's highlighter. Choosing nothing removes the key rather
     * than storing an empty value, which keeps "this page colour has been
     * changed" answerable as a presence test.
     */
    fun choosingHighlighter(style: ReaderStyle, theme: ReaderTheme, choice: com.benjaminissa.issareader.render.HighlighterChoice?): ReaderStyle =
        style.copy(highlighters = if (choice == null) style.highlighters - theme else style.highlighters + (theme to choice))
}
