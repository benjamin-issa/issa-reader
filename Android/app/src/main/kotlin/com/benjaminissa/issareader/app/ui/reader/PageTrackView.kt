package com.benjaminissa.issareader.app.ui.reader

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import com.benjaminissa.issareader.app.reader.PageSnapshot
import com.benjaminissa.issareader.app.reader.ReaderModel
import com.benjaminissa.issareader.render.PageTurn
import com.benjaminissa.issareader.render.android.PageDrawing
import com.benjaminissa.issareader.ui.color
import kotlinx.coroutines.isActive

/** The margins a page is drawn inside, in dp. A page slides with its margins. */
data class PageInsets(val top: Dp, val leading: Dp, val bottom: Dp, val trailing: Dp)

/**
 * The page, and the page it is turning to.
 *
 * The outer function reads the model, which is how the live page follows the
 * narration as it always has; the layer inside reads the turner, and only the
 * frame clock inside the layers' own drawing blocks, so a page moving under a
 * finger re-places two layers and redraws no text.
 *
 * The caller makes it one accessibility node, outside the motion, saying what
 * the model says: the page being turned to is the page the moment the turn is
 * made, and the one sliding away is not there at all.
 *
 * @param pageWidth the page's own width inside its margins, in dp; [pageHeight] likewise.
 */
@Composable
fun PageTrackView(
    model: ReaderModel,
    turner: PageTurner,
    pageWidth: Dp,
    pageHeight: Dp,
    insets: PageInsets,
    modifier: Modifier = Modifier,
) {
    // Read here, so the track is told when the page is re-flowed in place —
    // the same chapter and page number, different lines.
    model.pageKey
    PageTrackLayer(
        turner = turner,
        live = model.currentSnapshot(),
        paper = model.style.theme.background.color,
        pageWidth = pageWidth,
        pageHeight = pageHeight,
        insets = insets,
        modifier = modifier,
    )
}

@Composable
private fun PageTrackLayer(
    turner: PageTurner,
    live: PageSnapshot?,
    paper: Color,
    pageWidth: Dp,
    pageHeight: Dp,
    insets: PageInsets,
    modifier: Modifier,
) {
    val width = pageWidth + insets.leading + insets.trailing
    val height = pageHeight + insets.top + insets.bottom

    // The turner moves the page by its own clock, sampled once a frame while
    // there is a motion to run. Nothing else animates it.
    var time by remember { mutableDoubleStateOf(turner.now()) }
    val motion = turner.motion
    LaunchedEffect(motion) {
        if (motion == null) return@LaunchedEffect
        while (isActive) withFrameNanos { time = turner.now() }
    }

    val scene = turner.scene
    val style = turner.style
    // Read inside the layers' blocks, never here: a frame moves the layers
    // and recomposes nothing.
    fun placement(): PageTurn.Placement? = scene?.let {
        PageTurn.placement(style, it.direction, turner.progress(time), width.value.toDouble())
    }
    val liveArrives = scene?.liveIsArriving ?: false
    val liveOnTop = scene?.let {
        liveArrives == PageTurn.placement(style, it.direction, 0.0, 1.0).arrivingOnTop
    } ?: true

    // Turns are physical: forward is the page moving left whatever the
    // language of the interface around it, so offsets are applied as they
    // are rather than mirrored.
    Box(modifier.size(width, height).clipToBounds()) {
        Slot(
            live, paper, pageWidth, pageHeight, insets,
            Modifier
                .zIndex(if (liveOnTop) 2f else 0f)
                .graphicsLayer {
                    val p = placement()
                    translationX = (p?.let { if (liveArrives) it.arrivingX else it.leavingX } ?: 0.0).dp.toPx()
                },
        )
        if (scene != null) {
            val otherModifier = Modifier
                .zIndex(if (liveOnTop) 0f else 2f)
                .graphicsLayer {
                    val p = placement()
                    translationX = (p?.let { if (liveArrives) it.leavingX else it.arrivingX } ?: 0.0).dp.toPx()
                }
            when (val other = scene.other) {
                is PageTurner.Other.Page -> Slot(other.snapshot, paper, pageWidth, pageHeight, insets, otherModifier)
                PageTurner.Other.Blank -> Blank(paper, width, height, otherModifier)
            }
            Spacer(
                Modifier
                    .zIndex(1f)
                    .size(PageTurn.SHADOW_WIDTH.dp, height)
                    .graphicsLayer {
                        val p = placement()
                        val opacity = p?.shadowOpacity ?: 0.0
                        alpha = if (opacity > 0) 1f else 0f
                        translationX = (p?.shadowX ?: 0.0).dp.toPx()
                    }
                    .drawBehind {
                        val opacity = placement()?.shadowOpacity ?: 0.0
                        if (opacity <= 0) return@drawBehind
                        drawRect(
                            Brush.horizontalGradient(
                                listOf(Color.Black.copy(alpha = opacity.toFloat()), Color.Black.copy(alpha = 0f)),
                            ),
                        )
                    },
            )
        }
    }
}

@Composable
private fun Slot(
    snapshot: PageSnapshot?,
    paper: Color,
    pageWidth: Dp,
    pageHeight: Dp,
    insets: PageInsets,
    modifier: Modifier,
) {
    val width = pageWidth + insets.leading + insets.trailing
    val height = pageHeight + insets.top + insets.bottom
    if (snapshot == null) {
        // The chapter is still being laid out. Holding the page's exact size
        // means nothing above or below it moves when the glyphs arrive, which
        // is the whole reason the reserve exists.
        Blank(paper, width, height, modifier)
        return
    }
    Box(modifier.size(width, height).background(paper)) {
        PageSurface(
            snapshot, pageWidth, pageHeight,
            Modifier.offset(insets.leading, insets.top),
        )
    }
}

@Composable
private fun Blank(paper: Color, width: Dp, height: Dp, modifier: Modifier) {
    Spacer(modifier.size(width, height).background(paper))
}

/**
 * One page of paper: the glyphs, and everything tinted underneath them.
 *
 * Every input is passed in rather than read from a model, so nothing here can
 * change under the renderer — the page sliding away is a snapshot of a page
 * the model has already left — and it redraws only when the snapshot would
 * draw something different.
 *
 * Everything tinted is drawn beneath the glyphs so it reads as paper tint
 * rather than a wash over the type — and each mark is filled exactly once, as
 * one block: filling a rounded rectangle per line composited a translucent
 * colour over itself at each seam, the dark band that used to run through
 * every wrapped sentence.
 */
@Composable
fun PageSurface(snapshot: PageSnapshot, pageWidth: Dp, pageHeight: Dp, modifier: Modifier = Modifier) {
    // Kept while it would draw the same thing, so an equal snapshot from a
    // recomposition does not redraw the page.
    val kept = remember(snapshot) { snapshot }
    Spacer(
        modifier
            .size(pageWidth, pageHeight)
            .clipToBounds()
            .drawBehind {
                val marks = buildList {
                    for (block in kept.annotations) add(PageDrawing.Mark(block.lines, ReaderPalette.pageFill(block.tint)))
                    kept.activeFragment?.let { add(PageDrawing.narration(kept.layout, it, kept.page, kept.highlight)) }
                    kept.selection?.let { add(PageDrawing.Mark(kept.layout.lines(it, kept.page), kept.theme.selection)) }
                }
                drawIntoCanvas { canvas ->
                    PageDrawing.draw(canvas.nativeCanvas, kept.layout, kept.page, marks, theme = null, style = kept.highlightStyle)
                }
            },
    )
}
