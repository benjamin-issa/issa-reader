package com.benjaminissa.issareader.render.android

import android.graphics.Canvas
import android.graphics.Color
import android.graphics.DashPathEffect
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
 *
 * On an E Ink panel a tint dithers to a grey that takes contrast from the words
 * on it, so E-Ink mode's marks are shapes: see [Treatment].
 */
object PageDrawing {
    /** How a mark is put on the page. */
    enum class Treatment {
        /** The block filled, under the text. */
        FILL,

        /** A solid line along the foot of each line of text. */
        UNDERLINE,

        /** The same line, dashed: a stored highlight, which has to read as different from the narration. */
        DASHED_UNDERLINE,

        /** The block's edge, with nothing inside it. */
        OUTLINE,

        /** The block filled and its words redrawn in the paper's colour. */
        INVERTED,
    }

    /**
     * One thing to mark on the page: a narrated sentence, a selection, a
     * stored highlight — its rectangles grouped by line, as
     * [ChapterLayout.highlightLines] and [ChapterLayout.lines] give them.
     */
    data class Mark(val lines: List<List<PageRect>>, val color: Rgba, val treatment: Treatment = Treatment.FILL)

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
        val shapes = marks.mapNotNull { mark ->
            HighlightBlock.path(lines = mark.lines, style = style).takeUnless { it.isEmpty }?.let { mark to it.toAndroidPath() }
        }
        val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.style = Paint.Style.FILL }
        for ((mark, shape) in shapes) {
            if (mark.treatment != Treatment.FILL && mark.treatment != Treatment.INVERTED) continue
            fill.color = mark.color.argb
            canvas.drawPath(shape, fill)
        }
        layout.draw(page, canvas)
        val scale = layout.scale.toFloat()
        for ((mark, shape) in shapes) {
            when (mark.treatment) {
                Treatment.FILL -> Unit
                Treatment.UNDERLINE -> drawRules(canvas, mark, width = NARRATION_UNDERLINE * scale, dash = null, scale)
                Treatment.DASHED_UNDERLINE -> drawRules(canvas, mark, width = HIGHLIGHT_UNDERLINE * scale, dash = HIGHLIGHT_DASH * scale, scale)
                Treatment.OUTLINE -> canvas.drawPath(
                    shape,
                    Paint(Paint.ANTI_ALIAS_FLAG).apply {
                        this.style = Paint.Style.STROKE
                        color = mark.color.argb
                        strokeWidth = NARRATION_OUTLINE * scale
                        strokeJoin = Paint.Join.ROUND
                    },
                )
                // The block went under the text, so a picture in the sentence
                // stays on top of it, and this redraws only the words.
                Treatment.INVERTED -> {
                    val saved = canvas.save()
                    canvas.clipPath(shape)
                    layout.draw(page, canvas, ink = Color.WHITE)
                    canvas.restoreToCount(saved)
                }
            }
        }
    }

    /**
     * A line under each line of [mark]. Inside the line's box, across the
     * descenders: below it is the next line's top at tight spacing, and on a
     * page's last line, nothing that is drawn.
     */
    private fun drawRules(canvas: Canvas, mark: Mark, width: Float, dash: Float?, scale: Float) {
        val rule = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            color = mark.color.argb
            strokeWidth = width
            if (dash != null) pathEffect = DashPathEffect(floatArrayOf(dash, dash / 2), 0f)
        }
        for (line in mark.lines) {
            if (line.isEmpty()) continue
            val y = line.maxOf { it.maxY }.toFloat() - RULE_LIFT * scale - width / 2
            canvas.drawLine(line.minOf { it.minX }.toFloat(), y, line.maxOf { it.maxX }.toFloat(), y, rule)
        }
    }

    // E-Ink mode's marks, in dp.
    private const val NARRATION_UNDERLINE = 3f
    private const val NARRATION_OUTLINE = 1.5f
    private const val HIGHLIGHT_UNDERLINE = 2f
    private const val HIGHLIGHT_DASH = 6f
    private const val RULE_LIFT = 1f

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
