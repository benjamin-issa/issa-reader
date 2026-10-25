package com.benjaminissa.issareader.app.ui.local

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Snackbar
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import com.benjaminissa.issareader.app.local.LocalBooksCopy
import com.benjaminissa.issareader.app.local.LocalImport
import com.benjaminissa.issareader.app.local.LocalImportError
import com.benjaminissa.issareader.app.ui.player.BookCoverImage
import com.benjaminissa.issareader.app.model.CoverCache
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.ByteCountText
import com.benjaminissa.issareader.core.model.LocalNotice
import com.benjaminissa.issareader.core.model.ReadingProgress
import com.benjaminissa.issareader.ui.Metrics
import com.benjaminissa.issareader.ui.Palette
import com.benjaminissa.issareader.ui.ProgressBar
import com.benjaminissa.issareader.ui.Symbols
import com.benjaminissa.issareader.ui.Typography
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

/*
 * The rows of the local books list (`LocalBooksScreen.swift`): a book's card,
 * a file on its way in, a file that could not be added, the undo toast, and
 * the swipe that removes.
 */

/** Which book a hardware keyboard's shortcut acts on. */
internal object LocalBooksKeyboard {
    /**
     * Delete: the row the keyboard is on, and nothing when it is on none.
     * Falling back to the first book removed the one opened last — the list's
     * first row — when the rows had been reached by touch.
     */
    fun removalTarget(focused: String?): String? = focused

    /** Book info: the row the keyboard is on, else the first book. Showing a book's info destroys nothing, so it may guess. */
    fun infoTarget(focused: String?, books: List<Book>): String? = focused ?: books.firstOrNull()?.uuid
}

/** What a row's notice strip is about, and so what its one action does. */
internal sealed interface LocalRowNotice {
    /** Told once after import: OK clears it for good. */
    data class Imported(val notice: LocalNotice) : LocalRowNotice

    /** The file did not come back from a backup: Add Again… opens the picker. */
    data object Missing : LocalRowNotice
}

/** One book as its row card says it: what a screen reader reads and what the trailing column shows. */
internal class LocalBookFacts(val book: Book, val size: Long?, val isMissing: Boolean, val isPlaying: Boolean) {
    val author: String get() = book.byline

    val narration: String?
        get() {
            val seconds = book.narrationDuration
            if (!book.hasReadalong || seconds == null || isMissing) return null
            return LocalBooksCopy.narrated(seconds)
        }

    val progress: Double? get() = book.progress?.takeIf { it > 0 }
    val percent: String? get() = progress?.let(ReadingProgress::percentText)
    val sizeText: String? get() = size?.let(ByteCountText::text)
    val trailing: String? get() = if (isMissing) LocalBooksCopy.notOnDevice else sizeText

    val notices: List<LocalRowNotice>
        get() = if (isMissing) listOf(LocalRowNotice.Missing) else (book.localCopy?.notices ?: emptyList()).map { LocalRowNotice.Imported(it) }

    /** The whole row, as one sentence: title, author, narration and length, percent, size, and "playing" while it narrates. */
    val spoken: String
        get() {
            val parts = mutableListOf(book.title)
            if (author.isNotEmpty()) parts += author
            narration?.let { parts += it.replace(" · ", ", ") }
            percent?.let { parts += "$it read" }
            trailing?.let { parts += it }
            if (isPlaying) parts += "playing"
            return parts.joinToString(", ")
        }

    companion object {
        fun noticeText(notice: LocalRowNotice): String = when (notice) {
            is LocalRowNotice.Imported -> LocalBooksCopy.notice(notice.notice)
            LocalRowNotice.Missing -> LocalBooksCopy.restoredNotice
        }

        fun noticeAction(notice: LocalRowNotice): String = when (notice) {
            is LocalRowNotice.Imported -> "OK"
            LocalRowNotice.Missing -> "Add Again…"
        }
    }
}

/** Whether the system's text is at one of its largest sizes, where a row stacks rather than lines up. */
@Composable
internal fun isAccessibilityTextSize(): Boolean = LocalDensity.current.fontScale >= 1.6f

