package com.benjaminissa.issareader.app.ui.reading

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.benjaminissa.issareader.app.model.AppModel
import com.benjaminissa.issareader.app.ui.book.BookCover
import com.benjaminissa.issareader.app.ui.book.BookMenuBox
import com.benjaminissa.issareader.app.ui.shell.DownloadsRoute
import com.benjaminissa.issareader.app.ui.shell.LocalTabNavigator
import com.benjaminissa.issareader.app.ui.shell.appModel
import com.benjaminissa.issareader.core.download.DownloadsInventory
import com.benjaminissa.issareader.core.model.ByteCountText
import com.benjaminissa.issareader.ui.Metrics
import com.benjaminissa.issareader.ui.Overline
import com.benjaminissa.issareader.ui.Palette
import com.benjaminissa.issareader.ui.Typography

/**
 * What is on this device, and the one way to take it off again: the Reading
 * tab's Downloaded section. Swift's `DownloadsSection` in its `.reading`
 * placement — a few rows, a total, a link to the Downloads screen.
 *
 * **Nothing here starts a download.** It lists what a reader has already
 * chosen to keep and lets them stop keeping it. A row swipes away to remove
 * its edition — hidden now, deleted when the undo window closes — and its
 * long press is the book's menu with that removal last.
 */
@Composable
fun DownloadsSection(showAll: () -> Unit, modifier: Modifier = Modifier) {
    val app = appModel
    var scanned by remember { mutableStateOf(DownloadsInventory.empty) }
    // Keyed on everything that can mean the directory changed. A count is the
    // wrong shape for it — removing one edition of a two-edition book moves
    // no count — so the model's revision is part of the key. One keyed effect
    // rather than two walks racing to write their totals.
    val refreshKey = listOf(
        app.downloadsRevision,
        app.downloadedUuids.size,
        app.books.size,
        app.downloadsPending.map { it.first },
        app.pendingRemoval?.id,
    )
    LaunchedEffect(refreshKey) {
        scanned = DownloadsInventory.scan(app.books, app.downloadedUuids, scope = DownloadsInventory.Scope.BOOKS_ONLY)
    }
    // A removal still inside its undo window is out of the list and out of
    // the total: the bytes are still on disk, but the reader has said they
    // should not be.
    val pending = app.pendingRemoval?.id
    val items = scanned.items.filter { it.id != pending }
    val visible = items.take(READING_ROW_LIMIT)

    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(Metrics.spacing8)) {
        Header(items)
        if (items.isEmpty()) {
            EmptyState()
        } else {
            Text(HINT, style = Typography.caption, color = Palette.inkQuaternary)
            for (item in visible) {
                key(item.id) { RemovableRow(app, item) }
            }
            if (items.size > READING_ROW_LIMIT) {
                Text(
                    "Show all ${items.size}",
                    style = Typography.caption.copy(fontWeight = FontWeight.SemiBold),
                    color = Palette.tangerinePressed,
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 44.dp)
                        .clickable(role = Role.Button, onClick = showAll)
                        .padding(vertical = 14.dp),
                )
            }
        }
    }
}

/** The mockup's four: enough to be useful in a tab about something else. */
private const val READING_ROW_LIMIT = 4

/** Names the gesture this platform has. */
const val HINT = "Swipe a book left to remove it from this device. It stays in your library."

/** "4 books · 1.4 GB". Books, not rows: two editions of one book are one book. */
fun downloadsSummary(items: List<DownloadsInventory.DownloadedItem>): String {
    val count = DownloadsInventory.bookCount(items)
    return "$count book${if (count == 1) "" else "s"} · ${ByteCountText.text(DownloadsInventory.bytes(items))}"
}

/** "Read-along · Bram Stoker": the edition's own name, never the server's "Readaloud". */
fun metaLine(item: DownloadsInventory.DownloadedItem): String {
    val byline = item.book.byline
    return if (byline.isEmpty()) item.format.displayName else "${item.format.displayName} · $byline"
}

