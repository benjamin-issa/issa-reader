package com.benjaminissa.issareader.app.widget

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.ColorFilter
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
import androidx.glance.layout.fillMaxHeight
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.text.FontFamily
import androidx.glance.unit.ColorProvider as ColorProviderType
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextAlign
import androidx.glance.text.TextStyle
import com.benjaminissa.issareader.core.CurrentBookSnapshot
import com.benjaminissa.issareader.core.CurrentBookSnapshotStore
import com.benjaminissa.issareader.core.OtherBook
import com.benjaminissa.issareader.core.WidgetOthers
import com.benjaminissa.issareader.core.model.asProgression
import com.benjaminissa.issareader.ui.IssaColors
import com.benjaminissa.issareader.ui.Symbols
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * "Currently Reading": the book in progress, how far through, and the others
 * in progress beside it.
 *
 * The iPhone widget's redesign on Android's home screen. Small is the cover
 * full-bleed under a dark haze holding the progress row; medium is the cover
 * flush left beside the title, author and progress, with an "Also reading"
 * card; large adds the chapter and a row of up to four more covers. Each of
 * the others opens its own book. Android phones have no lock-screen widgets,
 * so the accessory families have no counterpart. Glance cannot set text in a
 * bundled font, so titles are the system serif where the iPhone draws
 * Newsreader.
 *
 * It reads the snapshot the app publishes (`CurrentBookPublisher`), never the
 * library: a widget runs on its own schedule and must not open the database.
 * A book from the reader's own files never appears in it.
 *
 * ### Sizes
 * A resizable widget is composed once per size in [SizeMode.Responsive] and
 * the launcher picks the largest that fits: narrower than 250 dp is small;
 * 250 dp wide and under 250 tall is medium (from 150 tall with room for the
 * card); 250 tall and over is large.
 */
class CurrentBookWidget : GlanceAppWidget() {
    override val sizeMode: SizeMode = SizeMode.Responsive(SIZES)

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val data = withContext(Dispatchers.IO) { WidgetData.load() }
        val bitmaps = WidgetBitmaps(context)
        provideContent { CurrentBookWidgetContent(context, data, widgetSmallCoverStyle, bitmaps) }
    }

    companion object {
        private val SMALL = DpSize(110.dp, 110.dp)
        private val SMALL_WIDE = DpSize(150.dp, 110.dp)
        internal val MEDIUM = DpSize(250.dp, 110.dp)
        internal val MEDIUM_CARD = DpSize(250.dp, 150.dp)
        internal val LARGE = DpSize(250.dp, 250.dp)
        internal val SIZES = setOf(SMALL, SMALL_WIDE, MEDIUM, MEDIUM_CARD, LARGE)

        /** Asks every placed widget to redraw from the current snapshot. */
        suspend fun reload(context: Context) {
            CurrentBookWidget().updateAll(context)
        }
    }
}

/**
 * How the small widget frames a cover in its square. The one switch: [SmallCoverStyle.FILL]
 * crops a 2:3 cover by a third; [SmallCoverStyle.FIT_OVER_BLUR] keeps all of it over a blurred backdrop.
 */
internal var widgetSmallCoverStyle: SmallCoverStyle = SmallCoverStyle.FILL

/** What one draw needs from disk: the snapshot and the raw bytes of the covers it names. */
internal class WidgetData(
    val snapshot: CurrentBookSnapshot?,
    val coverBytes: ByteArray?,
    /** By book id: only those whose file exists. */
    val otherCovers: Map<String, ByteArray>,
) {
    companion object {
        fun load(): WidgetData {
            val snapshot = CurrentBookSnapshotStore.read()?.takeIf { it.bookId.isNotEmpty() }
            // Only if it is this book's: the cover is one shared file, written
            // after the snapshot, so between the two writes it is still the
            // previous book's jacket.
            val cover = snapshot?.takeIf { it.hasMatchingCover }?.let { CurrentBookSnapshotStore.readCover() }
            val others = snapshot?.others.orEmpty()
                .mapNotNull { other -> CurrentBookSnapshotStore.readOtherCover(other.bookId)?.let { other.bookId to it } }
                .toMap()
            return WidgetData(snapshot, cover, others)
        }
    }
}

