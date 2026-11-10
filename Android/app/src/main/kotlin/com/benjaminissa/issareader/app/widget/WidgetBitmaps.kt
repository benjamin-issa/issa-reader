package com.benjaminissa.issareader.app.widget

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Shader
import androidx.core.content.res.ResourcesCompat
import com.benjaminissa.issareader.R
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** How the small widget frames a 2:3 cover in its square. */
internal enum class SmallCoverStyle {
    /** Aspect-fill: the cover fills the square and loses about a third of its height. */
    FILL,

    /** Aspect-fit, centred over a blurred, darkened copy of itself: nothing is cropped. */
    FIT_OVER_BLUR,
}

/**
 * Everything the widget draws that Glance cannot: a gradient, a blur, a
 * tracked caption, a rounded logo. Each is a Bitmap, drawn once per update.
 *
 * Remote views carry their bitmaps in the update itself, under a cap of about
 * a screen's worth of pixels (screen width x height x 4 x 1.5). So covers are
 * decoded at the size they are drawn, never the size they arrived, and one
 * instance of this class memoises by key: the widget composes every size
 * bucket in one update, and a bitmap two buckets share is sent once.
 */
internal class WidgetBitmaps(context: Context) {
    private val resources = context.resources
    private val density = min(resources.displayMetrics.density, 3f)
    private val appContext = context.applicationContext
    private val memo = mutableMapOf<String, Bitmap?>()

    /** The pixel size of [dp] at the widget's density, capped at xxhdpi. */
    fun px(dp: Float): Int = max(1, (dp * density).roundToInt())

    /** [bitmap]'s size in dp, so an image can be laid out at its own size. */
    fun dp(pixels: Int): Float = pixels / density

    /** Bytes the memoised bitmaps hold: the figure a test checks against the remote-views cap. */
    val totalBytes: Long get() = memo.values.filterNotNull().distinct().sumOf { it.allocationByteCount.toLong() }

    private fun memoised(key: String, make: () -> Bitmap?): Bitmap? = memo.getOrPut(key, make)

    /** A cover decoded to cover a [widthDp] x [heightDp] box, never larger than that needs. */
    fun cover(key: String, bytes: ByteArray?, widthDp: Float, heightDp: Float): Bitmap? {
        bytes ?: return null
        return memoised("$key@${widthDp}x$heightDp") { decodeCovering(bytes, px(widthDp), px(heightDp)) }
    }

    /** The small widget's cover in the chosen [style]; a square cover is always aspect-filled. */
    fun smallCover(bytes: ByteArray?, square: Boolean, style: SmallCoverStyle, sideDp: Float): Bitmap? {
        bytes ?: return null
        val side = px(sideDp)
        if (square || style == SmallCoverStyle.FILL) return cover("main", bytes, sideDp, sideDp)
        return memoised("main-blur@$side") { decodeCovering(bytes, side, side)?.let { fitOverBlur(it, side) } }
    }

    /** A strip one pixel-ish wide: stretched across the widget, whatever its width. */
    fun haze(heightDp: Float): Bitmap = memoised("haze@$heightDp") { haze(px(heightDp)) }!!

    fun logo(sizeDp: Float): Bitmap = memoised("logo@$sizeDp") { logo(appContext, px(sizeDp)) }!!

    /** Black text, tracked, to be tinted by the caller. Its size in dp is `dp(bitmap.width)` by `dp(bitmap.height)`. */
    fun caption(text: String, sizeSp: Float, trackingEm: Float = 0.12f): Bitmap =
        memoised("caption:$text@$sizeSp") { caption(text, px(sizeSp), trackingEm) }!!

