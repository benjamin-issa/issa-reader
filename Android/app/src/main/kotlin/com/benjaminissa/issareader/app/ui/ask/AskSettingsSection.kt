package com.benjaminissa.issareader.app.ui.ask

import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import com.benjaminissa.issareader.app.ask.AskCoordinator
import com.benjaminissa.issareader.app.ask.AskSettingsState
import com.benjaminissa.issareader.ui.BetaPill
import com.benjaminissa.issareader.ui.PaperSection
import com.benjaminissa.issareader.ui.ToggleRow

/**
 * The Ask section of Settings, as one item of the Settings list.
 *
 * Reading it asks ML Kit nothing: the section draws [AskCoordinator.settingsState],
 * which is only ever filled in after the reader has turned the switch on.
 * Availability is read again as the app comes forward — only while Ask is on —
 * by the coordinator itself, not by this screen.
 */
fun LazyListScope.askSettingsSection(coordinator: AskCoordinator, key: Any = "settings.ask") {
    item(key = key) { AskSettingsSection(coordinator) }
}

/** The section for a Settings screen that is not a lazy list. */
@Composable
fun AskSettingsSection(coordinator: AskCoordinator, modifier: Modifier = Modifier) {
    AskSettingsSection(coordinator.settingsState, onToggle = coordinator::setEnabled, modifier = modifier)
}

/**
 * The switch, and the one honest sentence under it.
 *
 * Always the switch, unlike the iPhone's — see [AskSettingsState] — with the
 * header the iPhone's, "Ask AI about this book" and its Beta capsule: read when
 * deciding whether to turn it on, which is when the hedge matters.
 */
@Composable
fun AskSettingsSection(state: AskSettingsState, onToggle: (Boolean) -> Unit, modifier: Modifier = Modifier) {
    PaperSection(
        header = "Ask AI about this book",
        footer = state.footer(),
        modifier = modifier,
        headerContent = { BetaPill() },
    ) {
        row {
            ToggleRow(
                title = "Ask about your book",
                checked = state.isOn,
                onCheckedChange = onToggle,
                modifier = Modifier.testTag("settings.ask.toggle"),
            )
        }
    }
}
