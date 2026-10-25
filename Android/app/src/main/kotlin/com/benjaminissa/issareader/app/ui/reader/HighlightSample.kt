package com.benjaminissa.issareader.app.ui.reader

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
import androidx.compose.ui.graphics.asComposePath
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextStyle
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
import kotlin.math.max
import kotlin.math.min

/**
 * A few lines of a book, on the chosen paper, with one sentence marked.
 *
 * Settings can otherwise only show the highlighter as a circle of ink, and a
 * circle at full strength answers none of the questions actually being
 * asked: how much of the page shows through, whether the words underneath
 * stay readable, whether it looks like a marker or like a stain. Three lines
 * of real prose answer all three.
 *
 * It has to be the same shape the page draws, or the sample would be a
 * promise the reader gets to check against the book a minute later — so the
 * marked sentence is filled through [HighlightBlock], exactly as the page
 * fills it, one line at a time from the laid-out text, in one fill.
 *
 * @param fontFamily the reading face; one the app does not ship falls back to the default.
 */
@Composable
fun HighlightSample(theme: ReaderTheme, highlight: Color, fontFamily: String?, modifier: Modifier = Modifier) {
    val family = remember(fontFamily) {
        val face = IssaFonts.bundledFace(fontFamily ?: ReaderStyle.DEFAULT_FAMILY) ?: IssaFonts.bundledFace(ReaderStyle.DEFAULT_FAMILY)
        face?.let { IssaFonts.composeFamily(it, opticalSize = SIZE) } ?: FontFamily.Serif
    }
    var layout by remember { mutableStateOf<TextLayoutResult?>(null) }
    val text = OPENING + MARKED + CLOSING
    Text(
        text,
        style = TextStyle(fontFamily = family, fontSize = SIZE.sp, color = theme.text.color),
        onTextLayout = { layout = it },
        modifier = modifier
            .fillMaxWidth()
            .background(theme.background.color, RoundedCornerShape(Metrics.radiusMedium))
            .padding(Metrics.spacing16)
            .drawBehind {
                val laid = layout ?: return@drawBehind
                val start = OPENING.length
                val end = start + MARKED.length
                val lines = ArrayList<List<PageRect>>()
                for (line in laid.getLineForOffset(start)..laid.getLineForOffset(end - 1)) {
                    val a = max(start, laid.getLineStart(line))
                    val b = min(end, laid.getLineEnd(line, visibleEnd = true))
                    if (b <= a) continue
                    val left = laid.getHorizontalPosition(a, usePrimaryDirection = true)
                    val right = if (b == laid.getLineEnd(line, visibleEnd = true)) laid.getLineRight(line) else laid.getHorizontalPosition(b, usePrimaryDirection = true)
                    val top = laid.getLineTop(line)
                    val bottom = laid.getLineBottom(line)
                    lines.add(listOf(PageRect(left.toDouble(), top.toDouble(), (right - left).toDouble(), (bottom - top).toDouble())))
                }
                if (lines.isEmpty()) return@drawBehind
                // The block's proportions at the sample's reading size, in pixels.
                val points = HighlightBlock.Style.forFontSize(SIZE.toDouble())
                val scale = density.toDouble()
                val style = HighlightBlock.Style(points.horizontal * scale, points.vertical * scale, points.cornerRadius * scale)
                drawPath(HighlightBlock.path(lines, style).toAndroidPath().asComposePath(), highlight)
            }
            .clearAndSetSemantics { contentDescription = "Sample of the highlighter on ${theme.title}" },
    )
}

/**
 * From *Peter and Wendy*, which is the book the reader is most likely to have
 * open — three sentences so the marked one has a line above and a line below,
 * which is where the block's seams show.
 */
private const val OPENING = "Wendy knew that she must grow up. "
private const val MARKED = "You always know after you are two."
private const val CLOSING = " Two is the beginning of the end."

/**
 * A reading size rather than a UI one: the sample is a picture of a page, and
 * the block's padding and corners are derived from exactly this number.
 */
private const val SIZE = 17f