    companion object {
        /** Black at 84% at the bottom edge, 66% at mid-height, nothing at the top. */
        fun haze(heightPx: Int): Bitmap {
            val bitmap = Bitmap.createBitmap(4, heightPx, Bitmap.Config.ARGB_8888)
            val paint = Paint().apply {
                shader = LinearGradient(
                    0f, 0f, 0f, heightPx.toFloat(),
                    intArrayOf(Color.argb(0, 0, 0, 0), Color.argb(168, 0, 0, 0), Color.argb(214, 0, 0, 0)),
                    floatArrayOf(0f, 0.5f, 1f), Shader.TileMode.CLAMP,
                )
            }
            Canvas(bitmap).drawRect(0f, 0f, 4f, heightPx.toFloat(), paint)
            return bitmap
        }

        /**
         * Decoded so that it still covers a [widthPx] x [heightPx] box, and
         * no bigger: sampled by the decoder, then scaled the last step.
         */
        fun decodeCovering(bytes: ByteArray, widthPx: Int, heightPx: Int): Bitmap? {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
            val scale = max(widthPx.toFloat() / bounds.outWidth, heightPx.toFloat() / bounds.outHeight)
            var sample = 1
            while (scale * sample * 2 <= 1f) sample *= 2
            val decoded = runCatching {
                BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })
            }.getOrNull() ?: return null
            val remaining = scale * sample
            if (remaining >= 1f) return decoded
            val width = max(1, (decoded.width * remaining).roundToInt())
            val height = max(1, (decoded.height * remaining).roundToInt())
            return Bitmap.createScaledBitmap(decoded, width, height, true).also { if (it !== decoded) decoded.recycle() }
        }

        /** [cover], aspect-fit and centred, over a darkened and blurred copy of itself that fills [side] square. */
        fun fitOverBlur(cover: Bitmap, side: Int): Bitmap {
            val out = Bitmap.createBitmap(side, side, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(out)
            val smooth = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
            // Blur without a toolkit: shrink to a handful of pixels, then grow back in two steps.
            val tiny = Bitmap.createBitmap(12, 12, Bitmap.Config.ARGB_8888)
            drawCropped(Canvas(tiny), cover, 12, smooth)
            val mid = Bitmap.createScaledBitmap(tiny, 48, 48, true)
            canvas.drawBitmap(mid, null, RectF(0f, 0f, side.toFloat(), side.toFloat()), smooth)
            canvas.drawColor(Color.argb(120, 0, 0, 0))
            val scale = min(side.toFloat() / cover.width, side.toFloat() / cover.height)
            val w = cover.width * scale
            val h = cover.height * scale
            val left = (side - w) / 2
            val top = (side - h) / 2
            canvas.drawBitmap(cover, null, RectF(left, top, left + w, top + h), smooth)
            return out
        }

        private fun drawCropped(canvas: Canvas, cover: Bitmap, side: Int, paint: Paint) {
            val scale = max(side.toFloat() / cover.width, side.toFloat() / cover.height)
            val w = cover.width * scale
            val h = cover.height * scale
            canvas.drawBitmap(cover, null, RectF((side - w) / 2, (side - h) / 2, (side + w) / 2, (side + h) / 2), paint)
        }

        /**
         * The app's icon on its slate tile, [sizePx] square with the continuous-ish 22% corner the
         * iPhone's widget draws. The mark is the launcher's foreground layer, centred and scaled
         * so it fills most of the tile.
         */
        fun logo(context: Context, sizePx: Int): Bitmap {
            val bitmap = Bitmap.createBitmap(sizePx, sizePx, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = SLATE }
            val radius = sizePx * 0.22f
            canvas.drawRoundRect(RectF(0f, 0f, sizePx.toFloat(), sizePx.toFloat()), radius, radius, paint)
            val mark = ResourcesCompat.getDrawable(context.resources, R.drawable.ic_launcher_foreground, null) ?: return bitmap
            // The mark spans x 83..187 and y 68..190 of the layer's 270 unit viewport.
            val k = sizePx * 0.80f / 122f
            val left = (sizePx / 2f - 135f * k).roundToInt()
            val top = (sizePx / 2f - 129f * k).roundToInt()
            mark.setBounds(left, top, left + (270 * k).roundToInt(), top + (270 * k).roundToInt())
            mark.draw(canvas)
            return bitmap
        }

        /** The app's slate, which the tile keeps in dark mode too (the iPhone's does). */
        const val SLATE = 0xFF2F3A3F.toInt()

        fun caption(text: String, textPx: Int, trackingEm: Float): Bitmap {
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = Color.BLACK
                textSize = textPx.toFloat()
                letterSpacing = trackingEm
                isFakeBoldText = true
            }
            val width = paint.measureText(text).roundToInt() + 2
            val height = (paint.descent() - paint.ascent()).roundToInt() + 2
            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            Canvas(bitmap).drawText(text, 0f, -paint.ascent() + 1, paint)
            return bitmap
        }
    }
}
