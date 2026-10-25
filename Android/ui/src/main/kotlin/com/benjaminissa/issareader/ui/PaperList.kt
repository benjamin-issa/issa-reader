package com.benjaminissa.issareader.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/*
 * The app's grouped lists: the iPhone's inset-grouped `List` on paper, with
 * surface rows in rounded cards, a quiet header above each section and the
 * sentence that explains it underneath (`PaperList`, `SettingsSection`,
 * `SettingsFooter` in Swift). The controls inside the rows are Material's —
 * switches and menus — in the palette's colours.
 */

/** Corner of a grouped card, as iOS 26 draws an inset-grouped section. */
val PaperCardRadius: Dp = 24.dp

/** A grouped list on the paper ground. */
@Composable
fun PaperList(
    modifier: Modifier = Modifier,
    state: LazyListState = rememberLazyListState(),
    contentPadding: PaddingValues = PaddingValues(bottom = Metrics.spacing32),
    content: LazyListScope.() -> Unit,
) {
    LazyColumn(
        modifier = modifier.background(Palette.paper),
        state = state,
        contentPadding = contentPadding,
        content = content,
    )
}

/** Builds the rows of one [PaperSection]; each row is separated from the last by a hairline. */
class PaperSectionScope internal constructor() {
    internal val rows = mutableListOf<Pair<Dp, @Composable () -> Unit>>()

    /**
     * One row. [dividerStart] is where the hairline *above the next row*
     * begins, measured from the card's leading edge: past an icon, as iOS
     * insets a separator to a row's text.
     */
    fun row(dividerStart: Dp = ROW_PADDING, content: @Composable () -> Unit) {
        rows += dividerStart to content
    }
}

private val ROW_PADDING = 16.dp

/** One grouped section as a list item: header, the card of rows, and its footer sentence. */
fun LazyListScope.paperSection(
    key: Any? = null,
    header: String? = null,
    footer: String? = null,
    headerContent: (@Composable RowScope.() -> Unit)? = null,
    rows: PaperSectionScope.() -> Unit,
) {
    item(key = key) { PaperSection(header, footer, headerContent = headerContent, rows = rows) }
}

/** One grouped section: an optional header, the rows in a rounded surface card, and an optional footer sentence. */
@Composable
fun PaperSection(
    header: String? = null,
    footer: String? = null,
    modifier: Modifier = Modifier,
    headerContent: (@Composable RowScope.() -> Unit)? = null,
    rows: PaperSectionScope.() -> Unit,
) {
    val scope = PaperSectionScope().apply(rows)
    Column(modifier.fillMaxWidth().padding(horizontal = Metrics.screenMargin)) {
        if (header != null || headerContent != null) {
            Row(
                Modifier.padding(start = ROW_PADDING, end = ROW_PADDING, top = Metrics.spacing24, bottom = Metrics.spacing8),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Metrics.spacing8),
            ) {
                if (header != null) SectionHeaderText(header)
                headerContent?.invoke(this)
            }
        } else {
            Spacer(Modifier.padding(top = Metrics.spacing24))
        }
        if (scope.rows.isNotEmpty()) {
            Column(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(PaperCardRadius))
                    .background(Palette.surface),
            ) {
                scope.rows.forEachIndexed { index, (dividerStart, content) ->
                    if (index > 0) {
                        HorizontalDivider(
                            modifier = Modifier.padding(start = scope.rows[index - 1].first, end = ROW_PADDING),
                            thickness = 0.5.dp,
                            color = Palette.border,
                        )
                    }
                    content()
                }
            }
        }
        if (footer != null) SettingsFooter(footer, Modifier.padding(horizontal = ROW_PADDING, vertical = Metrics.spacing8))
    }
}

/** A section's header: the system face, sentence case, quiet. */
@Composable
fun SectionHeaderText(text: String, modifier: Modifier = Modifier) {
    Text(text, modifier = modifier, style = SystemText.subheadline.copy(fontWeight = FontWeight.SemiBold), color = Palette.inkTertiary)
}

/** The sentence under a settings section, which says what its rows do. */
@Composable
fun SettingsFooter(text: String, modifier: Modifier = Modifier) {
    WrappingText(text, modifier = modifier.fillMaxWidth(), style = Typography.footnote, color = Palette.inkSecondary)
}