/**
 * The row card: the Reading tab's "Also reading" card with the size on the
 * device in its trailing column, and a notice strip at its foot when there is
 * one.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun LocalBookRow(
    book: Book,
    size: Long?,
    isMissing: Boolean,
    isPlaying: Boolean,
    isHighlighted: Boolean,
    onNoticeAction: (LocalRowNotice) -> Unit,
    coverCache: CoverCache,
    modifier: Modifier = Modifier,
) {
    val facts = LocalBookFacts(book, size, isMissing, isPlaying)
    val stacked = isAccessibilityTextSize()
    val outline by animateColorAsState(if (isHighlighted) Palette.tangerine else Palette.border, label = "highlight")
    val shape = RoundedCornerShape(Metrics.radiusMedium)
    Column(
        modifier
            .fillMaxWidth()
            .then(if (isHighlighted) Modifier.shadow(3.dp, shape, ambientColor = Palette.tangerine, spotColor = Palette.tangerine) else Modifier)
            .background(Palette.surface, shape)
            .border(1.dp, outline, shape)
            .padding(Metrics.spacing12),
        verticalArrangement = Arrangement.spacedBy(Metrics.spacing12),
    ) {
        Box(Modifier.testTag("localBook.row")) {
            if (stacked) StackedRow(book, facts, isMissing, isPlaying, coverCache) else InlineRow(book, facts, isMissing, isPlaying, coverCache)
        }
        for (notice in facts.notices) {
            HorizontalDivider(thickness = 1.dp, color = Palette.border)
            NoticeStrip(notice, stacked) { onNoticeAction(notice) }
        }
    }
}

@Composable
private fun RowCover(book: Book, isMissing: Boolean, width: androidx.compose.ui.unit.Dp, coverCache: CoverCache) {
    Box(Modifier.width(width)) {
        // Decoded at the size drawn rather than 600 pixels for a thumbnail.
        BookCoverImage(book = book, session = null, localPixels = if (width > 40.dp) 260 else 180, cache = coverCache)
        if (isMissing) {
            Box(
                Modifier
                    .matchParentSize()
                    .clip(RoundedCornerShape(Metrics.radiusSmall))
                    .background(Palette.borderStrong.copy(alpha = 0.7f)),
            )
        }
    }
}

@Composable
private fun InlineRow(book: Book, facts: LocalBookFacts, isMissing: Boolean, isPlaying: Boolean, coverCache: CoverCache) {
    Row(horizontalArrangement = Arrangement.spacedBy(Metrics.spacing12), verticalAlignment = Alignment.Top) {
        RowCover(book, isMissing, 38.dp, coverCache)
        Details(book, facts, isMissing, stacked = false, modifier = Modifier.weight(1f))
        Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(Metrics.spacing4)) {
            if (isPlaying) Icon(painterResource(Symbols.chartBarFill), contentDescription = null, tint = Palette.tangerine, modifier = Modifier.size(13.dp))
            if (!isMissing) facts.percent?.let { Text(it, style = Typography.caption.copy(fontFeatureSettings = "tnum"), color = Palette.inkTertiary) }
            facts.trailing?.let {
                Text(it, style = Typography.caption.copy(fontFeatureSettings = "tnum"), color = if (isMissing) Palette.inkTertiary else Palette.inkSecondary)
            }
        }
    }
}

@Composable
private fun StackedRow(book: Book, facts: LocalBookFacts, isMissing: Boolean, isPlaying: Boolean, coverCache: CoverCache) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.spacing8)) {
        RowCover(book, isMissing, 57.dp, coverCache)
        Details(book, facts, isMissing, stacked = true)
        Text(
            listOfNotNull(facts.percent, facts.trailing, if (isPlaying) "Playing" else null).joinToString(" · "),
            style = Typography.caption.copy(fontFeatureSettings = "tnum"),
            color = Palette.inkTertiary,
        )
    }
}

@Composable
private fun Details(book: Book, facts: LocalBookFacts, isMissing: Boolean, stacked: Boolean, modifier: Modifier = Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(Metrics.spacing4)) {
        Text(
            book.title,
            style = Typography.bookTitle,
            color = if (isMissing) Palette.inkSecondary else Palette.ink,
            maxLines = if (stacked) Int.MAX_VALUE else 1,
            overflow = TextOverflow.Ellipsis,
        )
        if (facts.author.isNotEmpty() || (isMissing && facts.percent != null)) {
            Text(
                listOfNotNull(facts.author.takeIf { it.isNotEmpty() }, if (isMissing) facts.percent?.let { "$it read" } else null).joinToString(" · "),
                style = Typography.caption,
                color = Palette.inkTertiary,
                maxLines = if (stacked) Int.MAX_VALUE else 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        facts.narration?.let { narration ->
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Metrics.spacing4)) {
                Icon(painterResource(Symbols.waveform), contentDescription = null, tint = Palette.inkTertiary, modifier = Modifier.size(13.dp))
                Text(narration, style = Typography.caption, color = Palette.inkTertiary)
            }
        }
        val progress = facts.progress
        if (progress != null && !isMissing) {
            ProgressBar(progress, Modifier.widthIn(max = 220.dp).fillMaxWidth().padding(top = Metrics.spacing4))
        }
    }
}

@Composable
private fun NoticeStrip(notice: LocalRowNotice, stacked: Boolean, onAction: () -> Unit) {
    val text: @Composable (Modifier) -> Unit = { m ->
        Text(LocalBookFacts.noticeText(notice), style = Typography.footnote, color = Palette.inkSecondary, modifier = m)
    }
    val action: @Composable () -> Unit = {
        Text(
            LocalBookFacts.noticeAction(notice),
            style = Typography.callout.copy(fontWeight = FontWeight.SemiBold),
            color = Palette.tangerinePressed,
            modifier = Modifier
                .heightIn(min = 44.dp)
                .clickable(role = Role.Button, onClick = onAction)
                .testTag("localBook.noticeAction")
                .padding(vertical = 12.dp),
        )
    }
    if (stacked) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.spacing8)) {
            text(Modifier.fillMaxWidth())
            action()
        }
    } else {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Metrics.spacing12)) {
            text(Modifier.weight(1f))
            action()
        }
    }
}

/**
 * Swipe left to remove, for a row that is not in a list with swipe actions of
 * its own: the row slides left over the alert-coloured Remove, snaps open at
 * 88 points, and a swipe past 200 removes outright. Only horizontal drags are
 * claimed, so the list still scrolls.
 */
