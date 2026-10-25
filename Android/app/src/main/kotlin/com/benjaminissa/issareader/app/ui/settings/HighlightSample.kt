package com.benjaminissa.issareader.app.ui.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.sp
import com.benjaminissa.issareader.render.HighlightBlock
import com.benjaminissa.issareader.render.PageRect
import com.benjaminissa.issareader.render.ReaderStyle
import com.benjaminissa.issareader.render.ReaderTheme
import com.benjaminissa.issareader.render.android.toAndroidPath
import com.benjaminissa.issareader.ui.IssaFonts
import com.benjaminissa.issareader.ui.Metrics
import com.benjaminissa.issareader.ui.color

/**
 * A few lines of a book, on the chosen paper, with one sentence marked.
 *
 * Settings can otherwise only show the highlighter as a circle of ink, and a
 * circle at full strength answers none of the questions actually being asked:
 * how much of the page shows through, whether the words underneath stay
 * readable, whether it looks like a marker or like a stain. Three lines of
 * real prose answer all three.
 *
 * It has to be the same shape the page draws, or the sample would be a
 * promise the reader gets to check against the book a minute later — so the
 * marked sentence is filled through [HighlightBlock], exactly as the page
 * fills it, rather than as a per-line background: one fill, under the glyphs,
 * from the laid-out lines' rectangles.
 */
@Composable
internal fun HighlightSample(theme: ReaderTheme, highlight: Color, fontFamily: String?, modifier: Modifier = Modifier) {
    var layout by remember { mutableStateOf<TextLayoutResult?>(null) }
    val text = remember {
        buildAnnotatedString {
            append(OPENING)
            append(MARKED)
            append(CLOSING)
        }
    }
    val face = remember(fontFamily) {
        (IssaFonts.bundledFace(fontFamily ?: ReaderStyle.DEFAULT_FAMILY) ?: IssaFonts.bundledFace(ReaderStyle.DEFAULT_FAMILY))
            ?.let { IssaFonts.composeFamily(it, opticalSize = SIZE) } ?: FontFamily.Serif
    }
    val style = remember { HighlightBlock.Style.forFontSize(SIZE.toDouble()) }
    Text(
        text,
        style = TextStyle(fontFamily = face, fontSize = SIZE.sp, color = theme.text.color),
        onTextLayout = { layout = it },
        modifier = modifier
            .fillMaxWidth()
            .background(theme.background.color, RoundedCornerShape(Metrics.radiusMedium))
            .padding(Metrics.spacing16)
            .drawBehind {
                val result = layout ?: return@drawBehind
                // A reading size rather than a UI one: the block's padding
                // and corners come from the point size, which on this screen
                // is drawn at the display's density.
                val scale = density.toDouble()
                val lines = markedLines(result).filter { it.isNotEmpty() }
                if (lines.isEmpty()) return@drawBehind
                val scaled = HighlightBlock.Style(style.horizontal * scale, style.vertical * scale, style.cornerRadius * scale)
                val path = HighlightBlock.path(lines = lines, style = scaled)
                if (path.isEmpty) return@drawBehind
                val paint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
                    this.style = android.graphics.Paint.Style.FILL
                    color = highlight.toArgb()
                }
                drawIntoCanvas { it.nativeCanvas.drawPath(path.toAndroidPath(), paint) }
            }
            .clearAndSetSemantics { contentDescription = "Sample of the highlighter on ${theme.title}" },
    )
}

/** From *Peter and Wendy*: three sentences, so the marked one has a line above and a line below, where the block's seams show. */
private const val OPENING = "Wendy knew that she must grow up. "
private const val MARKED = "You always know after you are two."
private const val CLOSING = " Two is the beginning of the end."

/** A reading size, from which the block's padding and corners derive. */
private const val SIZE = 17f

/**
 * The marked sentence's rectangle on each line it crosses, in pixels: one list
 * per laid-out line, as the page hands [HighlightBlock] its lines, so a line
 * is never merged with the one below it.
 */
private fun markedLines(layout: TextLayoutResult): List<List<PageRect>> {
    val start = OPENING.length
    val end = OPENING.length + MARKED.length
    return (0 until layout.lineCount).map { line ->
        val lineStart = layout.getLineStart(line)
        val lineEnd = layout.getLineEnd(line, visibleEnd = true)
        val from = maxOf(start, lineStart)
        val to = minOf(end, lineEnd)
        if (from >= to) return@map emptyList()
        val left = layout.getHorizontalPosition(from, usePrimaryDirection = true)
        val right = if (to >= lineEnd) layout.getLineRight(line) else layout.getHorizontalPosition(to, usePrimaryDirection = true)
        val top = layout.getLineTop(line)
        val bottom = layout.getLineBottom(line)
        listOf(PageRect(minOf(left, right).toDouble(), top.toDouble(), kotlin.math.abs(right - left).toDouble(), (bottom - top).toDouble()))
    }
}
