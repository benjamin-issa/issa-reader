package com.benjaminissa.issareader.app.widget

import android.app.Application
import android.content.Context
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Shader
import android.os.Bundle
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.glance.appwidget.ExperimentalGlanceRemoteViewsApi
import androidx.glance.appwidget.GlanceRemoteViews
import androidx.test.core.app.ApplicationProvider
import com.benjaminissa.issareader.core.CurrentBookSnapshot
import com.benjaminissa.issareader.core.OtherBook
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.ByteArrayOutputStream
import java.io.File

/**
 * The home-screen widget, drawn: Small (both ways of framing a cover), Medium
 * and Large, light and dark, with a long title and none, one and four other
 * books. The pictures land in `app/build/widget-shots/`, for looking at; the
 * click tests read the intents the drawn views would fire.
 */
@OptIn(ExperimentalGlanceRemoteViewsApi::class)
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(qualifiers = "w402dp-h874dp-xxhdpi")
class CurrentBookWidgetTest {
    private val context: Context get() = ApplicationProvider.getApplicationContext()

    private val longTitle = "The Strange Case of Dr Jekyll and Mr Hyde"

    private fun snapshot(others: Int = 0, square: Boolean = false, title: String = longTitle, otherTitle: String? = null) = CurrentBookSnapshot(
        bookId = "current", title = title, author = "Robert Louis Stevenson",
        chapter = "Chapter 3 · A Caucus-Race and a Long Tale", progress = 0.42, remaining = 6 * 3600.0 + 12 * 60,
        coverBookId = "current", coverIsSquare = square,
        others = listOf(
            OtherBook("book-1", "Moby-Dick", progress = 0.18),
            OtherBook("book-2", "Dracula", progress = 0.55),
            OtherBook("book-3", "Emma", progress = 0.3),
            OtherBook("book-4", "Walden", progress = 0.8),
        ).take(others).mapIndexed { i, other -> if (i == 0 && otherTitle != null) other.copy(title = otherTitle) else other },
    )

    private val palette = listOf(
        0xFF3F8A71.toInt() to 0xFF1E4A3C.toInt(), 0xFF3B5A94.toInt() to 0xFF243A66.toInt(),
        0xFF8A3A4A.toInt() to 0xFF5A2331.toInt(), 0xFFA87420.toInt() to 0xFF6E4B14.toInt(),
        0xFF5E6B3A.toInt() to 0xFF3A4424.toInt(),
    )

