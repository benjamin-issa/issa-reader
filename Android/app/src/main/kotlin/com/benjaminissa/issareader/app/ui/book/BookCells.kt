package com.benjaminissa.issareader.app.ui.book

import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.benjaminissa.issareader.app.ui.shell.BookDetailRoute
import com.benjaminissa.issareader.app.ui.shell.LocalTabNavigator
import com.benjaminissa.issareader.app.ui.shell.appModel
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.BookFormat
import com.benjaminissa.issareader.core.model.SeriesText
import com.benjaminissa.issareader.ui.BookCell
import com.benjaminissa.issareader.ui.CoverRail
import com.benjaminissa.issareader.ui.FormatMark
import com.benjaminissa.issareader.ui.Metrics
import com.benjaminissa.issareader.ui.RailBook

/**
 * How a cover opens its book: its page, pushed on the tab the cover is in —
 * Swift's `BookLink`. Null while signed out, when a cover is inert.
 */
@Composable
fun rememberOpenBook(): ((Book) -> Unit)? {
    val navigator = LocalTabNavigator.current
    if (appModel.session == null) return null
    return { book -> navigator.push(BookDetailRoute(book.uuid)) }
}

/** The numeral a cover carries on a screen about one series, when the server numbered it there. */
fun seriesOrdinal(book: Book, series: String?): String? =
    series?.let { book.membership(it)?.position }?.let(SeriesText::ordinal)

/**
 * Whether a book can be listened to, in one glyph: the waveform for a
 * read-along, headphones for an audiobook. Reads `servableFormats`, so it
 * never promises narration the server has a row for but no file behind.
 */
fun formatMark(book: Book): FormatMark? {
    val formats = book.servableFormats
    return when {
        BookFormat.READALOUD in formats -> FormatMark.READALONG
        BookFormat.AUDIOBOOK in formats -> FormatMark.AUDIOBOOK
        else -> null
    }
}

/**
 * A book in a grid: the cover with its marks, the title on two reserved lines
 * and the byline — or [caption] in its place — and the book's menu on a long
 * press. Swift's `BookGridItem`.
 *
 * @param series the series the screen is about, if it is about one: only
 *   there does a numeral on a cover answer a question.
 */
@Composable
fun BookGridItem(
    book: Book,
    modifier: Modifier = Modifier,
    showsFormatMark: Boolean = true,
    series: String? = null,
    caption: String? = null,
) {
    val open = rememberOpenBook()
    BookMenuBox(book, modifier.testTag("cell.book.${book.uuid}")) { openMenu ->
        BookCell(
            cover = { BookCover(book) },
            title = book.title,
            caption = caption ?: book.byline,
            progress = book.progress,
            formatMark = if (showsFormatMark) formatMark(book) else null,
            seriesOrdinal = seriesOrdinal(book, series),
            onClick = open?.let { { it(book) } },
            onLongClick = openMenu,
        )
    }
}

/**
 * A horizontal shelf of covers with a title and, when there is somewhere to
 * go, a "See all": one rail for the book page's related books, the Library's
 * Browse screen and the Reading tab's queue, so they cannot drift. Drawn edge
 * to edge, its first cover keeping the screen's margin.
 *
 * @param series the series this rail is, when it is one: its covers then
 *   carry their number in it.
 */
@Composable
fun BookRail(
    title: String,
    books: List<Book>,
    modifier: Modifier = Modifier,
    coverWidth: Dp = 84.dp,
    series: String? = null,
    onSeeAll: (() -> Unit)? = null,
) {
    val open = rememberOpenBook()
    CoverRail(title, books, key = { it.uuid }, modifier = modifier.testTag(railTag(title)), onSeeAll = onSeeAll) { book ->
        BookMenuBox(book) { openMenu ->
            RailBook(
                cover = { BookCover(book, Modifier.width(coverWidth)) },
                title = book.title,
                coverWidth = coverWidth,
                seriesOrdinal = seriesOrdinal(book, series),
                onClick = open?.let { { it(book) } },
                onLongClick = openMenu,
            )
        }
    }
}

/** A rail's test tag, as Swift's identifier spells it: "rail.up-next-·-to-read". */
fun railTag(title: String): String = "rail." + title.lowercase().replace(" ", "-")

/**
 * The grid's columns: as many as fit at [minimum] with [spacing] between,
 * each sharing the width but never wider than [maximum] — SwiftUI's
 * `GridItem(.adaptive(minimum:maximum:))`, which leaves the spare width at
 * the trailing edge rather than stretching a cover past its largest size.
 */
object CoverGrid {
    val minimum: Dp = 108.dp
    val maximum: Dp = 160.dp
    val columnSpacing: Dp = Metrics.spacing16
    val rowSpacing: Dp = Metrics.spacing24

    /** How many columns, and how wide each is, in pixels. */
    fun columns(available: Int, spacing: Int, minimum: Int, maximum: Int): Pair<Int, Int> {
        val count = maxOf(1, (available + spacing) / (minimum + spacing))
        val width = ((available - spacing * (count - 1)) / count).coerceAtMost(maximum).coerceAtLeast(0)
        return count to width
    }

    /** The same, as a lazy grid's cells. */
    val cells: GridCells = object : GridCells {
        override fun Density.calculateCrossAxisCellSizes(availableSize: Int, spacing: Int): List<Int> {
            val (count, width) = columns(availableSize, spacing, minimum.roundToPx(), maximum.roundToPx())
            return List(count) { width }
        }
    }
}

/**
 * The cover grid drawn eagerly, for a page with a handful of books inside a
 * scroll of its own: a series, a tag's reading stage. Rows size to their
 * tallest cell with every cell at its top, so a title wrapping to two lines
 * does not push its neighbours down.
 */
@Composable
fun StaticBookGrid(
    books: List<Book>,
    modifier: Modifier = Modifier,
    series: String? = null,
    showsFormatMark: Boolean = true,
    caption: ((Book) -> String?)? = null,
) {
    Layout(
        modifier = modifier,
        content = {
            for (book in books) {
                BookGridItem(book, showsFormatMark = showsFormatMark, series = series, caption = caption?.invoke(book))
            }
        },
    ) { measurables, constraints ->
        val spacing = CoverGrid.columnSpacing.roundToPx()
        val rowGap = CoverGrid.rowSpacing.roundToPx()
        val (count, width) = CoverGrid.columns(constraints.maxWidth, spacing, CoverGrid.minimum.roundToPx(), CoverGrid.maximum.roundToPx())
        val placeables = measurables.map { it.measure(Constraints.fixedWidth(width)) }
        val rows = placeables.chunked(count)
        val heights = rows.map { row -> row.maxOf { it.height } }
        val height = heights.sum() + rowGap * (rows.size - 1).coerceAtLeast(0)
        layout(constraints.maxWidth, height) {
            var y = 0
            rows.forEachIndexed { index, row ->
                row.forEachIndexed { column, placeable -> placeable.place(column * (width + spacing), y) }
                y += heights[index] + rowGap
            }
        }
    }
}
