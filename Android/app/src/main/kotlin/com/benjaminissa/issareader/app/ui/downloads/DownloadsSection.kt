package com.benjaminissa.issareader.app.ui.downloads

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Snackbar
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.benjaminissa.issareader.app.model.AppModel
import com.benjaminissa.issareader.app.model.BookRouter
import com.benjaminissa.issareader.app.ui.book.BookCover
import com.benjaminissa.issareader.app.ui.book.BookMenuBox
import com.benjaminissa.issareader.app.ui.book.LocalBookRouter
import com.benjaminissa.issareader.app.ui.shell.DownloadsRoute
import com.benjaminissa.issareader.app.ui.shell.LocalTabNavigator
import com.benjaminissa.issareader.app.ui.shell.appModel
import com.benjaminissa.issareader.core.download.DownloadManager
import com.benjaminissa.issareader.core.download.DownloadsInventory
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.ByteCountText
import com.benjaminissa.issareader.ui.Metrics
import com.benjaminissa.issareader.ui.Overline
import com.benjaminissa.issareader.ui.Palette
import com.benjaminissa.issareader.ui.Symbols
import com.benjaminissa.issareader.ui.Typography
import kotlinx.coroutines.launch
import kotlin.math.min

/*
 * What is on this device, and the one way to take it off again: Swift's
 * `DownloadsSection`, one component drawn by two screens so that a redesign of
 * the downloads list is an edit here and nowhere else. The Reading tab shows
 * four rows and a link to the rest; the Downloads screen shows every row plus
 * the transfers still arriving. Both get the same row, the same menu — the
 * book's own, with the row's removal last — and the same removal.
 *
 * **Nothing here starts a download.** This is a management surface: it lists
 * what a reader has already chosen to keep and lets them stop keeping it. A
 * book is fetched from its own screen, where the edition being fetched is
 * visible and the size is stated before the tap.
 *
 * Drawn as rows of the screen's own lazy list. The section brings no side
 * margin of its own, as Swift's does not — the list it is in gives it one —
 * and carries its own gaps: each of its rows but the first sits 8 below the
 * one before, so the list should not space its items as well.
 */

/** Which surface is drawing the section. */
enum class DownloadsPlacement {
    /** The Reading tab: a few rows, a total, and a link to the full screen. */
    READING,

    /**
     * The Downloads screen itself: every row, the transfers still arriving,
     * and no link back to where you already are.
     */
    MANAGE,
}

/**
 * The section's state: what is on the disk — scanned here, or handed over by
 * a screen that already walks it for its storage bar — and the one row a
 * swipe has hold of. One at a time: two rows half swiped is two red strips
 * and no way to tell which a release means.
 */
@Stable
class DownloadsSectionState internal constructor(
    internal val app: AppModel,
    val placement: DownloadsPlacement,
) {
    /** What this section's own walk of the disk found; unused while [supplied] is set. */
    var scanned: DownloadsInventory by mutableStateOf(DownloadsInventory.empty)
        internal set

    /** The inventory the screen handed over, which the section uses instead of scanning. */
    var supplied: DownloadsInventory? by mutableStateOf(null)
        internal set

    /** The row a swipe has hold of, by item id. */
    var openRow: String? by mutableStateOf(null)

    val inventory: DownloadsInventory get() = supplied ?: scanned

    /**
     * The rows, with a removal still inside its undo window taken out: the
     * bytes are still on disk, deliberately, but the reader has said they
     * should not be.
     */
    val items: List<DownloadsInventory.DownloadedItem>
        get() {
            val pending = app.pendingRemoval?.id
            return inventory.items.filter { it.id != pending }
        }

    /** The rows drawn: four on the Reading tab, every one on the Downloads screen. */
    val visibleItems: List<DownloadsInventory.DownloadedItem>
        get() = if (placement == DownloadsPlacement.READING) items.take(READING_ROW_LIMIT) else items

    /**
     * Whether transfers are listed above the rows. Both the heading and the
     * empty state depend on it, and they must agree.
     */
    val showsTransfers: Boolean get() = placement == DownloadsPlacement.MANAGE && app.downloadsPending.isNotEmpty()

    /**
     * Hides the row now and deletes when the undo window closes. Nothing is
     * fetched to undo it.
     */
    fun remove(item: DownloadsInventory.DownloadedItem) {
        openRow = null
        app.removeDownload(item.book.uuid, item.format, item.book.title)
    }

    companion object {
        /** The mockup's four: enough to be useful in a tab about something else. */
        const val READING_ROW_LIMIT = 4
    }
}

