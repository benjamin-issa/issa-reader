package com.benjaminissa.issareader.app.ui.reader

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.BottomSheetDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.foundation.layout.navigationBars
import kotlinx.coroutines.launch
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.benjaminissa.issareader.ui.Metrics
import com.benjaminissa.issareader.ui.Palette
import com.benjaminissa.issareader.ui.PaperCardRadius
import com.benjaminissa.issareader.ui.SystemText

/*
 * The reader's sheets: Material's modal bottom sheet on the app's paper, as
 * the iPhone presents its own on `Palette.paper`. A half-height sheet that can
 * be pulled up is the iPhone's medium and large detents; a full one is its
 * large detent alone.
 */

/**
 * One of the reader's sheets.
 *
 * @param halfHeight opens at half the screen, as the iPhone's medium detent,
 *   and grows when pulled up; otherwise opens at full height.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReaderSheet(
    onDismiss: () -> Unit,
    halfHeight: Boolean = false,
    content: @Composable ColumnScope.(dismiss: () -> Unit) -> Unit,
) {
    val state = rememberModalBottomSheetState(skipPartiallyExpanded = !halfHeight)
    val scope = rememberCoroutineScope()
    // Slid away first, then gone: what "Done" and a chosen row do.
    val dismiss: () -> Unit = {
        scope.launch { state.hide() }.invokeOnCompletion { onDismiss() }
    }
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = state,
        containerColor = Palette.paper,
        contentColor = Palette.ink,
        tonalElevation = 0.dp,
        dragHandle = { BottomSheetDefaults.DragHandle(color = Palette.borderStrong) },
        contentWindowInsets = { WindowInsets.navigationBars },
    ) {
        // The iPhone's large detent is the whole height, however little is in it.
        Column(if (halfHeight) Modifier.fillMaxWidth() else Modifier.fillMaxSize()) { content(dismiss) }
    }
}

/** A sheet's large title, as a navigation stack's in a sheet. */
@Composable
fun SheetLargeTitle(title: String, modifier: Modifier = Modifier) {
    Text(
        title,
        style = SystemText.largeTitle,
        color = Palette.ink,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
        modifier = modifier.padding(start = Metrics.screenMargin + 4.dp, end = Metrics.screenMargin, top = Metrics.spacing8, bottom = Metrics.spacing12),
    )
}

/** A sheet's inline title, centred, with "Done" at the trailing edge: the iPhone's confirmation action. */
@Composable
fun SheetInlineTitle(title: String, onDone: () -> Unit, modifier: Modifier = Modifier) {
    Row(
        modifier.fillMaxWidth().padding(horizontal = Metrics.spacing8).height(52.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // As wide as the button, so the title is centred on the sheet.
        Spacer(Modifier.width(DONE_WIDTH))
        Text(
            title,
            style = SystemText.navigationTitle,
            color = Palette.ink,
            textAlign = TextAlign.Center,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        TextButton(onClick = onDone, modifier = Modifier.width(DONE_WIDTH)) {
            Text("Done", style = SystemText.headline.copy(fontWeight = FontWeight.SemiBold), color = Palette.tangerine)
        }
    }
}

private val DONE_WIDTH: Dp = 76.dp

/**
 * One row of a grouped list that is built lazily: the surface card's corners
 * on the first and last row only, so a long list still reads as one card.
 */
@Composable
fun Modifier.groupedRow(index: Int, count: Int): Modifier {
    val top = if (index == 0) PaperCardRadius else 0.dp
    val bottom = if (index == count - 1) PaperCardRadius else 0.dp
    return this
        .fillMaxWidth()
        .clip(RoundedCornerShape(topStart = top, topEnd = top, bottomStart = bottom, bottomEnd = bottom))
        .background(Palette.surface)
}

/** The hairline under a grouped row, inset to its text. */
@Composable
fun GroupedRowDivider(start: Dp = 16.dp) {
    HorizontalDivider(modifier = Modifier.padding(start = start, end = 16.dp), thickness = 0.5.dp, color = Palette.border)
}