/** The frame every row shares: its height, padding and, when tappable, its touch target. */
@Composable
fun PaperRowFrame(
    modifier: Modifier = Modifier,
    onClick: (() -> Unit)? = null,
    role: Role = Role.Button,
    content: @Composable RowScope.() -> Unit,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = 50.dp)
            .then(if (onClick != null) Modifier.clickable(role = role, onClick = onClick) else Modifier)
            .padding(horizontal = ROW_PADDING, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Metrics.spacing12),
        content = content,
    )
}

/** A leading row icon at the system size, in ink (an SF Symbol in a `Label`). */
@Composable
fun RowIcon(icon: Int, tint: Color = Palette.ink) {
    Icon(painterResource(icon), contentDescription = null, tint = tint, modifier = Modifier.size(22.dp))
}

/** Title and value, as `LabeledContent`. */
@Composable
fun LabeledRow(title: String, value: String?, modifier: Modifier = Modifier, icon: Int? = null) {
    PaperRowFrame(modifier) {
        icon?.let { RowIcon(it) }
        TitleAndValue(
            title = { Text(title, style = SystemText.body, color = Palette.ink) },
            value = value?.let { { Text(it, style = SystemText.body, color = Palette.inkTertiary, maxLines = 1, overflow = TextOverflow.Ellipsis) } },
            modifier = Modifier.weight(1f),
        )
    }
}

/**
 * A title at the leading edge and a value at the trailing one, as
 * `LabeledContent` lays them out: the value takes the width it needs, and
 * only when both cannot fit does it give way, keeping the title at least
 * 45 % of the row before truncating.
 */
@Composable
fun TitleAndValue(title: @Composable () -> Unit, value: (@Composable () -> Unit)?, modifier: Modifier = Modifier, gap: Dp = Metrics.spacing12) {
    Layout(
        modifier = modifier,
        content = {
            title()
            value?.invoke()
        },
    ) { measurables, constraints ->
        val width = constraints.maxWidth
        val gapPx = gap.roundToPx()
        val titleMeasurable = measurables[0]
        val valueMeasurable = measurables.getOrNull(1)
        val titleWanted = titleMeasurable.maxIntrinsicWidth(constraints.maxHeight)
        val valueMax = if (valueMeasurable == null) 0 else (width - gapPx - minOf(titleWanted, (width * 0.45f).toInt())).coerceAtLeast(0)
        val valuePlaceable = valueMeasurable?.measure(Constraints(maxWidth = valueMax, maxHeight = constraints.maxHeight))
        val titleMax = (width - (valuePlaceable?.width?.plus(gapPx) ?: 0)).coerceAtLeast(0)
        val titlePlaceable = titleMeasurable.measure(Constraints(maxWidth = titleMax, maxHeight = constraints.maxHeight))
        val height = maxOf(titlePlaceable.height, valuePlaceable?.height ?: 0)
        layout(width, height) {
            titlePlaceable.place(0, (height - titlePlaceable.height) / 2)
            valuePlaceable?.place(width - valuePlaceable.width, (height - valuePlaceable.height) / 2)
        }
    }
}

/** A row that opens another screen: optional icon, title, optional value, and a chevron. */
@Composable
fun NavigationRow(title: String, onClick: () -> Unit, modifier: Modifier = Modifier, icon: Int? = null, value: String? = null) {
    PaperRowFrame(modifier, onClick = onClick) {
        icon?.let { RowIcon(it) }
        Text(title, style = SystemText.body, color = Palette.ink, modifier = Modifier.weight(1f))
        if (value != null) Text(value, style = SystemText.body, color = Palette.inkTertiary, maxLines = 1)
        Icon(painterResource(Symbols.chevronRight), contentDescription = null, tint = Palette.inkQuaternary, modifier = Modifier.size(20.dp))
    }
}

/** A row with a Material switch in the accent colour. */
@Composable
fun ToggleRow(title: String, checked: Boolean, onCheckedChange: (Boolean) -> Unit, modifier: Modifier = Modifier, icon: Int? = null, enabled: Boolean = true) {
    PaperRowFrame(modifier, onClick = if (enabled) ({ onCheckedChange(!checked) }) else null, role = Role.Switch) {
        icon?.let { RowIcon(it) }
        Text(title, style = SystemText.body, color = if (enabled) Palette.ink else Palette.inkTertiary, modifier = Modifier.weight(1f))
        Switch(
            checked = checked,
            onCheckedChange = onCheckedChange,
            enabled = enabled,
            colors = SwitchDefaults.colors(
                checkedThumbColor = Color.White,
                checkedTrackColor = Palette.tangerine,
                checkedBorderColor = Palette.tangerine,
                uncheckedThumbColor = Palette.inkQuaternary,
                uncheckedTrackColor = Palette.surfaceRaised,
                uncheckedBorderColor = Palette.borderStrong,
            ),
        )
    }
}