@Composable
internal fun LocalSwipeToRemove(
    id: String,
    openRow: String?,
    onOpenRowChange: (String?) -> Unit,
    label: String,
    onRemove: () -> Unit,
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    val density = LocalDensity.current
    val reveal = with(density) { 88.dp.toPx() }
    val commit = with(density) { 200.dp.toPx() }
    val isOpen = openRow == id
    val offset = remember { Animatable(0f) }
    val scope = rememberCoroutineScope()
    androidx.compose.runtime.LaunchedEffect(isOpen) { offset.animateTo(if (isOpen) -reveal else 0f) }
    Box(modifier.clip(RoundedCornerShape(Metrics.radiusMedium)).height(IntrinsicSize.Min)) {
        // Grows with the swipe, so dragging past the commit distance looks
        // like what it does. Only there while the row is moved: at rest its
        // colour would show through the card's rounded corners.
        val width = with(density) { maxOf(reveal, -offset.value).toDp() }
        if (offset.value < 0f) Box(
            Modifier
                .align(Alignment.CenterEnd)
                .fillMaxHeight()
                .width(width)
                .background(Palette.alert)
                .clickable {
                    onOpenRowChange(null)
                    onRemove()
                }
                .clearAndSetSemantics {},
            contentAlignment = Alignment.Center,
        ) {
            // Paper on alert, not white: the alert colour is the *light* half
            // of its pair in the dark theme.
            Text(label, style = Typography.callout.copy(fontWeight = FontWeight.SemiBold), color = Palette.paper)
        }
        Box(
            Modifier
                .offset { IntOffset(offset.value.roundToInt(), 0) }
                .draggable(
                    orientation = Orientation.Horizontal,
                    state = rememberDraggableState { delta ->
                        scope.launch { offset.snapTo((offset.value + delta).coerceAtMost(0f)) }
                    },
                    onDragStopped = {
                        val travelled = -offset.value
                        when {
                            travelled > commit -> {
                                onOpenRowChange(null)
                                offset.snapTo(0f)
                                onRemove()
                            }
                            travelled > reveal / 2 -> {
                                onOpenRowChange(id)
                                offset.animateTo(-reveal)
                            }
                            else -> {
                                if (isOpen) onOpenRowChange(null)
                                offset.animateTo(0f)
                            }
                        }
                    },
                ),
        ) { content() }
    }
}

