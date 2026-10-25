package com.benjaminissa.issareader.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.benjaminissa.issareader.render.HighlightTint
import com.benjaminissa.issareader.render.HighlighterChoice
import com.benjaminissa.issareader.render.HighlighterPreset
import com.benjaminissa.issareader.render.ReaderTheme

/**
 * The highlighter control for one page colour, as swatches.
 *
 * Beside `ThemePicker` and built the same way, because it answers the second
 * half of the same question: that one picks the paper, this one picks the pen.
 * Only the four swatches that suit the ground in force are offered, plus a
 * fifth that opens a colour picker for a colour of the reader's own.
 *
 * Picking the ground's own default stores *nothing* (`null`), which is what
 * makes "this page colour has been changed" answerable as `selection != null`
 * everywhere else.
 */
@Composable
fun HighlighterPicker(
    theme: ReaderTheme,
    selection: HighlighterChoice?,
    onSelect: (HighlighterChoice?) -> Unit,
    modifier: Modifier = Modifier,
) {
    var picking by remember { mutableStateOf(false) }
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(vertical = Metrics.spacing4)
            .semantics { contentDescription = "Highlighter" },
        horizontalArrangement = Arrangement.spacedBy(Metrics.spacing12, Alignment.CenterHorizontally),
    ) {
        val current = selection ?: HighlighterChoice.Preset(theme.defaultHighlighter)
        for (preset in theme.highlighterPresets) {
            val isSelected = current == HighlighterChoice.Preset(preset)
            Ringed(
                selected = isSelected,
                modifier = Modifier
                    .clickable(role = Role.RadioButton) {
                        onSelect(if (preset == theme.defaultHighlighter) null else HighlighterChoice.Preset(preset))
                    }
                    .semantics {
                        contentDescription = preset.title
                        this.selected = isSelected
                    },
            ) {
                // At full strength, not at the alpha the page paints: four
                // washes of 22 % on a white row are four barely different greys.
                Box(Modifier.size(DIAMETER).background(hex(preset.hex), CircleShape))
            }
        }
        val isCustom = selection is HighlighterChoice.Custom
        Ringed(
            selected = isCustom,
            modifier = Modifier
                .clickable(role = Role.Button) { picking = true }
                .semantics {
                    contentDescription = "Custom colour"
                    this.selected = isCustom
                },
        ) {
            Box(
                Modifier
                    .size(DIAMETER)
                    .clip(CircleShape)
                    .background(Brush.sweepGradient(RAINBOW)),
            )
        }
    }
    if (picking) {
        // Opens on the colour the page is actually using — including a preset,
        // so "nearly that, but greener" starts from the right place.
        val start = theme.highlightColor(selection)
        ColorPickerDialog(
            initial = start.color,
            onDismiss = { picking = false },
            onPick = { color ->
                picking = false
                onSelect(HighlighterChoice.Custom(HighlightTint(color.red.toDouble(), color.green.toDouble(), color.blue.toDouble(), color.alpha.toDouble())))
            },
        )
    }
}

/** Diameter of a swatch, the ring's weight, and the clear space between them. */
private val DIAMETER = 36.dp
private val RING_WIDTH = 2.dp
private val RING_GAP = 3.dp

private val RAINBOW = listOf(Color.Red, Color.Yellow, Color.Green, Color.Cyan, Color.Blue, Color.Magenta, Color.Red)

/**
 * The selected ring sits *off* the colour it marks: a tangerine ring drawn
 * straight onto a tangerine swatch is invisible. Room for the ring is always
 * reserved, so the row keeps its height whether or not anything is selected.
 */
@Composable
private fun Ringed(selected: Boolean, modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Box(
        modifier = modifier
            .size(DIAMETER + (RING_GAP + RING_WIDTH) * 2)
            .border(RING_WIDTH, if (selected) Palette.ink else Color.Transparent, CircleShape),
        contentAlignment = Alignment.Center,
    ) { content() }
}
