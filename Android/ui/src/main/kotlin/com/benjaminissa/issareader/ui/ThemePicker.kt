package com.benjaminissa.issareader.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.benjaminissa.issareader.render.ReaderTheme

/**
 * The page-colour control, as swatches.
 *
 * One view rather than two: it appears both in Settings and in the reader's
 * "Aa" sheet, and two copies of a four-way picker drift. Each swatch is painted
 * in its own theme's colours — never palette tokens — because the page's
 * appearance is the reader's choice, so Paper must look like paper even when
 * the phone is in dark theme.
 */
@Composable
fun ThemePicker(selection: ReaderTheme, onSelect: (ReaderTheme) -> Unit, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(vertical = Metrics.spacing4)
            .semantics { contentDescription = "Page colour" },
        horizontalArrangement = Arrangement.spacedBy(Metrics.spacing12),
    ) {
        for (theme in ReaderTheme.entries) {
            val isSelected = theme == selection
            Column(
                modifier = Modifier
                    .weight(1f)
                    .clickable(role = Role.RadioButton) { onSelect(theme) }
                    .semantics {
                        contentDescription = theme.title
                        selected = isSelected
                    },
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(Metrics.spacing8),
            ) {
                val shape = RoundedCornerShape(Metrics.radiusSmall)
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(52.dp)
                        .background(theme.background.color, shape)
                        .border(
                            width = if (isSelected) 2.dp else 0.5.dp,
                            color = if (isSelected) Palette.tangerine else Palette.border,
                            shape = shape,
                        ),
                    contentAlignment = Alignment.CenterStart,
                ) {
                    // Bars of "text" in the theme's own ink, so a swatch says
                    // what a page set in it will look like rather than only
                    // what colour the paper is.
                    Column(
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp),
                        verticalArrangement = Arrangement.spacedBy(5.dp),
                    ) {
                        val ink = theme.text.withAlpha(0.75).color
                        Spacer(Modifier.fillMaxWidth().height(3.dp).background(ink, CircleShape))
                        Spacer(Modifier.fillMaxWidth().height(3.dp).background(ink, CircleShape))
                        Spacer(Modifier.width(18.dp).height(3.dp).background(ink, CircleShape))
                    }
                }
                Text(
                    text = theme.title,
                    style = Typography.caption,
                    color = if (isSelected) Palette.ink else Palette.inkTertiary,
                )
            }
        }
    }
}
