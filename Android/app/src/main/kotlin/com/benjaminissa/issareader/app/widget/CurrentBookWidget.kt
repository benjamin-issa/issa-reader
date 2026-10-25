package com.benjaminissa.issareader.app.widget

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.net.Uri
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.LocalSize
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.LinearProgressIndicator
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.appWidgetBackground
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.appwidget.updateAll
import androidx.glance.background
import androidx.glance.color.ColorProvider
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.ContentScale
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.text.FontFamily
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import com.benjaminissa.issareader.core.CurrentBookSnapshot
import com.benjaminissa.issareader.core.CurrentBookSnapshotStore
import com.benjaminissa.issareader.core.model.ReadingProgress
import com.benjaminissa.issareader.core.model.asProgression
import com.benjaminissa.issareader.ui.IssaColors
import com.benjaminissa.issareader.ui.Symbols

/**
 * "Currently Reading": the book in progress, its chapter and how far through.
 *
 * The iPhone widget's home-screen families on Android's home screen — small
 * (cover-led, with a ring), medium and large (cover beside the details).
 * Android phones have no lock-screen widgets, so the accessory families have
 * no counterpart. Glance cannot set text in a bundled font, so the title is
 * the system serif where the iPhone draws Newsreader.
 *
 * It reads the snapshot the app publishes (`CurrentBookPublisher`), never the
 * library: a widget runs on its own schedule and must not open the database.
 * A book from the reader's own files never appears in it.
 */
