package com.benjaminissa.issareader.app.ui.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import com.benjaminissa.issareader.app.model.AppModel
import com.benjaminissa.issareader.app.ui.downloads.DownloadsPlacement
import com.benjaminissa.issareader.app.ui.downloads.downloadsSection
import com.benjaminissa.issareader.app.ui.downloads.rememberDownloadsSectionState
import com.benjaminissa.issareader.core.download.BookContentService
import com.benjaminissa.issareader.core.download.DownloadsInventory
import com.benjaminissa.issareader.core.model.ByteCountText
import com.benjaminissa.issareader.ui.ButtonRow
import com.benjaminissa.issareader.ui.Metrics
import com.benjaminissa.issareader.ui.Palette
import com.benjaminissa.issareader.ui.PaperRowContent
import com.benjaminissa.issareader.ui.SystemText
import com.benjaminissa.issareader.ui.ToggleRow
import com.benjaminissa.issareader.ui.Typography
import com.benjaminissa.issareader.ui.paperSection
import kotlin.math.roundToInt

/**
 * What is on this device, what is arriving, and how much room it all takes:
 * `DownloadsView.swift`.
 *
 * Read-along editions embed their audio, so a single book can be most of a
 * gigabyte. The rows themselves are [downloadsSection], the same component the
 * Reading tab draws; what is left here is the part only true of this screen —
 * the storage bar, the Wi-Fi setting, and the books whose entry in the library
 * has gone.
 *
 * @param scanned an inventory to draw instead of walking the disk: a screenshot's.
 */