/** A bar with no percentage: a 30 % segment moving across and back, or pulsing where it stands when animations are off. */
@Composable
internal fun LocalIndeterminateBar(reduceMotion: Boolean, modifier: Modifier = Modifier) {
    val transition = rememberInfiniteTransition(label = "indeterminate")
    val phase by transition.animateFloat(0f, 1f, infiniteRepeatable(tween(1200), RepeatMode.Reverse), label = "phase")
    BoxWithConstraints(modifier.fillMaxWidth().height(3.dp).clearAndSetSemantics {}) {
        val segment = maxWidth * 0.3f
        Box(Modifier.fillMaxWidth().height(3.dp).clip(CircleShape).background(Palette.ink.copy(alpha = 0.25f)))
        Box(
            Modifier
                .offset(x = if (reduceMotion) maxWidth * 0.35f else maxWidth * 0.7f * phase)
                .width(segment)
                .height(3.dp)
                .clip(CircleShape)
                .background(Palette.tangerine.copy(alpha = if (reduceMotion) 0.35f + 0.65f * phase else 1f)),
        )
    }
}

/** One file on its way in: its name, its stage, its bar, and a way to stop it. */
@Composable
internal fun LocalImportRow(item: LocalImport, reduceMotion: Boolean, onCancel: () -> Unit) {
    val added = item.stage is LocalImport.Stage.Added
    val shape = RoundedCornerShape(Metrics.radiusMedium)
    val dashColor = Palette.borderStrong
    Row(
        Modifier
            .fillMaxWidth()
            .background(Palette.surface, shape)
            .border(1.dp, Palette.border, shape)
            .padding(Metrics.spacing12)
            .semantics(mergeDescendants = true) {}
            .testTag("localImport.row"),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Metrics.spacing12),
    ) {
        Box(
            Modifier
                .size(width = 32.dp, height = 44.dp)
                .drawBehind {
                    drawRoundRect(
                        color = dashColor,
                        cornerRadius = CornerRadius(Metrics.radiusSmall.toPx()),
                        style = Stroke(width = 1.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 3.dp.toPx()))),
                    )
                },
            contentAlignment = Alignment.Center,
        ) {
            if (added) Icon(painterResource(Symbols.checkmarkCircleFill), contentDescription = null, tint = Palette.moss, modifier = Modifier.size(20.dp))
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(Metrics.spacing4)) {
            Text(item.fileName, style = Typography.callout, color = Palette.ink, maxLines = 1, overflow = TextOverflow.MiddleEllipsis)
            Text(
                item.statusText ?: "",
                style = Typography.caption.copy(fontFeatureSettings = "tnum"),
                color = if (added) Palette.moss else Palette.inkTertiary,
            )
            when (val stage = item.stage) {
                is LocalImport.Stage.Copying -> ProgressBar(stage.fraction, Modifier.widthIn(max = 260.dp).fillMaxWidth())
                LocalImport.Stage.Downloading, LocalImport.Stage.Checking -> LocalIndeterminateBar(reduceMotion, Modifier.widthIn(max = 260.dp))
                else -> Unit
            }
        }
        if (item.isUnfinished) {
            Box(
                Modifier
                    .size(44.dp)
                    .clip(CircleShape)
                    .clickable(role = Role.Button, onClick = onCancel)
                    .semantics { contentDescription = "Cancel adding ${item.fileName}" },
                contentAlignment = Alignment.Center,
            ) {
                Icon(painterResource(Symbols.xmark), contentDescription = null, tint = Palette.inkTertiary, modifier = Modifier.size(20.dp))
            }
        }
    }
}

