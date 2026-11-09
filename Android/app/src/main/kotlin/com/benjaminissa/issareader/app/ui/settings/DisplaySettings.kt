package com.benjaminissa.issareader.app.ui.settings

import android.os.Build
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import com.benjaminissa.issareader.app.model.PlaybackSettings
import com.benjaminissa.issareader.render.EInkNarrationMark
import com.benjaminissa.issareader.ui.Metrics
import com.benjaminissa.issareader.ui.Palette
import com.benjaminissa.issareader.ui.PaperRowContent
import com.benjaminissa.issareader.ui.SystemText
import com.benjaminissa.issareader.ui.ToggleRow
import com.benjaminissa.issareader.ui.paperSection

/**
 * The Display section: E-Ink mode, and while it is on how it marks the
 * sentence being read aloud. Shown on the main list and on the settings sheet
 * of an app with no server, since an E Ink reader may well have none.
 */
internal fun LazyListScope.displaySection(settings: PlaybackSettings) {
    paperSection(key = "display", header = "Display", footer = DisplaySettings.footer(settings.einkMode)) {
        row { EInkModeRow(settings) }
        if (settings.einkMode) row { NarrationMarkRow(settings) }
    }
}

/**
 * The switch, which only moves after the warning. It warns on the way on and
 * not on the way off, drawn in the theme the app is in: on a colour screen this
 * is the last thing that looks as it did.
 */
@Composable
private fun EInkModeRow(settings: PlaybackSettings) {
    var confirming by rememberSaveable { mutableStateOf(false) }
    ToggleRow(
        "E-Ink mode",
        checked = settings.einkMode,
        onCheckedChange = { on -> if (on) confirming = true else settings.einkMode = false },
        modifier = Modifier.testTag("settings.einkMode"),
    )
    if (confirming) {
        ChoiceDialog(
            title = DisplaySettings.WARNING_TITLE,
            message = DisplaySettings.WARNING,
            choices = listOf(
                DialogChoice("Turn on") {
                    confirming = false
                    settings.einkMode = true
                },
            ),
            onDismiss = { confirming = false },
        )
    }
}

@Composable
private fun NarrationMarkRow(settings: PlaybackSettings) {
    PaperRowContent {
        Text("Narration mark", style = SystemText.body, color = Palette.ink)
        Spacer(Modifier.height(Metrics.spacing12))
        SegmentedPicker(
            options = EInkNarrationMark.entries,
            selection = settings.einkNarrationMark,
            label = { it.title },
            onSelect = { settings.einkNarrationMark = it },
        )
    }
}

/** The section's words, without the section. */
internal object DisplaySettings {
    const val OFF_NOTE = "For E Ink screens, such as the Boox Palma. Black and white, no animation, outlines instead of colour."
    const val ON_NOTE = "How the sentence being read aloud is marked. Inverted is the boldest, but it redraws the most of the screen."
    const val BOOX_NOTE = "On Boox devices, set Issa Reader to HD in Control Center › EinkWise for the sharpest text."
    const val WARNING_TITLE = "Turn on E-Ink mode?"
    const val WARNING = "E-Ink mode is designed for E Ink screens, such as the Boox Palma. It switches Issa Reader to black and white, " +
        "turns off animations, and replaces colour and shading with outlines and underlines.\n\n" +
        "On a colour LCD or OLED screen the app will look plain and stark. You can turn it off here at any time."

    /** The note under the section; the refresh mode is Boox's own setting, so only a Boox hears about it. */
    fun footer(einkMode: Boolean, manufacturer: String = Build.MANUFACTURER): String = when {
        !einkMode -> OFF_NOTE
        isBoox(manufacturer) -> "$ON_NOTE\n\n$BOOX_NOTE"
        else -> ON_NOTE
    }

    private fun isBoox(manufacturer: String): Boolean = manufacturer.uppercase() in setOf("ONYX", "BOOX")
}