    /** A stand-in cover with its lettering near the top and the bottom, where a crop would take it. */
    private fun fakeCover(seed: Int, title: String, square: Boolean = false, light: Boolean = false): ByteArray {
        val w = 320
        val h = if (square) 320 else 480
        val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val (top, bottom) = if (light) 0xFFF3EAD3.toInt() to 0xFFE2D4B4.toInt() else palette[seed % palette.size]
        canvas.drawRect(0f, 0f, w.toFloat(), h.toFloat(), Paint().apply { shader = LinearGradient(0f, 0f, 0f, h.toFloat(), top, bottom, Shader.TileMode.CLAMP) })
        val ink = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = if (light) Color.rgb(60, 40, 20) else Color.WHITE; textAlign = Paint.Align.CENTER; textSize = 30f; isFakeBoldText = true }
        canvas.drawCircle(w * 0.8f, h * 0.3f, w * 0.3f, Paint().apply { color = Color.argb(40, 255, 255, 255) })
        canvas.drawText(title.uppercase().take(18), w / 2f, h * 0.12f, ink)
        canvas.drawText("A NOVEL", w / 2f, h * 0.93f, ink.apply { textSize = 22f })
        return ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.JPEG, 85, it) }.toByteArray()
    }

    private fun data(snapshot: CurrentBookSnapshot?, cover: Boolean = true, light: Boolean = false) = WidgetData(
        snapshot = snapshot,
        coverBytes = if (cover && snapshot != null) fakeCover(0, snapshot.title, snapshot.coverIsSquare, light) else null,
        otherCovers = snapshot?.others.orEmpty().mapIndexed { i, o -> o.bookId to fakeCover(i + 1, o.title) }.toMap(),
    )

    private fun configured(dark: Boolean): Context {
        val configuration = Configuration(context.resources.configuration)
        configuration.uiMode = (configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or
            if (dark) Configuration.UI_MODE_NIGHT_YES else Configuration.UI_MODE_NIGHT_NO
        return context.createConfigurationContext(configuration)
    }

    /** Composes [size]'s layout and inflates it at that size, as the launcher would. */
    private fun inflate(size: DpSize, data: WidgetData, style: SmallCoverStyle = SmallCoverStyle.FILL, dark: Boolean = false, bitmaps: WidgetBitmaps = WidgetBitmaps(context)): View {
        val views = runBlocking {
            GlanceRemoteViews().compose(context, size, null, Bundle()) {
                CurrentBookWidgetContent(context, data, style, bitmaps)
            }.remoteViews
        }
        val host = configured(dark)
        val density = host.resources.displayMetrics.density
        val parent = FrameLayout(host)
        val view = views.apply(host, parent)
        parent.addView(view, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        val w = (size.width.value * density).toInt()
        val h = (size.height.value * density).toInt()
        parent.measure(View.MeasureSpec.makeMeasureSpec(w, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(h, View.MeasureSpec.EXACTLY))
        parent.layout(0, 0, w, h)
        return parent
    }

    private fun shot(name: String, size: DpSize, data: WidgetData, style: SmallCoverStyle = SmallCoverStyle.FILL, dark: Boolean = false) {
        val view = inflate(size, data, style, dark)
        val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
        view.draw(Canvas(bitmap))
        val file = File("build/widget-shots/$name.png").apply { parentFile?.mkdirs() }
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }

    private val small = DpSize(158.dp, 158.dp)
    private val medium = DpSize(338.dp, 158.dp)
    private val large = DpSize(338.dp, 354.dp)

    /** Records the pictures; the assertions are in the tests below. */
    @Test
    fun recordsTheShots() {
        for (dark in listOf(false, true)) {
            val mode = if (dark) "dark" else "light"
            val s = snapshot()
            shot("small-fill-$mode", small, data(s), SmallCoverStyle.FILL, dark)
            shot("small-blur-$mode", small, data(s), SmallCoverStyle.FIT_OVER_BLUR, dark)
            shot("small-lightcover-fill-$mode", small, data(s, light = true), SmallCoverStyle.FILL, dark)
            shot("small-lightcover-blur-$mode", small, data(s, light = true), SmallCoverStyle.FIT_OVER_BLUR, dark)
            shot("small-square-$mode", small, data(snapshot(square = true)), SmallCoverStyle.FILL, dark)
            shot("small-nocover-$mode", small, data(s, cover = false), SmallCoverStyle.FILL, dark)
            shot("small-narrow-$mode", DpSize(110.dp, 110.dp), data(s), SmallCoverStyle.FILL, dark)
            for (others in listOf(0, 1)) {
                shot("medium-$others-others-$mode", medium, data(snapshot(others)), dark = dark)
                shot("medium-$others-others-square-$mode", medium, data(snapshot(others, square = true)), dark = dark)
            }
            shot("medium-1-others-short-title-$mode", medium, data(snapshot(1, title = "Dracula")), dark = dark)
            shot("medium-compact-$mode", DpSize(250.dp, 110.dp), data(snapshot(1)), dark = dark)
            shot("medium-card-minimum-$mode", DpSize(250.dp, 150.dp), data(snapshot(1)), dark = dark)
            for (others in listOf(0, 1, 4)) shot("large-$others-others-$mode", large, data(snapshot(others)), dark = dark)
            shot("large-4-others-square-$mode", large, data(snapshot(4, square = true)), dark = dark)
            shot("large-4-others-small-$mode", DpSize(250.dp, 250.dp), data(snapshot(4)), dark = dark)
            shot("empty-$mode", small, data(null), dark = dark)
        }
    }

    // The "Also reading" card's title

    private val longOther = "The Adventures of Sherlock Holmes: A Scandal in Bohemia and Other Stories"

    /** The card's TextView for the other book's title, and the main title's, from a drawn widget. */
    private fun texts(root: View): List<android.widget.TextView> {
        val found = mutableListOf<android.widget.TextView>()
        fun walk(view: View) {
            if (view is android.widget.TextView) found += view
            if (view is ViewGroup) for (i in 0 until view.childCount) walk(view.getChildAt(i))
        }
        walk(root)
        return found
    }

    private fun textOf(root: View, text: String) = texts(root).first { it.text.toString() == text }

    /**
     * The main title keeps what it has in every size the launcher can pick:
     * the lines and the size the card's company already gave it. The card's
     * second line is paid for from leftover height or not at all.
     */
    @Test
    fun theMainTitleIsTheSameInEverySizeAndTheCardOnlyGrowsIntoRoomToSpare() {
        val expected = mapOf(
            // size to (lines, sp, card title lines); compact has no card at all.
            CurrentBookWidget.MEDIUM to Triple(2, 15, null),
            CurrentBookWidget.MEDIUM_CARD to Triple(3, 15, 1),
        )
        for (size in CurrentBookWidget.SIZES) {
            if (size.width < CurrentBookWidget.MEDIUM.width || size.height >= CurrentBookWidget.LARGE.height) continue
            val (lines, sp, cardLines) = expected.getValue(size)
            val compact = size.height < CurrentBookWidget.MEDIUM_CARD.height
            assertEquals("$size lines", lines, MediumColumn.titleLines(compact))
            assertEquals("$size sp", sp, MediumColumn.titleSp(compact, hasCard = !compact))
            if (!compact) {
                // The widest the column can be at this size (a stacked progress row is the tighter case).
                for (stacked in listOf(true, false)) {
                    assertEquals(
                        "$size stacked=$stacked",
                        cardLines,
                        MediumColumn.alsoReadingTitleLines(size.height.value, lines, sp, MediumColumn.AUTHOR_SP, stacked),
                    )
                }
            }
        }
    }

    /** The edge of the budget, on both sides: the same column, one dp apart. */
    @Test
    fun theCardGetsASecondLineExactlyWhenTheColumnHasRoomForIt() {
        for (stacked in listOf(false, true)) {
            val needed = 2 * MediumColumn.PAD +
                3 * MediumColumn.TITLE_SP_SMALL * MediumColumn.LINE_HEIGHT +
                MediumColumn.AUTHOR_SP * MediumColumn.LINE_HEIGHT +
                (if (stacked) MediumColumn.BAR + MediumColumn.STACK_GAP else 0) + MediumColumn.PROGRESS_SP * MediumColumn.LINE_HEIGHT +
                MediumColumn.CARD_GAP + MediumColumn.CARD_TWO_LINES
            fun lines(height: Float) = MediumColumn.alsoReadingTitleLines(height, 3, MediumColumn.TITLE_SP_SMALL, MediumColumn.AUTHOR_SP, stacked)
            assertEquals(2, lines(needed))
            assertEquals(1, lines(needed - 0.5f))
            assertEquals(1, lines(150f))
            // A book with no author needs a line less.
            assertEquals(
                2,
                MediumColumn.alsoReadingTitleLines(needed - MediumColumn.AUTHOR_SP * MediumColumn.LINE_HEIGHT, 3, MediumColumn.TITLE_SP_SMALL, null, stacked),
            )
        }
        assertEquals(40, MediumColumn.cardHeight(1))
        assertEquals(52, MediumColumn.cardHeight(2))
    }

    /**
     * Drawn: where the column has room the other title may take two lines, where
     * it has none the card is as it was, and the main title is three lines
     * either way. Long and long, long and short, short and long.
     */
    @Test
    fun theCardsTitleTakesTwoLinesWhereThereIsRoom() {
        val cases = listOf(
            "long-long" to (longTitle to longOther),
            "long-short" to (longTitle to "Emma"),
            "short-long" to ("Dracula" to longOther),
        )
        val roomy = DpSize(338.dp, 200.dp)
        for ((name, titles) in cases) {
            val (main, other) = titles
            val tight = inflate(medium, data(snapshot(1, title = main, otherTitle = other)))
            assertEquals("$name tight: the card as it was", 1, textOf(tight, other).maxLines)
            assertEquals("$name tight: the main title", 3, textOf(tight, main).maxLines)
            val room = inflate(roomy, data(snapshot(1, title = main, otherTitle = other)))
            assertEquals("$name roomy: the card's title", 2, textOf(room, other).maxLines)
            assertEquals("$name roomy: the main title is untouched", 3, textOf(room, main).maxLines)
            for (dark in listOf(false, true)) {
                val mode = if (dark) "dark" else "light"
                shot("medium-card-$name-tight-$mode", medium, data(snapshot(1, title = main, otherTitle = other)), dark = dark)
                shot("medium-card-$name-roomy-$mode", roomy, data(snapshot(1, title = main, otherTitle = other)), dark = dark)
            }
        }
        // The size the launcher hands a card today.
        val card = inflate(CurrentBookWidget.MEDIUM_CARD, data(snapshot(1, otherTitle = longOther)))
        assertEquals(1, textOf(card, longOther).maxLines)
        assertEquals(3, textOf(card, longTitle).maxLines)
    }

    // Click targets

    /** Every view the drawn widget would fire an intent from, in layout order: the whole widget first. */
    private fun clickedData(root: View): List<String?> {
        val clickable = mutableListOf<View>()
        fun walk(view: View) {
            if (view.hasOnClickListeners()) clickable += view
            if (view is ViewGroup) for (i in 0 until view.childCount) walk(view.getChildAt(i))
        }
        walk(root)
        val application = ApplicationProvider.getApplicationContext<Application>()
        return clickable.map { view ->
            shadowOf(application).clearNextStartedActivities()
            view.performClick()
            shadowOf(application).nextStartedActivity?.data?.toString()
        }
    }

    /** The large widget's row: the second and fourth covers open the second and fourth books, and the widget opens the current one. */
    @Test
    fun eachLargeCoverOpensItsOwnBook() {
        val snapshot = snapshot(others = 4)
        val clicks = clickedData(inflate(large, data(snapshot)))
        assertEquals("the widget, then the four covers", 5, clicks.size)
        assertEquals("issareader://book/current", clicks[0])
        assertEquals(listOf("book-1", "book-2", "book-3", "book-4").map { "issareader://book/$it" }, clicks.drop(1))
        assertEquals("issareader://book/book-2", clicks[2])
        assertEquals("issareader://book/book-4", clicks[4])
        assertNotEquals(clicks[1], clicks[2])
        assertNotEquals(clicks[1], clicks[4])
    }

    /** Fewer others, fewer targets; none, none. */
    @Test
    fun theRowHasOneTargetPerBook() {
        assertEquals(3, clickedData(inflate(large, data(snapshot(others = 2)))).size)
        assertEquals(listOf("issareader://book/current"), clickedData(inflate(large, data(snapshot(others = 0)))))
    }

    /** The medium card opens the first of the others, not the current book. */
    @Test
    fun theMediumCardOpensTheFirstOther() {
        val clicks = clickedData(inflate(medium, data(snapshot(others = 4))))
        assertEquals(listOf("issareader://book/current", "issareader://book/book-1"), clicks)
    }

    /** No other book, no card; a compact medium has no room for one. */
    @Test
    fun noCardWithoutAnotherBookOrRoom() {
        assertEquals(1, clickedData(inflate(medium, data(snapshot(others = 0)))).size)
        assertEquals(1, clickedData(inflate(DpSize(250.dp, 110.dp), data(snapshot(others = 1)))).size)
    }

    /** Small is one target: the current book. */
    @Test
    fun smallOpensTheCurrentBook() {
        assertEquals(listOf("issareader://book/current"), clickedData(inflate(small, data(snapshot(others = 4)))))
    }

    // Fresh data on every composition

    /**
     * Glance does not run `provideGlance` again for an update that arrives while
     * its session is alive; it recomposes. So the files are read in the
     * composition ([LiveCurrentBookWidgetContent]), and a composition after the
     * files change draws the new ones. The publisher writes the others list and
     * reloads, then the covers land and it reloads again: the second must not
     * show the first's placeholders. (Glance has no public handle on a live
     * session, so this drives the composition each update triggers, over the
     * real store, twice.)
     */
    @Test
    fun aRecompositionReadsTheFilesAsTheyAreNow() {
        val dir = java.nio.file.Files.createTempDirectory("widget-files").toFile()
        com.benjaminissa.issareader.core.CurrentBookSnapshotStore.configure(dir)
        try {
            val store = com.benjaminissa.issareader.core.CurrentBookSnapshotStore
            fun draw(): List<String?> {
                val views = runBlocking {
                    GlanceRemoteViews().compose(context, large, null, Bundle()) {
                        LiveCurrentBookWidgetContent(context, SmallCoverStyle.FILL, WidgetBitmaps(context))
                    }.remoteViews
                }
                val host = context
                val parent = FrameLayout(host)
                parent.addView(views.apply(host, parent))
                return clickedData(parent)
            }
            store.write(snapshot(others = 1, title = "First"))
            assertEquals(listOf("issareader://book/current", "issareader://book/book-1"), draw())
            // The others list lands, then (later) the next composition sees it.
            store.write(snapshot(others = 3, title = "Second"))
            assertEquals(4, draw().size)
            store.clear()
            assertEquals("no snapshot: the widget opens the continue route", listOf("issareader://continue"), draw())
        } finally {
            com.benjaminissa.issareader.core.CurrentBookSnapshotStore.configure(null)
            dir.deleteRecursively()
        }
    }

    // Memory

    /**
     * Every size is composed into one update, so every bitmap counts. A
     * remote-views update is held to about a screen's pixels x 4 x 1.5; this
     * keeps to a third of that on a 1080 x 2400 phone.
     */
    @Test
    fun anUpdateStaysWellUnderTheBitmapCap() {
        val bitmaps = WidgetBitmaps(context)
        val data = data(snapshot(others = 4))
        for (size in CurrentBookWidget.SIZES) inflate(size, data, SmallCoverStyle.FIT_OVER_BLUR, bitmaps = bitmaps)
        val cap = 1080L * 2400 * 4 * 3 / 2
        println("widget bitmaps: ${bitmaps.totalBytes} bytes of a $cap cap")
        assertTrue("${bitmaps.totalBytes} bytes", bitmaps.totalBytes < cap / 3)
    }

    private fun solidPng(colour: Int): ByteArray {
        val bitmap = Bitmap.createBitmap(200, 300, Bitmap.Config.ARGB_8888).also { it.eraseColor(colour) }
        return ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
    }

    /** One instance lives across a session's recompositions, so a changed book must not draw the old jacket. */
    @Test
    fun aChangedCoverIsNotServedFromTheMemo() {
        val bitmaps = WidgetBitmaps(context)
        val red = solidPng(Color.RED)
        val blue = solidPng(Color.BLUE)

        val first = bitmaps.cover("main-large", red, 100f, 150f)!!
        val second = bitmaps.cover("main-large", blue, 100f, 150f)!!
        assertNotEquals(first.getPixel(first.width / 2, first.height / 2), second.getPixel(second.width / 2, second.height / 2))
        // The same bytes are still one bitmap.
        assertTrue(bitmaps.cover("main-large", red, 100f, 150f) === first)

        val firstBlur = bitmaps.smallCover(red, false, SmallCoverStyle.FIT_OVER_BLUR, 80f)!!
        val secondBlur = bitmaps.smallCover(blue, false, SmallCoverStyle.FIT_OVER_BLUR, 80f)!!
        assertTrue(firstBlur !== secondBlur)
        assertNotEquals(firstBlur.getPixel(firstBlur.width / 2, firstBlur.height / 2), secondBlur.getPixel(secondBlur.width / 2, secondBlur.height / 2))
    }
}
