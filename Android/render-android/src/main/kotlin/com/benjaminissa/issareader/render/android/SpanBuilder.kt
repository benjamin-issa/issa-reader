package com.benjaminissa.issareader.render.android

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.TextPaint
import android.text.style.LineHeightSpan
import android.text.style.MetricAffectingSpan
import android.text.style.ReplacementSpan
import android.text.style.UnderlineSpan
import com.benjaminissa.issareader.render.ChapterPlate
import com.benjaminissa.issareader.render.ImageAttachment
import com.benjaminissa.issareader.render.ReaderStyle
import com.benjaminissa.issareader.render.RunStyle
import com.benjaminissa.issareader.render.StyledChapter
import kotlin.math.roundToInt

/**
 * A chapter's style runs as Android text: one face span per run, an underline
 * where the book asked for one, and a replacement span holding each plate's
 * place. The Swift parser's `attributes(for:)`, applied after the fact — the
 * string was settled by `ChapterParser` and nothing here can change it.
 *
 * Colour is never a span. The ink is the paint's, so a theme change repaints a
 * laid-out chapter without touching its text or its layout (see
 * [ChapterLayout.recolour]); a colour baked into the text, as TextKit's
 * `.foregroundColor` is, is what made the Swift reader re-parse a chapter at
 * sunset.
 *
 * Faces are resolved once per distinct request for the life of one builder —
 * the Swift parser's `FontCache`. Owned by the builder and thrown away with
 * it, rather than kept for the process: fonts are registered while the app
 * runs (a reader's imported face whenever they add one, a book's own when it
 * opens), and an answer cached before a registration is an answer to a
 * different question.
 *
 * @param scale pixels per point: the page is laid out in pixels, and every
 *   length the parser hands over — the reading size, indents, plate sizes — is
 *   in points.
 */
class SpanBuilder(
    private val fonts: ReaderFonts,
    private val style: ReaderStyle,
    private val scale: Double,
) {
    private data class Key(val italic: Boolean, val bold: Boolean, val sizeScale: Double)

    private val faces = HashMap<Key, ResolvedFace>()

    /** The face a run is set in, resolved once per italic, bold and size. */
    fun face(run: RunStyle): ResolvedFace = faces.getOrPut(Key(run.italic, run.bold, run.sizeScale)) {
        fonts.bodyFace(style, italic = run.italic, bold = run.bold, scale = run.sizeScale)
    }

    /** The point size a run is set at, in pixels. */
    fun sizePx(run: RunStyle): Float = (style.fontSize * run.sizeScale * scale).toFloat()

    /** The whole chapter as spans over its own string. Plates get a [PlateSpan] each, which [plateSpans] returns. */
    fun build(chapter: StyledChapter): SpannableStringBuilder {
        val text = SpannableStringBuilder(chapter.text)
        for (run in chapter.runs) {
            text.setSpan(FaceSpan(face(run.style), sizePx(run.style)), run.start, run.end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            if (run.style.underlined) text.setSpan(UnderlineSpan(), run.start, run.end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            val plate = run.plateIndex?.let { chapter.plates.getOrNull(it) } ?: continue
            if (plate.offset in run.start until run.end) {
                text.setSpan(PlateSpan(plate, scale), plate.offset, plate.offset + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
        }
        return text
    }
}

/** The face and size of a run. Metric-affecting, so measurement and drawing agree. */
class FaceSpan(val face: ResolvedFace, val sizePx: Float) : MetricAffectingSpan() {
    /** The face's own ascent and descent at this size: what a line of it is naturally. */
    val metrics: Paint.FontMetricsInt by lazy { TextPaint(Paint.ANTI_ALIAS_FLAG).also(::apply).fontMetricsInt }

    override fun updateMeasureState(paint: TextPaint) = apply(paint)

    override fun updateDrawState(paint: TextPaint) = apply(paint)

    private fun apply(paint: TextPaint) {
        paint.typeface = face.typeface
        paint.textSize = sizePx
        // Never a fake: a family without the member was asked for is set in
        // the member it has (see `ReaderFonts`).
        paint.isFakeBoldText = false
        paint.textSkewX = 0f
    }
}

/**
 * TextKit's `lineHeightMultiple`: each line's natural height times the
 * paragraph's multiple — Tight 1.05, Normal 1.20, Roomy 1.42, and a heading's
 * 0.82 of that — with the difference above the baseline, where TextKit puts
 * it. A multiple of zero, which is TextKit's "unset", leaves the line alone.
 *
 * The natural height is worked out from the faces on the line, not read off
 * the metrics `StaticLayout` hands in: for the second and later lines of a
 * run those are the previous line's *after* this span adjusted them, so
 * multiplying them compounded line by line — every line of a long paragraph
 * a fifth taller than the one before it.
 */
class LineHeightMultipleSpan(val multiple: Double) : LineHeightSpan {
    override fun chooseHeight(text: CharSequence, start: Int, end: Int, spanstartv: Int, lineHeight: Int, fm: Paint.FontMetricsInt) {
        if (!(multiple > 0)) return
        val faces = (text as? Spanned)?.getSpans(start, end, FaceSpan::class.java).orEmpty()
        if (faces.isEmpty()) return
        var ascent = 0
        var descent = 0
        for (face in faces) {
            ascent = minOf(ascent, face.metrics.ascent)
            descent = maxOf(descent, face.metrics.descent)
        }
        val natural = descent - ascent
        fm.descent = descent
        fm.ascent = descent - (natural * multiple).roundToInt()
        fm.top = fm.ascent
        fm.bottom = fm.descent
    }
}

/**
 * An illustration's place in a line: the Swift client's `ImageAttachment`.
 *
 * Sized to its display size, never wider than the column it lands in
 * ([ImageAttachment.bounds]) — a plate that overflows the measure would be
 * clipped rather than scaled. Sitting on the baseline, as an attachment does,
 * and nothing below it.
 *
 * The pixels are decoded only when the plate is drawn ([PlateBitmaps]): laying
 * a chapter out is not drawing it, and the reader lays out every page of a
 * chapter at each open and each typeface step.
 */
class PlateSpan(val plate: ChapterPlate, private val scale: Double) : ReplacementSpan() {
    /** The column this plate lands in, in pixels; set by the layout before each pass. */
    var availableWidthPx: Double = Double.MAX_VALUE

    private val bitmapPaint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)

    /** The size it is drawn at, in pixels. */
    val sizePx: ImageAttachment.Size
        get() {
            val bounds = ImageAttachment.bounds(plate.displayWidth, plate.displayHeight, availableWidthPx / scale)
            return ImageAttachment.Size(bounds.width * scale, bounds.height * scale)
        }

    override fun getSize(paint: Paint, text: CharSequence?, start: Int, end: Int, fm: Paint.FontMetricsInt?): Int {
        val size = sizePx
        if (fm != null) {
            fm.ascent = -size.height.roundToInt()
            fm.top = fm.ascent
            fm.descent = 0
            fm.bottom = 0
        }
        return size.width.roundToInt()
    }

    override fun draw(
        canvas: Canvas,
        text: CharSequence?,
        start: Int,
        end: Int,
        x: Float,
        top: Int,
        y: Int,
        bottom: Int,
        paint: Paint,
    ) {
        val bitmap = PlateBitmaps.bitmap(plate.artwork) ?: return
        val size = sizePx
        val width = size.width.roundToInt().toFloat()
        val height = size.height.roundToInt().toFloat()
        canvas.drawBitmap(bitmap, null, RectF(x, y - height, x + width, y.toFloat()), bitmapPaint)
    }
}
