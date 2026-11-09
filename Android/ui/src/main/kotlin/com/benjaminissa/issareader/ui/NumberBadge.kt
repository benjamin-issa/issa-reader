package com.benjaminissa.issareader.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

/**
 * A small number drawn on artwork: which book in a series a cover is, how many
 * books a series tile holds.
 *
 * One recipe for both marks, on its own slate ground because a cover is
 * arbitrary artwork and bare white digits vanish on a pale one. Tabular
 * figures, so a rail numbered 1, 3, 4 has badges the same width.
 */
@Composable
fun NumberBadge(text: String, modifier: Modifier = Modifier) {
    Text(
        text = text,
        style = Typography.caption.copy(fontWeight = FontWeight.Bold, fontFeatureSettings = "tnum"),
        color = Color.White,
        modifier = modifier
            .background(Palette.slate, CircleShape)
            .padding(horizontal = Metrics.spacing8, vertical = 2.dp),
    )
}
