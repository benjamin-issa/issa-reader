package com.benjaminissa.issareader.ui

import androidx.compose.animation.core.Animatable
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

/**
 * Swipe left to remove, for a row that is not in a list with swipe actions of
 * its own: the iPhone's `SwipeToRemove`, and the swipe action its `List`s
 * give a row. The row slides left over the alert-coloured button, snaps open
 * at 88 to show it, and a swipe past 200 removes outright without waiting
 * for the button to be tapped. One row is open at a time — two open rows are
 * two buttons and no way to tell which a tap means — so the caller holds
 * which ([openRow]).
 *
 * Only horizontal drags are claimed, so the list the row lives in still
 * scrolls. The button is hidden from a screen reader: the row's own actions
 * carry the removal.
 *
 * @param label the button's word: Delete, or Remove for a book from the
 *   reader's files, whose original stays where it was.
 * @param onTap the row's tap. A tap while a row is open puts that row away
 *   instead: the reader is looking at a red button, and the tap that dismisses
 *   it must not also open something. Null for a row that takes its own taps.
 * @param onLongPress the row's long press, its menu.
 * @param shape the row's outline, which the button is clipped to.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun SwipeToRemove(
    id: String,
    openRow: String?,
    onOpenRowChange: (String?) -> Unit,
    onRemove: () -> Unit,
    modifier: Modifier = Modifier,
    label: String = "Delete",
    onTap: (() -> Unit)? = null,
    onLongPress: (() -> Unit)? = null,
    shape: Shape = RoundedCornerShape(Metrics.radiusMedium),
    content: @Composable () -> Unit,
) {
    val density = LocalDensity.current
    val reveal = with(density) { REVEAL_WIDTH.toPx() }
    val commit = with(density) { COMMIT_DISTANCE.toPx() }
    val isOpen = openRow == id
    // The drag's callbacks outlive a recomposition, so they read the latest.
    val currentIsOpen by rememberUpdatedState(isOpen)
    val currentOnOpenRowChange by rememberUpdatedState(onOpenRowChange)
    val currentOnRemove by rememberUpdatedState(onRemove)
    val offset = remember { Animatable(0f) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(isOpen) { offset.animateTo(if (isOpen) -reveal else 0f) }
    Box(modifier.clip(shape).height(IntrinsicSize.Min)) {
        // Grows with the swipe, so dragging past the commit distance looks
        // like what it does. Only there while the row is moved: at rest its
        // colour would show through the row's rounded corners.
        val width = with(density) { maxOf(reveal, -offset.value).toDp() }
        if (offset.value < 0f) {
            Box(
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
                // Paper on alert, not white: the alert colour is the *light*
                // half of its pair in the dark theme.
                Text(label, style = Typography.callout.copy(fontWeight = FontWeight.SemiBold), color = Palette.paper)
            }
        }
        Box(
            Modifier
                .offset { IntOffset(offset.value.roundToInt(), 0) }
                // detectHorizontalDragGestures rather than `draggable`: draggable
                // reports a drag the system cancelled exactly as one the finger
                // ended, so a cancel past the commit distance removed the row.
                // Swift's `.cancelled` is "reset, don't remove".
                .pointerInput(reveal, commit) {
                    detectHorizontalDragGestures(
                        onDragEnd = {
                            scope.launch {
                                val travelled = -offset.value
                                when {
                                    travelled > commit -> {
                                        currentOnOpenRowChange(null)
                                        offset.snapTo(0f)
                                        currentOnRemove()
                                    }
                                    travelled > reveal / 2 -> {
                                        currentOnOpenRowChange(id)
                                        offset.animateTo(-reveal)
                                    }
                                    else -> {
                                        if (currentIsOpen) currentOnOpenRowChange(null)
                                        offset.animateTo(0f)
                                    }
                                }
                            }
                        },
                        // Back to where the row was before the finger came down,
                        // and nothing else: no removal, and the open row stays
                        // as it was.
                        onDragCancel = {
                            scope.launch { offset.animateTo(if (currentIsOpen) -reveal else 0f) }
                        },
                        onHorizontalDrag = { change, delta ->
                            change.consume()
                            scope.launch { offset.snapTo((offset.value + delta).coerceAtMost(0f)) }
                        },
                    )
                }
                .then(
                    if (onTap != null || onLongPress != null) {
                        Modifier.combinedClickable(
                            role = Role.Button,
                            onClick = { if (openRow != null) onOpenRowChange(null) else onTap?.invoke() },
                            onLongClick = onLongPress,
                        )
                    } else {
                        Modifier
                    },
                ),
        ) { content() }
    }
}

/** The revealed button's width. */
private val REVEAL_WIDTH = 88.dp

/** How far a swipe goes before it means the removal without the button being tapped. */
private val COMMIT_DISTANCE = 200.dp
