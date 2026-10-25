// A stub with the screens port's API: the screens port replaces this file with
// the real `DownloadsSection` (the download rows the Reading tab and Settings ›
// Downloads & storage both draw). Until then it draws nothing.
package com.benjaminissa.issareader.app.ui.downloads

import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import com.benjaminissa.issareader.core.download.DownloadsInventory

/** Where the section is drawn: the Reading tab's rail, or the storage screen's full list. */
enum class DownloadsPlacement { READING, MANAGE }

/** The section's state: what it has scanned and which rows are open. */
class DownloadsSectionState

@Composable
fun rememberDownloadsSectionState(placement: DownloadsPlacement, inventory: DownloadsInventory? = null): DownloadsSectionState =
    remember(placement) { DownloadsSectionState() }

@Suppress("UNUSED_PARAMETER")
fun LazyListScope.downloadsSection(
    state: DownloadsSectionState,
    placement: DownloadsPlacement = DownloadsPlacement.READING,
    showAll: (() -> Unit)? = null,
) {
    // Draws nothing: see the note at the top of this file.
}