/**
 * The section's state for [placement]. With [inventory] the section draws the
 * screen's own scan; without one it walks the Books directory itself — one
 * directory read, no recursion — whenever the app has reason to think it
 * changed.
 */
@Composable
fun rememberDownloadsSectionState(placement: DownloadsPlacement, inventory: DownloadsInventory? = null): DownloadsSectionState {
    val app = appModel
    val state = remember(app, placement) { DownloadsSectionState(app, placement) }
    SideEffect { state.supplied = inventory }
    // What the walk depends on, spelled so that any change to it is a change
    // to the key. A count is the wrong shape — removing one edition of a
    // two-edition book moves no count — so the model's revision is in it, and
    // the transfers by job rather than by length. One keyed effect, so two
    // walks never race to write their totals.
    val refreshKey = listOf(
        app.downloadsRevision,
        app.downloadedUuids.size,
        app.books.size,
        app.downloadsPending.map { it.first },
        app.pendingRemoval?.id,
    )
    LaunchedEffect(state, refreshKey, inventory == null) {
        if (inventory != null) return@LaunchedEffect
        state.scanned = DownloadsInventory.scan(app.books, app.downloadedUuids, scope = DownloadsInventory.Scope.BOOKS_ONLY)
    }
    return state
}

/** Swift's `DownloadsSection`, as rows of a LazyColumn. */
fun LazyListScope.downloadsSection(
    state: DownloadsSectionState,
    placement: DownloadsPlacement = DownloadsPlacement.READING,
    showAll: (() -> Unit)? = null,
) {
    val items = state.items
    val showsTransfers = state.showsTransfers
    if (showsTransfers) {
        // Without its own heading the transfers sat under "Downloaded",
        // labelled as the thing they are on their way to becoming.
        item(key = "downloads.transfersHeading") { Overline("Downloading") }
        items(state.app.downloadsPending, key = { "downloads.transfer.${it.first.bookUuid}-${it.first.format.rawValue}" }) { (job, transfer) ->
            TransferRow(state.app, job, transfer, Modifier.padding(top = Metrics.spacing8))
        }
    }
    item(key = "downloads.header") {
        Header(items, placement, Modifier.padding(top = if (showsTransfers) Metrics.spacing8 else 0.dp))
    }
    if (items.isEmpty()) {
        // Not while transfers are listed: "Nothing on this device" under
        // moving progress bars is the screen contradicting itself.
        if (!showsTransfers) item(key = "downloads.empty") { EmptyState(Modifier.padding(top = Metrics.spacing8)) }
        return
    }
    item(key = "downloads.hint") {
        Text(HINT, style = Typography.caption, color = Palette.inkQuaternary, modifier = Modifier.padding(top = Metrics.spacing8))
    }
    items(state.visibleItems, key = { "downloads.row.${it.id}" }) { item ->
        RemovableRow(state, item, Modifier.padding(top = Metrics.spacing8))
    }
    if (placement == DownloadsPlacement.READING && showAll != null && items.size > DownloadsSectionState.READING_ROW_LIMIT) {
        item(key = "downloads.showAll") {
            Text(
                "Show all ${items.size}",
                style = Typography.caption.copy(fontWeight = FontWeight.SemiBold),
                color = Palette.tangerinePressed,
                modifier = Modifier
                    .padding(top = Metrics.spacing8)
                    .fillMaxWidth()
                    .heightIn(min = 44.dp)
                    .clickable(role = Role.Button, onClick = showAll)
                    .padding(vertical = 14.dp),
            )
        }
    }
}

/** Names the gesture this platform has: a hint about a gesture the phone lacks is worse than none. */
const val HINT = "Swipe a book left to remove it from this device. It stays in your library."