/**
 * A file that could not be added: what happened, which file, why and what to
 * do, then one action and Dismiss. The alert colour marks only the "!".
 */
@Composable
internal fun LocalProblemRow(item: LocalImport, error: LocalImportError, onAction: (LocalImportError.Action) -> Unit, onDismiss: () -> Unit) {
    val shape = RoundedCornerShape(Metrics.radiusMedium)
    Row(
        Modifier
            .fillMaxWidth()
            .background(Palette.surface, shape)
            .border(1.dp, Palette.border, shape)
            .padding(Metrics.spacing12)
            .testTag("localProblem.row"),
        horizontalArrangement = Arrangement.spacedBy(Metrics.spacing12),
    ) {
        Box(Modifier.size(32.dp), contentAlignment = Alignment.Center) {
            Icon(painterResource(Symbols.exclamationmarkCircleFill), contentDescription = null, tint = Palette.alert, modifier = Modifier.size(22.dp))
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(Metrics.spacing4)) {
            Text(error.title, style = Typography.headline, color = Palette.ink)
            Text(item.fileName, style = Typography.caption, color = Palette.inkTertiary, maxLines = 1, overflow = TextOverflow.MiddleEllipsis)
            Text(error.reason, style = Typography.footnote, color = Palette.inkSecondary)
            Row(Modifier.padding(top = Metrics.spacing4), horizontalArrangement = Arrangement.spacedBy(Metrics.spacing24), verticalAlignment = Alignment.CenterVertically) {
                error.action?.let { action ->
                    Text(
                        LocalImportError.label(action),
                        style = Typography.callout.copy(fontWeight = FontWeight.SemiBold),
                        color = Palette.tangerinePressed,
                        modifier = Modifier.heightIn(min = 44.dp).clickable(role = Role.Button) { onAction(action) }.padding(vertical = 12.dp),
                    )
                }
                Text(
                    "Dismiss",
                    style = Typography.callout,
                    color = Palette.inkTertiary,
                    modifier = Modifier.heightIn(min = 44.dp).clickable(role = Role.Button, onClick = onDismiss).padding(vertical = 12.dp),
                )
            }
        }
    }
}

/**
 * The undo toast: Material's snackbar in the palette — one line and one text
 * action in a capsule, pinned above whatever bar is at the bottom.
 */
@Composable
internal fun LocalToast(message: String, action: String, spoken: String, onAction: () -> Unit, modifier: Modifier = Modifier) {
    Box(modifier.fillMaxWidth().padding(Metrics.screenMargin), contentAlignment = Alignment.BottomCenter) {
        Snackbar(
            modifier = Modifier
                .widthIn(max = 520.dp)
                .border(1.dp, Palette.border, CircleShape)
                .semantics { contentDescription = spoken },
            shape = CircleShape,
            containerColor = Palette.surfaceRaised,
            contentColor = Palette.ink,
            actionContentColor = Palette.tangerinePressed,
            action = {
                TextButton(onClick = onAction, modifier = Modifier.testTag("toast.action")) {
                    Text(action, style = Typography.callout.copy(fontWeight = FontWeight.SemiBold), color = Palette.tangerinePressed)
                }
            },
        ) {
            Text(message, style = Typography.callout, color = Palette.ink, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
    }
}

/** The custom actions a row offers a screen reader: Book Info and Remove. */
internal fun Modifier.localRowActions(spoken: String, onOpen: () -> Unit, onInfo: () -> Unit, onRemove: () -> Unit, removeTitle: String): Modifier =
    semantics(mergeDescendants = true) {
        contentDescription = spoken
        role = Role.Button
        onClick { onOpen(); true }
        customActions = listOf(
            CustomAccessibilityAction("Book Info") { onInfo(); true },
            CustomAccessibilityAction(removeTitle) { onRemove(); true },
        )
    }