class CurrentBookWidget : GlanceAppWidget() {
    override val sizeMode: SizeMode = SizeMode.Responsive(setOf(SMALL, MEDIUM, LARGE))

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val snapshot = CurrentBookSnapshotStore.read()?.takeIf { it.bookId.isNotEmpty() }
        // Only if it is this book's: the cover is one shared file, written
        // after the snapshot, so between the two writes it is still the
        // previous book's jacket.
        val cover = snapshot?.takeIf { it.hasMatchingCover }
            ?.let { CurrentBookSnapshotStore.readCover() }
            ?.let { runCatching { BitmapFactory.decodeByteArray(it, 0, it.size) }.getOrNull() }
        provideContent { Content(context, snapshot, cover) }
    }

    @Composable
    private fun Content(context: Context, snapshot: CurrentBookSnapshot?, cover: Bitmap?) {
        val open = Intent(Intent.ACTION_VIEW).apply {
            data = snapshot?.let { CurrentBookSnapshotStore.deepLink(it.bookId) }?.let { Uri.parse(it.toString()) }
                ?: Uri.parse("issareader://continue")
            setPackage(context.packageName)
        }
        Box(
            modifier = GlanceModifier
                .fillMaxSize()
                .appWidgetBackground()
                .cornerRadius(16.dp)
                .background(Colors.surface)
                .padding(14.dp)
                .clickable(actionStartActivity(open)),
        ) {
            when {
                snapshot == null -> Empty()
                LocalSize.current.width < MEDIUM.width -> Small(snapshot, cover)
                else -> WithCover(snapshot, cover, large = LocalSize.current.height >= LARGE.height)
            }
        }
    }

    /** What an installed widget says when nothing is in progress: the normal state on a fresh install and after a sign-out. */
    @Composable
    private fun Empty() {
        Column(modifier = GlanceModifier.fillMaxSize(), verticalAlignment = Alignment.CenterVertically, horizontalAlignment = Alignment.CenterHorizontally) {
            Image(ImageProvider(Symbols.bookClosed), contentDescription = null, modifier = GlanceModifier.size(26.dp), colorFilter = androidx.glance.ColorFilter.tint(Colors.inkSecondary))
            Spacer(GlanceModifier.height(8.dp))
            Text("Nothing in progress", style = TextStyle(color = Colors.inkSecondary, fontSize = 11.sp))
        }
    }

    /** Cover-led, with a ring rather than a bar. */
    @Composable
    private fun Small(snapshot: CurrentBookSnapshot, cover: Bitmap?) {
        Column(modifier = GlanceModifier.fillMaxSize()) {
            Row(modifier = GlanceModifier.fillMaxWidth()) {
                Cover(cover, snapshot.coverIsSquare, height = 52)
                Spacer(GlanceModifier.defaultWeight())
                Image(ImageProvider(ring(snapshot.progress)), contentDescription = "${ReadingProgress.percent(snapshot.progress)} percent through", modifier = GlanceModifier.size(40.dp))
            }
            Spacer(GlanceModifier.defaultWeight())
            Text(snapshot.title, maxLines = 2, style = TextStyle(color = Colors.ink, fontSize = 17.sp, fontWeight = FontWeight.Medium, fontFamily = FontFamily.Serif))
            Text(snapshot.subtitle, maxLines = 1, style = TextStyle(color = Colors.inkSecondary, fontSize = 11.sp))
        }
    }

    /** Medium and large: the cover beside the text, which makes a shelf of widgets recognisable at a glance. */
    @Composable
    private fun WithCover(snapshot: CurrentBookSnapshot, cover: Bitmap?, large: Boolean) {
        Row(modifier = GlanceModifier.fillMaxSize()) {
            Cover(cover, snapshot.coverIsSquare, height = if (large) 174 else 111)
            Spacer(GlanceModifier.width(12.dp))
            Column(modifier = GlanceModifier.defaultWeight().fillMaxSize()) {
                Text(snapshot.title, maxLines = 2, style = TextStyle(color = Colors.ink, fontSize = 17.sp, fontWeight = FontWeight.Medium, fontFamily = FontFamily.Serif))
                Text(snapshot.author, maxLines = 1, style = TextStyle(color = Colors.inkTertiary, fontSize = 11.sp))
                Spacer(GlanceModifier.defaultWeight())
                snapshot.displayChapter?.let {
                    Text(it, maxLines = if (large) 3 else 1, style = TextStyle(color = Colors.inkSecondary, fontSize = 11.sp))
                    Spacer(GlanceModifier.height(4.dp))
                }
                LinearProgressIndicator(
                    progress = (snapshot.progress.asProgression ?: 0.0).toFloat(),
                    modifier = GlanceModifier.fillMaxWidth().height(4.dp),
                    color = Colors.tangerine,
                    backgroundColor = Colors.border,
                )
                Spacer(GlanceModifier.height(4.dp))
                Row(modifier = GlanceModifier.fillMaxWidth()) {
                    Text("${snapshot.percent}%", style = TextStyle(color = Colors.inkSecondary, fontSize = 11.sp))
                    Spacer(GlanceModifier.defaultWeight())
                    snapshot.remainingText?.let { Text(it, style = TextStyle(color = Colors.inkSecondary, fontSize = 11.sp)) }
                }
            }
        }
    }

    /** The cover at the app's 2:3, or square for audiobook art; a placeholder when there is none yet. */
    @Composable
    private fun Cover(cover: Bitmap?, square: Boolean, height: Int) {
        val width = if (square) height else (height * 2 / 3)
        val modifier = GlanceModifier.width(width.dp).height(height.dp).cornerRadius(6.dp)
        if (cover != null) {
            Image(ImageProvider(cover), contentDescription = null, contentScale = ContentScale.Crop, modifier = modifier)
        } else {
            Box(modifier = modifier.background(Colors.border), contentAlignment = Alignment.Center) {
                Image(ImageProvider(Symbols.bookClosed), contentDescription = null, modifier = GlanceModifier.size(16.dp), colorFilter = androidx.glance.ColorFilter.tint(Colors.inkSecondary))
            }
        }
    }

    /**
     * A ring around the percentage, drawn as a picture: Glance's circular
     * indicator only spins. Rounded the way the reader rounds, so it never
     * shows "99%" beside a ring that has closed.
     */
    private fun ring(progress: Double): Bitmap {
        val scale = 3
        val size = 40 * scale
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val stroke = 4f * scale
        val inset = stroke / 2
        val oval = RectF(inset, inset, size - inset, size - inset)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = stroke; strokeCap = Paint.Cap.ROUND }
        paint.color = LIGHT.border.toArgb()
        canvas.drawArc(oval, 0f, 360f, false, paint)
        paint.color = LIGHT.tangerine.toArgb()
        canvas.drawArc(oval, -90f, 360f * (progress.asProgression ?: 0.0).toFloat(), false, paint)
        val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = LIGHT.inkSecondary.toArgb()
            textSize = 11f * scale
            isFakeBoldText = true
            textAlign = Paint.Align.CENTER
        }
        canvas.drawText("${ReadingProgress.percent(progress)}%", size / 2f, size / 2f - (text.descent() + text.ascent()) / 2, text)
        return bitmap
    }

    private object Colors {
        val surface = ColorProvider(day = LIGHT.surface, night = DARK.surface)
        val ink = ColorProvider(day = LIGHT.ink, night = DARK.ink)
        val inkSecondary = ColorProvider(day = LIGHT.inkSecondary, night = DARK.inkSecondary)
        val inkTertiary = ColorProvider(day = LIGHT.inkTertiary, night = DARK.inkTertiary)
        val tangerine = ColorProvider(day = LIGHT.tangerine, night = DARK.tangerine)
        val border = ColorProvider(day = LIGHT.border, night = DARK.border)
    }

    companion object {
        private val LIGHT = IssaColors.Light
        private val DARK = IssaColors.Dark
        private val SMALL = DpSize(110.dp, 110.dp)
        private val MEDIUM = DpSize(250.dp, 110.dp)
        private val LARGE = DpSize(250.dp, 250.dp)

        /** Asks every placed widget to redraw from the current snapshot. */
        suspend fun reload(context: Context) {
            CurrentBookWidget().updateAll(context)
        }
    }
}

private fun Color.toArgb(): Int = android.graphics.Color.argb((alpha * 255).toInt(), (red * 255).toInt(), (green * 255).toInt(), (blue * 255).toInt())

/** The widget's receiver, which the manifest declares. */
class CurrentBookWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = CurrentBookWidget()
}