/** The address that opens [bookId], or the app's continue route when there is none. */
internal fun openBookIntent(context: Context, bookId: String?): Intent = Intent(Intent.ACTION_VIEW).apply {
    data = bookId?.let { CurrentBookSnapshotStore.deepLink(it) }?.let { Uri.parse(it.toString()) } ?: Uri.parse("issareader://continue")
    setPackage(context.packageName)
}

private object Colors {
    private val LIGHT = IssaColors.Light
    private val DARK = IssaColors.Dark
    val surface = ColorProvider(day = LIGHT.surface, night = DARK.surface)
    val surfaceRaised = ColorProvider(day = LIGHT.surfaceRaised, night = DARK.surfaceRaised)
    val ink = ColorProvider(day = LIGHT.ink, night = DARK.ink)
    val inkSecondary = ColorProvider(day = LIGHT.inkSecondary, night = DARK.inkSecondary)
    val tangerine = ColorProvider(day = LIGHT.tangerine, night = DARK.tangerine)
    val border = ColorProvider(day = LIGHT.border, night = DARK.border)
    val white = ColorProvider(day = Color.White, night = Color.White)
    val whiteTrack = ColorProvider(day = Color.White.copy(alpha = 0.35f), night = Color.White.copy(alpha = 0.35f))
}

@Composable
internal fun CurrentBookWidgetContent(context: Context, data: WidgetData, smallStyle: SmallCoverStyle, bitmaps: WidgetBitmaps) {
    val snapshot = data.snapshot
    val size = LocalSize.current
    Box(
        modifier = GlanceModifier
            .fillMaxSize()
            .appWidgetBackground()
            .cornerRadius(16.dp)
            .background(Colors.surface)
            .clickable(actionStartActivity(openBookIntent(context, snapshot?.bookId))),
    ) {
        when {
            snapshot == null -> Empty()
            size.width < CurrentBookWidget.MEDIUM.width -> Small(snapshot, data, smallStyle, bitmaps)
            size.height >= CurrentBookWidget.LARGE.height -> Large(context, snapshot, data, bitmaps)
            else -> Medium(context, snapshot, data, bitmaps)
        }
    }
}

/** What an installed widget says when nothing is in progress: the normal state on a fresh install and after a sign-out. */
@Composable
private fun Empty() {
    Column(modifier = GlanceModifier.fillMaxSize().padding(14.dp), verticalAlignment = Alignment.CenterVertically, horizontalAlignment = Alignment.CenterHorizontally) {
        Image(ImageProvider(Symbols.bookClosed), contentDescription = null, modifier = GlanceModifier.size(26.dp), colorFilter = ColorFilter.tint(Colors.inkSecondary))
        Spacer(GlanceModifier.height(8.dp))
        Text("Nothing in progress", style = TextStyle(color = Colors.inkSecondary, fontSize = 11.sp))
    }
}

private const val HAZE_DP = 50f
private const val SMALL_COVER_DP = 170f

/**
 * Full-bleed cover under a haze that holds the progress. No title over a real
 * cover, which carries its own; the title is in the description. With no
 * cover the placeholder has none, so it wears the title.
 */