@Composable
internal fun DownloadsScreen(app: AppModel, onBack: (() -> Unit)?, scanned: DownloadsInventory? = null) {
    var inventory by remember { mutableStateOf(scanned ?: DownloadsInventory.empty) }
    // Bumped by each sweep, so the one keyed effect below scans again rather
    // than a second scan racing it.
    var removals by remember { mutableIntStateOf(0) }
    var confirmingSweep by remember { mutableStateOf(false) }
    // Not snapshot state in the download manager, so mirrored here for the switch.
    var wifiOnly by remember { mutableStateOf(app.wifiOnlyDownloads) }

    // Rows appear and disappear as transfers finish, so the totals follow
    // rather than being read once — and one keyed effect, because two scans of
    // the disk in flight at once finish in whichever order they finish and
    // the loser writes its stale totals last. `downloadsRevision` because
    // removing one edition of a two-edition book moves no count.
    val refreshKey = listOf(
        app.downloadsRevision,
        app.downloadsPending.map { it.first },
        removals,
        app.downloadedUuids.size,
        app.books.size,
        app.pendingRemoval?.id,
    )
    if (scanned == null) {
        LaunchedEffect(refreshKey) {
            inventory = DownloadsInventory.scan(
                books = app.books,
                downloaded = DownloadsStorage.onDisk(app.downloadedUuids, app.pendingRemoval),
                scope = DownloadsInventory.Scope.EVERYTHING,
            )
        }
    }

    val segments = DownloadsStorage.segments(inventory, accountsForLibrary = app.books.isNotEmpty() && app.loadError == null)
    val sectionState = rememberDownloadsSectionState(DownloadsPlacement.MANAGE, inventory)

    SettingsPage(title = "Downloads", onBack = onBack) {
        // Free space is only worth stating when the scan produced a figure;
        // the second half of the sentence is true either way.
        val note = if (inventory.freeBytes > 0) {
            "${ByteCountText.text(inventory.freeBytes)} free on this device. Downloaded books open with no network at all."
        } else {
            "Downloaded books open with no network at all."
        }
        paperSection(key = "storage", footer = note) {
            row { StorageSummary(inventory.totalBytes, segments) }
        }

        paperSection(key = "metered", footer = "Applies to downloads you start from now on. A book already in progress carries on.") {
            row {
                ToggleRow("Download over Wi-Fi only", wifiOnly, {
                    wifiOnly = it
                    app.wifiOnlyDownloads = it
                })
            }
        }

        // The same component the Reading tab draws, transfers included, handed
        // the inventory this screen has already scanned.
        downloadsSection(sectionState, placement = DownloadsPlacement.MANAGE)

        // Offered rather than swept automatically, and only once the catalogue
        // has actually arrived: "absent from the library" is not the same
        // claim as "the reader no longer owns it" while a refresh has failed
        // or none has run.
        if (inventory.orphans.isNotEmpty() && app.books.isNotEmpty() && app.loadError == null) {
            val count = inventory.orphans.size
            paperSection(
                key = "orphans",
                header = "No longer in your library",
                // `orphanBytes`, not `unaccountedBytes`: the sweep deletes the
                // files this app can name, and promising the larger number
                // offered to free space the button would not free.
                footer = "${ByteCountText.text(inventory.orphanBytes)} of downloads whose books are not in your library any more. They have no row above, so this is the only way to reclaim the space.",
            ) {
                row {
                    ButtonRow(
                        "Remove $count orphaned file${if (count == 1) "" else "s"}",
                        onClick = { confirmingSweep = true },
                        destructive = true,
                    )
                }
            }
        }
    }

    if (confirmingSweep) {
        AlertDialog(
            onDismissRequest = { confirmingSweep = false },
            containerColor = Palette.surface,
            title = { Text("Remove ${ByteCountText.text(inventory.orphanBytes)} of downloads?", style = SystemText.title3, color = Palette.ink) },
            text = {
                Text(
                    "These files belong to books that are no longer in your library. Nothing you can still see in the app is affected.",
                    style = SystemText.subheadline,
                    color = Palette.inkSecondary,
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    confirmingSweep = false
                    // Through `removeDownload`, one file at a time, so an
                    // orphan is deleted by exactly the code that deletes
                    // anything else — extracted narration, question index and
                    // publisher font included.
                    for (orphan in inventory.orphans) app.removeDownload(orphan.bookUuid, orphan.format)
                    removals += 1
                }) { Text("Remove", style = SystemText.subheadline.copy(fontWeight = FontWeight.SemiBold), color = dialogButtonColor(destructive = true)) }
            },
            dismissButton = {
                TextButton(onClick = { confirmingSweep = false }) {
                    Text("Keep", style = SystemText.subheadline.copy(fontWeight = FontWeight.SemiBold), color = dialogButtonColor(destructive = false))
                }
            },
        )
    }
}

/** The headline, the bar and its legend. */
@Composable
private fun StorageSummary(totalBytes: Long, segments: List<DownloadsStorage.Segment>) {
    PaperRowContent(Modifier.padding(vertical = Metrics.spacing8)) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.spacing12)) {
            Column {
                Text(ByteCountText.text(totalBytes), style = Typography.title, color = Palette.ink)
                Text("used by Issa Reader", style = Typography.caption, color = Palette.inkTertiary)
            }
            StorageBar(totalBytes, segments)
            // A legend, not a chart key: each band is named with its size so
            // the bar is readable without colour perception.
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                for (segment in segments) {
                    Row(
                        Modifier.fillMaxWidth().semantics(mergeDescendants = true) {},
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(Metrics.spacing8),
                    ) {
                        Box(Modifier.size(10.dp).clip(RoundedCornerShape(2.dp)).background(segment.color()))
                        Text(segment.label, style = Typography.caption, color = Palette.inkSecondary, modifier = Modifier.weight(1f))
                        Text(
                            ByteCountText.text(segment.bytes),
                            style = Typography.caption.copy(fontFeatureSettings = "tnum"),
                            color = Palette.inkTertiary,
                        )
                    }
                }
            }
        }
    }
}

/**
 * The bands side by side, each as wide as its share, never thinner than three
 * points: a band under a couple of points reads as a gap, and a small download
 * should still visibly be there.
 */
