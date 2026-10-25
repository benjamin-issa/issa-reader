package com.benjaminissa.issareader.app.ui.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.BasicAlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberTopAppBarState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.benjaminissa.issareader.playback.Observed
import com.benjaminissa.issareader.ui.InlineTitleBar
import com.benjaminissa.issareader.ui.LargeTitleBar
import com.benjaminissa.issareader.ui.Metrics
import com.benjaminissa.issareader.ui.Overline
import com.benjaminissa.issareader.ui.Palette
import com.benjaminissa.issareader.ui.PaperList
import com.benjaminissa.issareader.ui.PaperRowContent
import com.benjaminissa.issareader.ui.PaperRowFrame
import com.benjaminissa.issareader.ui.Symbols
import com.benjaminissa.issareader.ui.SystemText
import com.benjaminissa.issareader.ui.Typography

/*
 * The pieces every settings screen shares: the pushed page with its title
 * bar, the segmented control, a grouped menu picker, the dialog that offers a
 * choice of several actions, and the quiet rows a section's content can hold.
 * Built from the design system's rows and Material's controls, in the palette.
 */

/** Where the hairline under a row with a leading icon starts: past the icon, at the text. */
internal val IconRowDivider = 50.dp

/**
 * One settings screen: the paper list under the iPhone's title bar — large,
 * collapsing as it scrolls, or inline — with a back button when it was pushed.
 *
 * @param listTag the list's test tag, the Swift view's `accessibilityIdentifier`.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalComposeUiApi::class)
@Composable
internal fun SettingsPage(
    title: String,
    onBack: (() -> Unit)?,
    modifier: Modifier = Modifier,
    largeTitle: Boolean = true,
    listTag: String? = null,
    actions: @Composable RowScope.() -> Unit = {},
    overlay: @Composable BoxScope.() -> Unit = {},
    content: LazyListScope.() -> Unit,
) {
    val behavior = if (largeTitle) {
        TopAppBarDefaults.exitUntilCollapsedScrollBehavior(rememberTopAppBarState())
    } else {
        TopAppBarDefaults.pinnedScrollBehavior(rememberTopAppBarState())
    }
    Scaffold(
        modifier = modifier
            .fillMaxSize()
            .semantics { testTagsAsResourceId = true }
            .nestedScroll(behavior.nestedScrollConnection),
        containerColor = Palette.paper,
        topBar = {
            if (largeTitle) {
                LargeTitleBar(title, behavior, onBack = onBack, actions = actions)
            } else {
                InlineTitleBar(title, onBack = onBack, actions = actions, scrollBehavior = behavior)
            }
        },
    ) { padding ->
        Box(Modifier.fillMaxSize()) {
            PaperList(
                modifier = Modifier.fillMaxSize().then(if (listTag != null) Modifier.testTag(listTag) else Modifier),
                contentPadding = PaddingValues(top = padding.calculateTopPadding(), bottom = padding.calculateBottomPadding() + Metrics.spacing32),
                content = content,
            )
            overlay()
        }
    }
}

/**
 * The iPhone's segmented picker, as Material's segmented buttons: the chosen
 * segment raised on the surface, the rest on the raised track, without the
 * check mark Material adds, which the iPhone's control does not have.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun <T> SegmentedPicker(
    options: List<T>,
    selection: T,
    label: (T) -> String,
    onSelect: (T) -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    SingleChoiceSegmentedButtonRow(modifier.fillMaxWidth()) {
        options.forEachIndexed { index, option ->
            val selected = option == selection
            SegmentedButton(
                selected = selected,
                onClick = { onSelect(option) },
                shape = SegmentedButtonDefaults.itemShape(index, options.size),
                enabled = enabled,
                icon = {},
                colors = SegmentedButtonDefaults.colors(
                    activeContainerColor = Palette.surface,
                    activeContentColor = Palette.ink,
                    activeBorderColor = Palette.borderStrong,
                    inactiveContainerColor = Palette.surfaceRaised,
                    inactiveContentColor = Palette.ink,
                    inactiveBorderColor = Palette.borderStrong,
                    disabledActiveContainerColor = Palette.surface,
                    disabledActiveContentColor = Palette.inkTertiary,
                    disabledActiveBorderColor = Palette.border,
                    disabledInactiveContainerColor = Palette.surfaceRaised,
                    disabledInactiveContentColor = Palette.inkTertiary,
                    disabledInactiveBorderColor = Palette.border,
                ),
                label = {
                    Text(
                        label(option),
                        style = SystemText.subheadline.copy(fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium),
                        maxLines = 1,
                    )
                },
            )
        }
    }
}

/** A segmented picker as a row of a section, padded like one. */
@Composable
internal fun <T> SegmentedRow(options: List<T>, selection: T, label: (T) -> String, onSelect: (T) -> Unit, modifier: Modifier = Modifier) {
    Box(modifier.fillMaxWidth().padding(horizontal = Metrics.spacing16, vertical = 10.dp)) {
        SegmentedPicker(options, selection, label, onSelect)
    }
}

/** One group of a [SectionedPickerRow]'s menu: a quiet heading and its choices. */
internal data class PickerGroup<T>(val title: String?, val options: List<T>)