/** The heading: the overline, the total, and "Manage" into the Downloads screen. */
@Composable
private fun Header(items: List<DownloadsInventory.DownloadedItem>) {
    val navigator = LocalTabNavigator.current
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Overline("Downloaded", Modifier.weight(1f))
        Spacer(Modifier.width(Metrics.spacing8))
        Text(downloadsSummary(items), style = Typography.caption.copy(fontFeatureSettings = "tnum"), color = Palette.inkTertiary, maxLines = 1)
        Text(
            "Manage",
            style = Typography.caption.copy(fontWeight = FontWeight.SemiBold),
            color = Palette.tangerinePressed,
            modifier = Modifier
                .clickable(role = Role.Button, onClickLabel = "Manage downloads") { navigator.push(DownloadsRoute) }
                .padding(start = Metrics.spacing8, top = 14.dp, bottom = 14.dp),
        )
    }
}

/**
 * One row, which a swipe to the left removes: Material's swipe-to-dismiss
 * over the alert colour, the word Delete in paper on it. A tap opens the book
 * where the platform opens books; a long press is its menu.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun RemovableRow(app: AppModel, item: DownloadsInventory.DownloadedItem) {
    val state = rememberSwipeToDismissBoxState()
    val remove = { app.removeDownload(item.book.uuid, item.format, item.book.title) }
    LaunchedEffect(state.currentValue) {
        if (state.currentValue == SwipeToDismissBoxValue.EndToStart) remove()
    }
    BookMenuBox(item.book, focusEdition = item.format, onRemoveFocused = remove) { openMenu ->
        SwipeToDismissBox(
            state = state,
            enableDismissFromStartToEnd = false,
            modifier = Modifier.clip(RoundedCornerShape(Metrics.radiusMedium)),
            backgroundContent = {
                Box(
                    Modifier.fillMaxSize().background(Palette.alert).padding(horizontal = Metrics.spacing24),
                    contentAlignment = Alignment.CenterEnd,
                ) {
                    // Paper on alert, not white: the alert colour is the light
                    // half of its pair in the dark theme.
                    Text("Delete", style = Typography.callout.copy(fontWeight = FontWeight.SemiBold), color = Palette.paper)
                }
            },
        ) {
            DownloadRow(
                item,
                Modifier
                    .combinedClickable(
                        role = Role.Button,
                        onClick = { app.requestBook(item.book.uuid, AppModel.PendingBook.Destination.READ) },
                        onLongClick = openMenu,
                    )
                    .semantics { contentDescription = "${item.book.title}, ${metaLine(item)}, ${ByteCountText.text(item.bytes)}" },
            )
        }
    }
}

/** Cover, title in the reading face, edition and author, size on the right: `ResumeRow`'s card. */
@Composable
private fun DownloadRow(item: DownloadsInventory.DownloadedItem, modifier: Modifier = Modifier) {
    val shape = RoundedCornerShape(Metrics.radiusMedium)
    Row(
        Modifier
            .fillMaxWidth()
            .background(Palette.surface, shape)
            .border(1.dp, Palette.border, shape)
            .then(modifier)
            .padding(Metrics.spacing12),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Metrics.spacing12),
    ) {
        BookCover(item.book, Modifier.width(38.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(item.book.title, style = Typography.bookTitle, color = Palette.ink, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(metaLine(item), style = Typography.caption, color = Palette.inkTertiary, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        // Tabular, so a column of sizes lines up instead of dancing.
        Text(ByteCountText.text(item.bytes), style = Typography.caption.copy(fontFeatureSettings = "tnum"), color = Palette.inkSecondary)
    }
}

/** The dashed box: dashed rather than solid because there is nothing in it. */
@Composable
private fun EmptyState() {
    val stroke = Palette.borderStrong
    Column(
        Modifier
            .fillMaxWidth()
            .drawBehind {
                val radius = Metrics.radiusMedium.toPx()
                drawRoundRect(
                    color = stroke,
                    cornerRadius = CornerRadius(radius, radius),
                    style = Stroke(width = 1.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 4.dp.toPx()))),
                )
            }
            .padding(Metrics.spacing16)
            .semantics(mergeDescendants = true) {},
        verticalArrangement = Arrangement.spacedBy(Metrics.spacing4),
    ) {
        Text("Nothing on this device", style = Typography.callout, color = Palette.inkSecondary)
        Text("Download a book from its own screen and it will be listed here.", style = Typography.footnote, color = Palette.inkTertiary)
    }
}
