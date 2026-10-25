package com.benjaminissa.issareader.render.android

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import com.benjaminissa.issareader.render.HighlightBlock
import com.benjaminissa.issareader.render.PagePath
import com.benjaminissa.issareader.render.PageRect
import com.benjaminissa.issareader.render.PathCommand
import com.benjaminissa.issareader.render.ReaderTheme
import com.benjaminissa.issareader.render.RenderedPage
import com.benjaminissa.issareader.render.Rgba

/**
 * Painting one page: its paper, the marks on it, and its text, in that order.
 *
 * The entry point the reader screen draws through, from a Compose `Canvas` or
 * any other. Every mark is one [HighlightBlock] shape filled once, so a
 * translucent highlighter is the same depth of colour at a seam between two
 * lines as in the middle of one — the band of doubled colour the Swift reader
 * once painted across every wrapped sentence cannot happen here by
 * construction.
 */
object PageDrawing {
    /**
     * One thing to mark on the page: a narrated sentence, a selection, a
     * stored highlight — its rectangles grouped by line, as
     * [ChapterLayout.highlightLines] and [ChapterLayout.lines] give them.
     */
    data class Mark(val lines: List<List<PageRect>>, val color: Rgba)

    /**
     * Draws [page] of [layout] with its top-left corner at the canvas origin.
     *
     * @param theme the page colour to fill first; `null` leaves the canvas as
     *   it is, for a caller that paints its own paper.
     * @param style the block's proportions; the layout's reading size by default.
     */
    fun draw(
        canvas: Canvas,
        layout: ChapterLayout,
        page: RenderedPage,
        marks: List<Mark> = emptyList(),
        theme: ReaderTheme? = null,
        style: HighlightBlock.Style = layout.highlightStyle,
    ) {
        if (theme != null) canvas.drawColor(theme.background.argb)
        val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.style = Paint.Style.FILL }
        for (mark in marks) {
            val shape = HighlightBlock.path(lines = mark.lines, style = style)
            if (shape.isEmpty) continue
            fill.color = mark.color.argb
            canvas.drawPath(shape.toAndroidPath(), fill)
        }
        layout.draw(page, canvas)
    }

    /** A narrated sentence's mark on a page, in the theme's colour for it. */
    fun narration(layout: ChapterLayout, fragmentId: String, page: RenderedPage, color: Rgba): Mark =
        Mark(layout.highlightLines(fragmentId, page), color)
}

/** [PageDrawing.draw], from a Compose `DrawScope`. */
fun DrawScope.drawChapterPage(
    layout: ChapterLayout,
    page: RenderedPage,
    marks: List<PageDrawing.Mark> = emptyList(),
    theme: ReaderTheme? = null,
) {
    drawIntoCanvas { PageDrawing.draw(it.nativeCanvas, layout, page, marks, theme) }
}

/**
 * The shape as an Android path: every arc is already a centre, a radius and
 * two angles, which is what `arcTo` takes, so nothing is approximated here.
 */
fun PagePath.toAndroidPath(): Path {
    val path = Path()
    path.fillType = Path.FillType.WINDING
    for (command in commands) {
        when (command) {
            is PathCommand.MoveTo -> path.moveTo(command.x.toFloat(), command.y.toFloat())
            is PathCommand.LineTo -> path.lineTo(command.x.toFloat(), command.y.toFloat())
            is PathCommand.Arc -> {
                val r = command.radius
                val oval = RectF(
                    (command.centerX - r).toFloat(), (command.centerY - r).toFloat(),
                    (command.centerX + r).toFloat(), (command.centerY + r).toFloat(),
                )
                path.arcTo(oval, command.startAngle.toFloat(), command.sweepAngle.toFloat(), false)
            }
            PathCommand.Close -> path.close()
        }
    }
    return path
}