/** "4 books · 1.4 GB". Books, not rows: two editions of one book are one book, and a reader counts books. */
fun downloadsSummary(items: List<DownloadsInventory.DownloadedItem>): String {
    val count = DownloadsInventory.bookCount(items)
    return "$count book${if (count == 1) "" else "s"} · ${ByteCountText.text(DownloadsInventory.bytes(items))}"
}

/** "Read-along · Bram Stoker": the edition's own name, never the server's "Readaloud". */
fun metaLine(item: DownloadsInventory.DownloadedItem): String {
    val byline = item.book.byline
    return if (byline.isEmpty()) item.format.displayName else "${item.format.displayName} · $byline"
}

/** What a screen reader says for a row. */
fun accessibilityLabel(item: DownloadsInventory.DownloadedItem): String =
    "${item.book.title}, ${metaLine(item)}, ${ByteCountText.text(item.bytes)}"

/** A transfer's line: the edition, then how far it has come. */
fun statusText(job: DownloadManager.Job, state: DownloadManager.State): String {
    val format = job.format.displayName
    return when (state) {
        DownloadManager.State.Queued -> "$format · Waiting"
        is DownloadManager.State.Downloading -> if (state.totalBytes <= 0) {
            "$format · ${ByteCountText.text(state.bytesWritten)}"
        } else {
            "$format · ${ByteCountText.text(state.bytesWritten)} of ${ByteCountText.text(state.totalBytes)} · ${(state.fractionCompleted * 100).toInt()}%"
        }
        is DownloadManager.State.Paused -> "$format · Paused at ${(state.fractionCompleted * 100).toInt()}%"
        DownloadManager.State.Finished -> "$format · Done"
        is DownloadManager.State.Failed -> state.reason
    }
}

/**
 * The item a context click, a double click or Delete is about, on a list
 * whose rows can be selected: the one row named, if it is still listed.
 * Several, or none, is no one row. Swift's `DownloadsRowCommands`, for the
 * Mac's list; kept so a selectable list here asks the same question.
 */
object DownloadsRowCommands {
    fun target(ids: Set<String>, items: List<DownloadsInventory.DownloadedItem>): DownloadsInventory.DownloadedItem? {
        if (ids.size != 1) return null
        val id = ids.first()
        return items.firstOrNull { it.id == id }
    }
}