@Composable
private fun StorageBar(totalBytes: Long, segments: List<DownloadsStorage.Segment>) {
    val colors = segments.map { it.color() }
    val empty = Palette.border
    Box(
        Modifier
            .fillMaxWidth()
            .height(10.dp)
            .clip(RoundedCornerShape(5.dp))
            .clearAndSetSemantics { contentDescription = "Storage used: ${ByteCountText.text(totalBytes)}" },
    ) {
        if (segments.isEmpty()) {
            Spacer(Modifier.fillMaxWidth().height(10.dp).background(empty))
        } else {
            Layout(
                content = { colors.forEach { Box(Modifier.background(it)) } },
                modifier = Modifier.fillMaxWidth().height(10.dp),
            ) { measurables, constraints ->
                val width = constraints.maxWidth
                val height = constraints.maxHeight
                val gap = 1.5.dp.toPx()
                val floor = 3.dp.roundToPx()
                val total = maxOf(segments.sumOf { it.bytes }.toDouble(), 1.0)
                val widths = segments.map { maxOf(floor, (width * it.bytes / total).roundToInt()) }
                val placeables = measurables.mapIndexed { index, measurable -> measurable.measure(Constraints.fixed(widths[index], height)) }
                layout(width, height) {
                    var x = 0f
                    for (placeable in placeables) {
                        placeable.place(x.roundToInt(), 0)
                        x += placeable.width + gap
                    }
                }
            }
        }
    }
}

/** The storage screen's arithmetic, without the screen. */
internal object DownloadsStorage {
    /** One band of the bar: its name, its size, and which palette colour draws it. */
    data class Segment(val label: String, val bytes: Long, val color: @Composable () -> Color)

    /**
     * The bands, in the order they are drawn, each with at least a byte in it.
     *
     * Every byte in the headline is in exactly one of these but the last: until
     * the catalogue has arrived there is no honest way to say a download is
     * "no longer in your library", so those bytes are in the headline and in
     * no band for as long as that is true — rather than drawing the reader's
     * whole shelf in alert red on every cold launch.
     *
     * @param accountsForLibrary whether the catalogue has arrived and the last
     *   refresh worked, so "not in your library" is a claim the app can make.
     */
    fun segments(inventory: DownloadsInventory, accountsForLibrary: Boolean): List<Segment> = listOfNotNull(
        Segment(BookContentService.Format.READALOUD.displayName, inventory.byFormat[BookContentService.Format.READALOUD] ?: 0) { Palette.tangerine },
        Segment(BookContentService.Format.EBOOK.displayName, inventory.byFormat[BookContentService.Format.EBOOK] ?: 0) { Palette.moss },
        Segment(BookContentService.Format.AUDIOBOOK.displayName, inventory.byFormat[BookContentService.Format.AUDIOBOOK] ?: 0) { Palette.slate },
        // Narration extracted from a read-along for playback: real disk use
        // that no book row accounts for, so it gets its own band.
        Segment("Extracted narration", inventory.extractedAudioBytes) { Palette.borderStrong },
        Segment("Book fonts", inventory.publisherFontBytes) { Palette.inkTertiary },
        Segment("Covers", inventory.coverBytes) { Palette.inkQuaternary },
        // The question indexes: a full-text copy of a book's prose each, and
        // the largest derived store the app keeps.
        Segment("Question indexes", inventory.askIndexBytes) { Palette.moss.copy(alpha = 0.55f) },
        if (accountsForLibrary) Segment("No longer in your library", inventory.unaccountedBytes) { Palette.alert } else null,
    ).filter { it.bytes > 0 }

    /**
     * The books whose files are on disk, which during a removal's undo window
     * is one more than `downloadedUuids` says: the app's set already leaves
     * out the book being removed, but its file is still there, and the scan
     * would count it as no longer in the library — an alert-red band for the
     * book just swiped away, under a toast offering to undo it.
     */
    fun onDisk(downloaded: Set<String>, pending: AppModel.PendingRemoval?): Set<String> =
        if (pending == null) downloaded else downloaded + pending.bookUuid
}