@Composable
private fun Small(snapshot: CurrentBookSnapshot, data: WidgetData, style: SmallCoverStyle, bitmaps: WidgetBitmaps) {
    val description = listOfNotNull(snapshot.title, snapshot.author.takeIf { it.isNotEmpty() }, "${snapshot.percent} percent", snapshot.remainingText).joinToString(", ")
    val cover = bitmaps.smallCover(data.coverBytes, snapshot.coverIsSquare, style, SMALL_COVER_DP)
    val roomy = LocalSize.current.width >= 150.dp
    Box(modifier = GlanceModifier.fillMaxSize()) {
        if (cover != null) {
            Image(ImageProvider(cover), contentDescription = description, contentScale = ContentScale.Crop, modifier = GlanceModifier.fillMaxSize())
        } else {
            Box(modifier = GlanceModifier.fillMaxSize().background(Colors.border).padding(start = 14.dp, end = 14.dp, top = 14.dp, bottom = HAZE_DP.dp), contentAlignment = Alignment.Center) {
                Text(snapshot.title, maxLines = 4, style = TextStyle(color = Colors.ink, fontSize = 17.sp, fontWeight = FontWeight.Medium, fontFamily = FontFamily.Serif, textAlign = TextAlign.Center))
            }
        }
        Column(modifier = GlanceModifier.fillMaxSize(), verticalAlignment = Alignment.Bottom) {
            Box(modifier = GlanceModifier.fillMaxWidth().height(HAZE_DP.dp), contentAlignment = Alignment.BottomStart) {
                Image(ImageProvider(bitmaps.haze(HAZE_DP)), contentDescription = null, contentScale = ContentScale.FillBounds, modifier = GlanceModifier.fillMaxSize())
                if (roomy) {
                    Row(modifier = GlanceModifier.fillMaxWidth().padding(start = 12.dp, end = 12.dp, bottom = 11.dp), verticalAlignment = Alignment.CenterVertically) {
                        Bar(snapshot.progress, Colors.whiteTrack, GlanceModifier.defaultWeight())
                        Spacer(GlanceModifier.width(10.dp))
                        Text(snapshot.progressLine, maxLines = 1, style = TextStyle(color = Colors.white, fontSize = 11.sp, fontWeight = FontWeight.Medium))
                    }
                } else {
                    Column(modifier = GlanceModifier.fillMaxWidth().padding(start = 12.dp, end = 12.dp, bottom = 10.dp)) {
                        Text(snapshot.progressLine, maxLines = 1, style = TextStyle(color = Colors.white, fontSize = 11.sp, fontWeight = FontWeight.Medium))
                        Spacer(GlanceModifier.height(4.dp))
                        Bar(snapshot.progress, Colors.whiteTrack, GlanceModifier.fillMaxWidth())
                    }
                }
            }
        }
    }
}

@Composable
private fun Bar(progress: Double, track: ColorProviderType, modifier: GlanceModifier, thickness: Int = 4) {
    LinearProgressIndicator(
        progress = (progress.asProgression ?: 0.0).toFloat(),
        modifier = modifier.height(thickness.dp),
        color = Colors.tangerine,
        backgroundColor = track,
    )
}

/** The cover flush left, top and bottom: 2:3 of the height, or as wide as it is tall for square art. */
@Composable
private fun Medium(context: Context, snapshot: CurrentBookSnapshot, data: WidgetData, bitmaps: WidgetBitmaps) {
    val size = LocalSize.current
    val bytes = data.coverBytes
    val square = snapshot.coverIsSquare && bytes != null
    val height = size.height.value
    val coverWidth = if (square) height else height * 2 / 3
    val compact = size.height < CurrentBookWidget.MEDIUM_CARD.height
    val pad = 12
    val columnWidth = size.width.value - coverWidth - 2 * 14
    // A square cover leaves a column too narrow for three lines of title, a stacked progress and a card.
    val other = snapshot.others.firstOrNull().takeIf { !compact && !(square && columnWidth < 170) }
    val stacked = columnWidth < 170
    // Up to three lines, so a long title is whole; the card's company takes the smaller size.
    val titleLines = if (compact) 2 else 3
    val smallTitle = compact || other != null
    // A column under 150 dp has no room for the title to clear the logo: the title wins and the logo is left off.
    val showLogo = columnWidth >= 150

    Box(modifier = GlanceModifier.fillMaxSize()) {
        Row(modifier = GlanceModifier.fillMaxSize()) {
            CoverFlush(bitmaps.cover("main-flush", bytes, coverWidth + 40, height + 40), snapshot.title, GlanceModifier.width(coverWidth.dp).fillMaxHeight())
            Column(modifier = GlanceModifier.defaultWeight().fillMaxHeight().padding(start = 14.dp, end = 14.dp, top = pad.dp, bottom = pad.dp)) {
                Text(snapshot.title, maxLines = titleLines, modifier = GlanceModifier.padding(end = if (showLogo) 44.dp else 0.dp), style = TextStyle(color = Colors.ink, fontSize = if (smallTitle) 15.sp else 17.sp, fontWeight = FontWeight.Medium, fontFamily = FontFamily.Serif))
                if (snapshot.author.isNotEmpty()) {
                    Text(snapshot.author, maxLines = 1, style = TextStyle(color = Colors.inkSecondary, fontSize = if (compact) 12.sp else 13.sp))
                }
                Spacer(GlanceModifier.defaultWeight())
                ProgressRow(snapshot, stacked)
                if (other != null) {
                    Spacer(GlanceModifier.height(8.dp))
                    AlsoReadingCard(context, other, data, bitmaps)
                }
            }
        }
        if (showLogo) Logo(bitmaps, inset = 12)
    }
}