/**
 * A menu picker whose choices come in groups, as a SwiftUI `Picker` with
 * `Section`s inside it: [com.benjaminissa.issareader.ui.PickerRow]'s face —
 * the value in the accent with the up-and-down chevron — over a Material
 * menu with a heading above each group and a rule between them.
 */
@Composable
internal fun <T> SectionedPickerRow(
    title: String,
    selection: T,
    groups: List<PickerGroup<T>>,
    label: (T) -> String,
    onSelect: (T) -> Unit,
    modifier: Modifier = Modifier,
) {
    var open by remember { mutableStateOf(false) }
    Box(modifier) {
        PaperRowFrame(onClick = { open = true }) {
            Text(title, style = SystemText.body, color = Palette.ink, modifier = Modifier.weight(1f))
            Text(label(selection), style = SystemText.body, color = Palette.tangerine, maxLines = 1)
            Icon(painterResource(Symbols.chevronUpChevronDown), contentDescription = null, tint = Palette.tangerine, modifier = Modifier.size(16.dp))
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }, containerColor = Palette.surface) {
            groups.forEachIndexed { index, group ->
                if (index > 0) HorizontalDivider(color = Palette.border, modifier = Modifier.padding(vertical = Metrics.spacing4))
                if (group.title != null) {
                    Text(
                        group.title,
                        style = SystemText.footnote,
                        color = Palette.inkTertiary,
                        modifier = Modifier.padding(horizontal = Metrics.spacing12, vertical = Metrics.spacing4),
                    )
                }
                for (option in group.options) {
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
}

/** One action a [ChoiceDialog] offers. */
internal data class DialogChoice(val title: String, val destructive: Boolean = false, val enabled: Boolean = true, val action: () -> Unit)

/**
 * A Material dialog offering several actions, stacked, with Cancel last: the
 * iPhone's confirmation dialog, which can offer more than the two buttons a
 * standard alert lays out side by side.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ChoiceDialog(
    title: String,
    choices: List<DialogChoice>,
    onDismiss: () -> Unit,
    message: String? = null,
    cancelTitle: String = "Cancel",
) {
    BasicAlertDialog(onDismissRequest = onDismiss) {
        // Material's alert frame: as wide as its content, between 280 and 560.
        Surface(
            modifier = Modifier.sizeIn(minWidth = 280.dp, maxWidth = 560.dp),
            shape = RoundedCornerShape(28.dp),
            color = Palette.surface,
            tonalElevation = 0.dp,
        ) {
            Column(Modifier.width(IntrinsicSize.Max).padding(top = Metrics.spacing24, bottom = Metrics.spacing12)) {
                Text(
                    title,
                    style = SystemText.title3,
                    color = Palette.ink,
                    modifier = Modifier.padding(horizontal = Metrics.spacing24),
                )
                if (message != null) {
                    Text(
                        message,
                        style = SystemText.subheadline,
                        color = Palette.inkSecondary,
                        modifier = Modifier.padding(start = Metrics.spacing24, end = Metrics.spacing24, top = Metrics.spacing12),
                    )
                }
                Column(
                    Modifier.fillMaxWidth().padding(start = Metrics.spacing12, end = Metrics.spacing12, top = Metrics.spacing16),
                    horizontalAlignment = Alignment.End,
                    verticalArrangement = Arrangement.spacedBy(0.dp),
                ) {
                    for (choice in choices) {
                        TextButton(onClick = choice.action, enabled = choice.enabled) {
                            Text(
                                choice.title,
                                style = SystemText.subheadline.copy(fontWeight = FontWeight.SemiBold),
                                color = when {
                                    !choice.enabled -> Palette.inkTertiary
                                    choice.destructive -> Palette.alert
                                    else -> Palette.tangerinePressed
                                },
                                textAlign = TextAlign.End,
                            )
                        }
                    }
                    TextButton(onClick = onDismiss) {
                        Text(cancelTitle, style = SystemText.subheadline.copy(fontWeight = FontWeight.SemiBold), color = Palette.tangerinePressed)
                    }
                }
            }
        }
    }
}

/** Colours for a Material alert's buttons in the palette: the accent, or the alert colour for one that destroys. */
@Composable
internal fun dialogButtonColor(destructive: Boolean): Color = if (destructive) Palette.alert else Palette.tangerinePressed

/** A sentence inside a section's card, as a row: the footnote ramp, quiet. */
@Composable
internal fun FootnoteRow(text: String, modifier: Modifier = Modifier, color: Color = Palette.inkTertiary) {
    PaperRowContent(modifier) { Text(text, style = Typography.footnote, color = color) }
}

/** An overline heading inside a section's card, as a row (`overlineStyle()` in a `List`). */
@Composable
internal fun OverlineRow(text: String, modifier: Modifier = Modifier) {
    PaperRowContent(modifier) { Overline(text) }
}

/**
 * Redraws when an observed playback object changes: Swift's `@Observable`,
 * through the revision [Observed] publishes. Reading the returned value is
 * what subscribes; null observes nothing.
 */
@Composable
internal fun Observed?.observe(): Long {
    val flow = remember(this) { this?.changes ?: kotlinx.coroutines.flow.MutableStateFlow(0L) }
    val value by flow.collectAsState()
    return value
}
