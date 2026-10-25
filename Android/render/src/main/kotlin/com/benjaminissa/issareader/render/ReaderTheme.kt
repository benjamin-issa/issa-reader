package com.benjaminissa.issareader.render

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Reading themes offered in the reader, from the design's "Page theme" control.
 *
 * Fixed values, deliberately not the app palette. The page's appearance is the
 * reader's own choice: someone who picks Paper while the system is in dark
 * theme has asked for a light page, and should get one. Drawing these from the
 * adaptive palette made Paper and Sepia turn dark with the system, so the four
 * themes collapsed to two and the picker offered a choice that did nothing.
 */
@Serializable
enum class ReaderTheme(
    private val backgroundHex: Int,
    private val textHex: Int,
    private val accentHex: Int,
) {
    @SerialName("paper") PAPER(0xFFFDF8, 0x221F1A, 0xE2853A),
    @SerialName("sepia") SEPIA(0xF4EFE3, 0x221F1A, 0xE2853A),
    @SerialName("night") NIGHT(0x17150F, 0xE0D6C6, 0xEE9B57),
    @SerialName("slate") SLATE(0x1C2422, 0x9FB3AF, 0xEE9B57),
    ;

    /** The persisted spelling, shared with the Swift client's `rawValue`. */
    val rawValue: String get() = name.lowercase()

    val background: Rgba get() = Rgba.hex(backgroundHex)
    val text: Rgba get() = Rgba.hex(textHex)

    /**
     * Quieter inks, for the reader's own furniture. The progress readout, the
     * controls and the messages shown while a book is opening are drawn *on the
     * page*, so they take their colour from the page.
     */
    val textSecondary: Rgba get() = text.withAlpha(0.75)
    val textTertiary: Rgba get() = text.withAlpha(0.55)

    /** The accent for anything interactive drawn on the page. */
    val accent: Rgba get() = Rgba.hex(accentHex)

    /**
     * Fill behind the currently-narrated sentence, when the reader has not
     * chosen a highlighter of their own: the default preset at this ground's
     * alpha, so the swatch the picker draws first and the colour an untouched
     * page paints are the same value by construction.
     */
    val highlight: Rgba get() = Rgba.hex(defaultHighlighter.hex, highlightAlpha)

    /** Fill behind selected text. */
    val selection: Rgba get() = accent.withAlpha(0.28)

    val isDark: Boolean get() = this == NIGHT || this == SLATE

    /** The name under the swatch. */
    val title: String
        get() = when (this) {
            PAPER -> "Paper"
            SEPIA -> "Sepia"
            NIGHT -> "Night"
            SLATE -> "Slate"
        }

    /**
     * The four swatches this ground is worth reading on, in the order the
     * picker draws them — the default first.
     */
    val highlighterPresets: List<HighlighterPreset>
        get() = if (isDark) {
            listOf(HighlighterPreset.AMBER, HighlighterPreset.SAGE, HighlighterPreset.BLUSH, HighlighterPreset.IRIS)
        } else {
            listOf(HighlighterPreset.TANGERINE, HighlighterPreset.MOSS, HighlighterPreset.ROSE, HighlighterPreset.PLUM)
        }

    /** What this page colour highlights with when the reader has chosen nothing. */
    val defaultHighlighter: HighlighterPreset
        get() = if (isDark) HighlighterPreset.AMBER else HighlighterPreset.TANGERINE

    /**
     * How much of the paper a preset lets through. A dark page needs more of
     * the marker to read as marked at all. A *custom* colour keeps whatever
     * opacity the reader picked instead — see [highlightColor].
     */
    val highlightAlpha: Double get() = if (isDark) 0.30 else 0.22

    /** The fill behind the narrated sentence, given this page colour's choice. */
    fun highlightColor(choice: HighlighterChoice?): Rgba = when (choice) {
        null -> highlight
        is HighlighterChoice.Preset -> Rgba.hex(choice.preset.hex, highlightAlpha)
        is HighlighterChoice.Custom -> choice.tint.rgba
    }

    companion object {
        fun fromRawValue(raw: String): ReaderTheme? = entries.firstOrNull { it.rawValue == raw }
    }
}