/** The bar and "42% · 6h 12m left": side by side, or one above the other in a narrow column. */
@Composable
private fun ProgressRow(snapshot: CurrentBookSnapshot, stacked: Boolean) {
    val text = TextStyle(color = Colors.inkSecondary, fontSize = 11.sp)
    if (stacked) {
        Column(modifier = GlanceModifier.fillMaxWidth()) {
            Bar(snapshot.progress, Colors.border, GlanceModifier.fillMaxWidth())
            Spacer(GlanceModifier.height(3.dp))
            Text(snapshot.progressLine, maxLines = 1, style = text)
        }
    } else {
        Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Bar(snapshot.progress, Colors.border, GlanceModifier.defaultWeight())
            Spacer(GlanceModifier.width(10.dp))
            Text(snapshot.progressLine, maxLines = 1, style = text)
        }
    }
}

/** A raised card for the first other book: mini cover, caption, title, percent. The whole card opens that book. */
@Composable
private fun AlsoReadingCard(context: Context, other: OtherBook, data: WidgetData, bitmaps: WidgetBitmaps) {
    val caption = bitmaps.caption("ALSO READING", 10f)
    Row(
        modifier = GlanceModifier.fillMaxWidth().height(40.dp).cornerRadius(10.dp).background(Colors.surfaceRaised)
            .padding(horizontal = 2.dp).clickable(actionStartActivity(openBookIntent(context, other.bookId))),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CoverFlush(bitmaps.cover("other-${other.bookId}", data.otherCovers[other.bookId], 24f, 36f), other.title, GlanceModifier.width(24.dp).height(36.dp).cornerRadius(5.dp))
        Spacer(GlanceModifier.width(10.dp))
        Column(modifier = GlanceModifier.defaultWeight()) {
            Image(ImageProvider(caption), contentDescription = null, colorFilter = ColorFilter.tint(Colors.inkSecondary), modifier = GlanceModifier.width(bitmaps.dp(caption.width).dp).height(bitmaps.dp(caption.height).dp))
            Text(other.title, maxLines = 1, style = TextStyle(color = Colors.ink, fontSize = 13.sp, fontWeight = FontWeight.Medium, fontFamily = FontFamily.Serif))
        }
        Spacer(GlanceModifier.width(6.dp))
        Text("${other.percent}%", maxLines = 1, style = TextStyle(color = Colors.inkSecondary, fontSize = 12.sp))
        Spacer(GlanceModifier.width(8.dp))
    }
}