/**
 * A row that picks one of several values: the iPhone's menu picker, its
 * current value in the accent colour with the up-and-down chevron, opening a
 * Material menu anchored to the row.
 */
@Composable
fun <T> PickerRow(
    title: String,
    selection: T,
    options: List<T>,
    label: (T) -> String,
    onSelect: (T) -> Unit,
    modifier: Modifier = Modifier,
    icon: Int? = null,
    enabled: Boolean = true,
) {
    var open by remember { mutableStateOf(false) }
    Box(modifier) {
        PaperRowFrame(onClick = if (enabled) ({ open = true }) else null) {
            icon?.let { RowIcon(it) }
            Text(title, style = SystemText.body, color = Palette.ink, modifier = Modifier.weight(1f))
            Text(label(selection), style = SystemText.body, color = if (enabled) Palette.tangerine else Palette.inkTertiary, maxLines = 1)
            Icon(painterResource(Symbols.chevronUpChevronDown), contentDescription = null, tint = if (enabled) Palette.tangerine else Palette.inkTertiary, modifier = Modifier.size(16.dp))
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }, containerColor = Palette.surface) {
            for (option in options) {
                DropdownMenuItem(
                    text = { Text(label(option), style = SystemText.body, color = Palette.ink) },
                    trailingIcon = if (option == selection) {
                        { Icon(painterResource(Symbols.checkmark), contentDescription = "Selected", tint = Palette.tangerine) }
                    } else {
                        null
                    },
                    onClick = {
                        open = false
                        onSelect(option)
                    },
                )
            }
        }
    }
}

/** A row that acts: in the accent colour, or the alert colour when it destroys something. */
@Composable
fun ButtonRow(title: String, onClick: () -> Unit, modifier: Modifier = Modifier, destructive: Boolean = false, enabled: Boolean = true, icon: Int? = null) {
    val color = when {
        !enabled -> Palette.inkTertiary
        destructive -> Palette.alert
        else -> Palette.tangerine
    }
    PaperRowFrame(modifier, onClick = if (enabled) onClick else null) {
        icon?.let { RowIcon(it, tint = color) }
        Text(title, style = SystemText.body, color = color)
    }
}

/** A numeric row with the −/+ stepper (`ValueStepper`). Material has no stepper, so this one is drawn. */
@Composable
fun StepperRow(
    title: String,
    value: Double,
    range: ClosedFloatingPointRange<Double>,
    onValueChange: (Double) -> Unit,
    modifier: Modifier = Modifier,
    step: Double = 1.0,
    format: (Double) -> String = { it.toInt().toString() },
) {
    PaperRowFrame(modifier) {
        Text(title, style = SystemText.body, color = Palette.ink, modifier = Modifier.weight(1f))
        Text(format(value), style = SystemText.body.copy(fontFeatureSettings = "tnum"), color = Palette.inkSecondary)
        Stepper(value, range, step, onValueChange)
    }
}

/** The −/+ pill on its own. */
@Composable
fun Stepper(value: Double, range: ClosedFloatingPointRange<Double>, step: Double, onValueChange: (Double) -> Unit, modifier: Modifier = Modifier) {
    Row(
        modifier.clip(RoundedCornerShape(50)).background(Palette.surfaceRaised),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        StepperHalf("−", enabled = value - step >= range.start - 1e-9, description = "Decrease") { onValueChange((value - step).coerceIn(range)) }
        Box(Modifier.width(1.dp).heightIn(min = 18.dp).background(Palette.borderStrong))
        StepperHalf("+", enabled = value + step <= range.endInclusive + 1e-9, description = "Increase") { onValueChange((value + step).coerceIn(range)) }
    }
}

@Composable
private fun StepperHalf(symbol: String, enabled: Boolean, description: String, onClick: () -> Unit) {
    Box(
        Modifier
            .width(46.dp)
            .heightIn(min = 34.dp)
            .clickable(enabled = enabled, role = Role.Button, onClickLabel = description, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(symbol, style = SystemText.title3.copy(fontSize = 22.sp), color = if (enabled) Palette.ink else Palette.inkQuaternary)
    }
}

/** Free-form content inside a section card, padded like a row. */
@Composable
fun PaperRowContent(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    Column(modifier.fillMaxWidth().padding(horizontal = ROW_PADDING, vertical = 12.dp), content = content)
}