/** The same shape as a rail's heading: the overline, the total, and on the Reading tab "Manage". */
@Composable
private fun Header(items: List<DownloadsInventory.DownloadedItem>, placement: DownloadsPlacement, modifier: Modifier = Modifier) {
    val navigator = LocalTabNavigator.current
    Row(modifier.fillMaxWidth().heightIn(min = 44.dp), verticalAlignment = Alignment.CenterVertically) {
        Overline("Downloaded", Modifier.weight(1f))
        Spacer(Modifier.width(Metrics.spacing8))
        Text(downloadsSummary(items), style = Typography.caption.copy(fontFeatureSettings = "tnum"), color = Palette.inkTertiary, maxLines = 1)
        if (placement == DownloadsPlacement.READING) {
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
}

/**
 * One row, which a swipe to the left removes, its long press the book's menu
 * with that removal last, and a tap opening the book where the phone opens
 * books.
 */
@Composable
private fun RemovableRow(state: DownloadsSectionState, item: DownloadsInventory.DownloadedItem, modifier: Modifier = Modifier) {
    val app = state.app
    val router = LocalBookRouter.current
    val open = { app.requestBook(item.book.uuid, AppModel.PendingBook.Destination.READ) }
    val remove = { state.remove(item) }
    BookMenuBox(item.book, modifier, focusEdition = item.format, onRemoveFocused = remove) { openMenu ->
        SwipeToRemove(
            id = item.id,
            state = state,
            onRemove = remove,
            onTap = open,
            onLongPress = openMenu,
            modifier = Modifier.semantics {
                contentDescription = accessibilityLabel(item)
                customActions = listOf(
                    CustomAccessibilityAction("Open") { open(); true },
                    CustomAccessibilityAction("View details") {
                        router?.route = BookRouter.Route.Details(item.book)
                        true
                    },
                    CustomAccessibilityAction("Remove download") { remove(); true },
                )
            },
        ) {
            DownloadRow(item.book, metaLine(item), ByteCountText.text(item.bytes))
        }
    }
}

/**
 * Swipe-left-to-remove for a row: Material's swipe-to-dismiss, the row
 * sliding over [label] in paper on the alert colour, removing once it is
 * swiped past the commit distance or flung. Shared with the list of books
 * from the reader's files, whose word is Remove — its original stays in
 * Files — rather than Delete.
 *
 * Only once the drag is more horizontal than vertical does it take over,
 * which is Material's own rule, so the list it lives in still scrolls.
 *
 * @param state whose [DownloadsSectionState.openRow] says which row a swipe
 *   has hold of; a swipe beginning on another row lets this one go.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun SwipeToRemove(
    id: String,
    state: DownloadsSectionState,
    onRemove: () -> Unit,
    onTap: () -> Unit,
    modifier: Modifier = Modifier,
    label: String = "Delete",
    onLongPress: (() -> Unit)? = null,
    content: @Composable () -> Unit,
) {
    val density = LocalDensity.current
    // Swift's commit distance: past 200 points, or half a narrow row.
    val swipe = rememberSwipeToDismissBoxState(positionalThreshold = { total -> min(with(density) { COMMIT_DISTANCE.toPx() }, total / 2) })
    val scope = rememberCoroutineScope()
    LaunchedEffect(swipe.dismissDirection) {
        if (swipe.dismissDirection == SwipeToDismissBoxValue.EndToStart) state.openRow = id
    }
    LaunchedEffect(state.openRow) {
        if (state.openRow != id && swipe.currentValue != SwipeToDismissBoxValue.Settled) swipe.reset()
    }
    SwipeToDismissBox(
        state = swipe,
        modifier = modifier.clip(RoundedCornerShape(Metrics.radiusMedium)),
        enableDismissFromStartToEnd = false,
        onDismiss = { value ->
            if (value == SwipeToDismissBoxValue.EndToStart) {
                onRemove()
                // The row leaves the list; should it come back (an undo),
                // it comes back settled.
                scope.launch { swipe.snapTo(SwipeToDismissBoxValue.Settled) }
            }
        },
        backgroundContent = { RemoveBackground(label) },
    ) {
        Box(
            Modifier.combinedClickable(
                role = Role.Button,
                onClick = {
                    // A tap while another row is mid-swipe puts that one away
                    // rather than opening a book.
                    if (state.openRow != null && state.openRow != id) state.openRow = null else onTap()
                },
                onLongClick = onLongPress,
            ),
        ) { content() }
    }
}

private val COMMIT_DISTANCE = 200.dp

/**
 * What the swipe uncovers: the word in paper on the alert colour — paper,
 * not white, because the alert colour is the light half of its pair in the
 * dark theme.
 */
@Composable
private fun RowScope.RemoveBackground(label: String) {
    Box(
        Modifier.fillMaxSize().background(Palette.alert).padding(horizontal = Metrics.spacing24),
        contentAlignment = Alignment.CenterEnd,
    ) {
        Text(label, style = Typography.callout.copy(fontWeight = FontWeight.SemiBold), color = Palette.paper)
    }
}

/** Cover, title in the reading face, edition and author, size on the right: `ResumeRow`'s card. */
@Composable
fun DownloadRow(book: Book, meta: String, size: String, modifier: Modifier = Modifier, selected: Boolean = false) {
    val shape = RoundedCornerShape(Metrics.radiusMedium)
    Row(
        modifier
            .fillMaxWidth()
            .background(Palette.surface, shape)
            .border(1.dp, if (selected) Palette.tangerine else Palette.border, shape)
            .padding(Metrics.spacing12),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Metrics.spacing12),
    ) {
        BookCover(book, Modifier.width(38.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(book.title, style = Typography.bookTitle, color = Palette.ink, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(meta, style = Typography.caption, color = Palette.inkTertiary, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        // Tabular, so a column of sizes lines up instead of dancing.
        Text(size, style = Typography.caption.copy(fontFeatureSettings = "tnum"), color = Palette.inkSecondary)
    }
}

/**
 * A book on its way onto the device, on the Downloads screen: title, how far
 * it has come, pause or resume, and cancel — which stops the transfer and
 * takes nothing else with it.
 */
@Composable
private fun TransferRow(app: AppModel, job: DownloadManager.Job, transfer: DownloadManager.State, modifier: Modifier = Modifier) {
    val scope = rememberCoroutineScope()
    val book = app.bookByUuid[job.bookUuid]
    val shape = RoundedCornerShape(Metrics.radiusMedium)
    Column(
        modifier
            .fillMaxWidth()
            .background(Palette.surface, shape)
            .border(1.dp, Palette.border, shape)
            .padding(Metrics.spacing12),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(book?.title ?: "Book", style = Typography.bookTitle, color = Palette.ink, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(
                    statusText(job, transfer),
                    style = Typography.caption.copy(fontFeatureSettings = "tnum"),
                    color = if (transfer.isFailure) Palette.alert else Palette.inkTertiary,
                )
            }
            Spacer(Modifier.width(Metrics.spacing8))
            Row(horizontalArrangement = Arrangement.spacedBy(Metrics.spacing12)) {
                if (transfer.isActive) {
                    TransferButton(Symbols.pauseCircle, "Pause", Palette.tangerine) { app.downloads?.pause(job) }
                } else {
                    TransferButton(Symbols.arrowDownCircle, "Resume", Palette.tangerine) { scope.launch { app.resumeDownload(job) } }
                }
                // Cancel, not remove: a download started by mistake is not a
                // decision about anything the reader has.
                TransferButton(Symbols.xmarkCircle, "Cancel", Palette.inkTertiary) { app.cancelDownload(job) }
            }
        }
        if (transfer.isActive || transfer.fraction > 0) {
            if (transfer.isIndeterminate) {
                LinearProgressIndicator(Modifier.fillMaxWidth(), color = Palette.tangerine, trackColor = Palette.border, strokeCap = StrokeCap.Round)
            } else {
                LinearProgressIndicator(
                    progress = { transfer.fraction.toFloat() },
                    modifier = Modifier.fillMaxWidth(),
                    color = Palette.tangerine,
                    trackColor = Palette.border,
                    strokeCap = StrokeCap.Round,
                    drawStopIndicator = {},
                )
            }
        }
    }
}

@Composable
private fun TransferButton(symbol: Int, description: String, tint: androidx.compose.ui.graphics.Color, onClick: () -> Unit) {
    Box(
        Modifier
            .size(32.dp)
            .clip(CircleShape)
            .clickable(role = Role.Button, onClick = onClick)
            .clearAndSetSemantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) {
        Icon(painterResource(symbol), contentDescription = null, tint = tint, modifier = Modifier.size(24.dp))
    }
}

/** The dashed box: dashed rather than solid because there is nothing in it, and a filled card reads as content. */
@Composable
private fun EmptyState(modifier: Modifier = Modifier) {
    val stroke = Palette.borderStrong
    Column(
        modifier
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

/**
 * The undo for a removal still inside its window: Swift's
 * `downloadRemovalToast`, as Material's snackbar on [host]. Applied once, by
 * the shell, rather than by the screens that list downloads: a book's menu
 * can remove a download from any screen, and the undo has to be wherever the
 * reader is. It says nothing itself; the model announces each removal once.
 */
@Composable
fun DownloadRemovalToast(host: SnackbarHostState) {
    val app = appModel
    val pending = app.pendingRemoval
    LaunchedEffect(pending?.id) {
        val removal = pending ?: return@LaunchedEffect
        // Standing until the model's window closes or the reader takes it back.
        val result = host.showSnackbar("Removed ${removal.title}", actionLabel = "Undo", duration = SnackbarDuration.Indefinite)
        if (result == SnackbarResult.ActionPerformed) app.undoPendingRemoval()
    }
}

/** The snackbar host the toast shows in: the capsule on the raised surface, its Undo in the accent. */
@Composable
fun DownloadRemovalSnackbarHost(host: SnackbarHostState, modifier: Modifier = Modifier) {
    SnackbarHost(host, modifier) { data ->
        Snackbar(
            data,
            modifier = Modifier.padding(horizontal = Metrics.screenMargin).border(1.dp, Palette.border, CircleShape),
            shape = CircleShape,
            containerColor = Palette.surfaceRaised,
            contentColor = Palette.ink,
            actionColor = Palette.tangerinePressed,
        )
    }
}