@Composable
private fun Large(context: Context, snapshot: CurrentBookSnapshot, data: WidgetData, bitmaps: WidgetBitmaps) {
    val size = LocalSize.current
    val others = snapshot.others.take(WidgetOthers.LIMIT)
    val bytes = data.coverBytes
    val square = snapshot.coverIsSquare && bytes != null

    // The row of others: up to four covers across, each 2:3, no wider than 70.
    val coverW = minOf(70f, (size.width.value - 28 - 3 * 8) / 4)
    val coverH = coverW * 1.5f
    val othersBlock = if (others.isEmpty()) 0f else 18f + coverH + 4f + 30f + 10f
    val room = size.height.value - 28 - othersBlock
    val topH = room.coerceIn(90f, if (others.isEmpty()) 200f else 150f)
    val topCoverW = if (square) minOf(topH, 120f) else topH * 2 / 3
    val topCoverH = if (square) topCoverW else topH
    val tight = topH < 130f

    Box(modifier = GlanceModifier.fillMaxSize()) {
        Column(modifier = GlanceModifier.fillMaxSize().padding(14.dp)) {
            Row(modifier = GlanceModifier.fillMaxWidth().height(topH.dp)) {
                CoverFlush(bitmaps.cover("main-large", bytes, topCoverW + 10, topCoverH + 10), snapshot.title, GlanceModifier.width(topCoverW.dp).height(topCoverH.dp).cornerRadius(8.dp))
                Spacer(GlanceModifier.width(12.dp))
                Column(modifier = GlanceModifier.defaultWeight().fillMaxHeight()) {
                    Text(snapshot.title, maxLines = if (tight) 2 else 3, modifier = GlanceModifier.padding(end = 34.dp), style = TextStyle(color = Colors.ink, fontSize = 17.sp, fontWeight = FontWeight.Medium, fontFamily = FontFamily.Serif))
                    if (snapshot.author.isNotEmpty()) {
                        Text(snapshot.author, maxLines = 1, style = TextStyle(color = Colors.inkSecondary, fontSize = 13.sp))
                    }
                    snapshot.displayChapter?.takeIf { !tight }?.let {
                        Spacer(GlanceModifier.height(2.dp))
                        Text(it, maxLines = 2, style = TextStyle(color = Colors.inkSecondary, fontSize = 12.sp))
                    }
                    Spacer(GlanceModifier.defaultWeight())
                    ProgressRow(snapshot, stacked = size.width.value - 28 - topCoverW - 12 < 170)
                }
            }
            if (others.isNotEmpty()) {
                Spacer(GlanceModifier.defaultWeight())
                val caption = bitmaps.caption("ALSO IN PROGRESS", 11f)
                Image(ImageProvider(caption), contentDescription = null, colorFilter = ColorFilter.tint(Colors.inkSecondary), modifier = GlanceModifier.width(bitmaps.dp(caption.width).dp).height(bitmaps.dp(caption.height).dp))
                Spacer(GlanceModifier.height(6.dp))
                Row(modifier = GlanceModifier.fillMaxWidth()) {
                    others.forEachIndexed { index, other ->
                        if (index > 0) {
                            if (others.size == WidgetOthers.LIMIT) Spacer(GlanceModifier.defaultWeight()) else Spacer(GlanceModifier.width(8.dp))
                        }
                        OtherCover(context, other, data, bitmaps, coverW, coverH)
                    }
                    if (others.size < WidgetOthers.LIMIT) Spacer(GlanceModifier.defaultWeight())
                }
            }
        }
        Logo(bitmaps, inset = 14)
    }
}

/** One of the large widget's row: its cover with a thin bar on the bottom edge, and a two-line title. It opens its own book. */
@Composable
private fun OtherCover(context: Context, other: OtherBook, data: WidgetData, bitmaps: WidgetBitmaps, width: Float, height: Float) {
    Column(modifier = GlanceModifier.width(width.dp).clickable(actionStartActivity(openBookIntent(context, other.bookId)))) {
        Box(modifier = GlanceModifier.width(width.dp).height(height.dp), contentAlignment = Alignment.BottomStart) {
            CoverFlush(bitmaps.cover("other-${other.bookId}", data.otherCovers[other.bookId], width, height), other.title, GlanceModifier.fillMaxSize().cornerRadius(8.dp))
            Bar(other.progress, Colors.whiteTrack, GlanceModifier.fillMaxWidth(), thickness = 3)
        }
        Spacer(GlanceModifier.height(4.dp))
        Text(other.title, maxLines = 2, style = TextStyle(color = Colors.ink, fontSize = if (width < 60f) 11.sp else 12.sp, fontWeight = FontWeight.Medium, fontFamily = FontFamily.Serif))
    }
}

/** The logo in the top-right corner, [inset] dp from the top and right edges. */
@Composable
private fun Logo(bitmaps: WidgetBitmaps, inset: Int) {
    Box(modifier = GlanceModifier.fillMaxSize().padding(top = inset.dp, end = inset.dp), contentAlignment = Alignment.TopEnd) {
        Image(ImageProvider(bitmaps.logo(22f)), contentDescription = null, modifier = GlanceModifier.size(22.dp))
    }
}

/** A cover cropped into [modifier]'s box; the book glyph on the border colour when there is no file for it. */
@Composable
private fun CoverFlush(cover: Bitmap?, title: String, modifier: GlanceModifier) {
    if (cover != null) {
        Image(ImageProvider(cover), contentDescription = title, contentScale = ContentScale.Crop, modifier = modifier)
    } else {
        Box(modifier = modifier.background(Colors.border), contentAlignment = Alignment.Center) {
            Image(ImageProvider(Symbols.bookClosed), contentDescription = null, modifier = GlanceModifier.size(16.dp), colorFilter = ColorFilter.tint(Colors.inkSecondary))
        }
    }
}

/** The widget's receiver, which the manifest declares. */
class CurrentBookWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = CurrentBookWidget()
}
