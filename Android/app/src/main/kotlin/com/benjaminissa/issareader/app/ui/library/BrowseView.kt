package com.benjaminissa.issareader.app.ui.library

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import com.benjaminissa.issareader.app.model.AppModel
import com.benjaminissa.issareader.app.ui.book.BookCover
import com.benjaminissa.issareader.app.ui.book.BookRail
import com.benjaminissa.issareader.app.ui.book.CoverGrid
import com.benjaminissa.issareader.app.ui.shell.LocalTabNavigator
import com.benjaminissa.issareader.app.ui.shell.PushedScreen
import com.benjaminissa.issareader.app.ui.shell.SeriesListRoute
import com.benjaminissa.issareader.app.ui.shell.SeriesRoute
import com.benjaminissa.issareader.app.ui.shell.appModel
import com.benjaminissa.issareader.core.sync.LibraryArrangement
import com.benjaminissa.issareader.core.sync.SeriesGroup
import com.benjaminissa.issareader.ui.LocalPlayerBand
import com.benjaminissa.issareader.ui.Metrics
import com.benjaminissa.issareader.ui.PalettePlaceholder
import com.benjaminissa.issareader.ui.RailHeader
import com.benjaminissa.issareader.ui.SeriesTile
import com.benjaminissa.issareader.ui.Symbols

/**
 * The Library's Browse screen: a vertical scroll of horizontal rails. Recent
 * arrivals, your series, what has audio, and the tags you use most, each with
 * a "See all" into the flat grid on the matching shelf. Every list is
 * `LibraryRails`, derived in the model; a rail with nothing on it is left out
 * rather than shown empty. Swift's `BrowseView`, whose rails are its lazy
 * stack's own items, as they are the list's here.
 */
fun LazyListScope.browseRails(app: AppModel) {
    val rails = app.rails
    val hasRails = rails.recentlyAdded.isNotEmpty() || rails.series.isNotEmpty() || rails.withAudio.isNotEmpty() || rails.tagRails.isNotEmpty()
    if (!hasRails) {
        if (app.books.isNotEmpty()) {
            item(key = "browse.nothing") {
                // A library of undated, untagged, unseriesed, text-only books
                // has nothing to browse by. Say so, and offer the grid — never
                // a blank page under a chip reading "Browse".
                PalettePlaceholder(
                    symbol = Symbols.squareGrid2x2,
                    title = "Nothing to browse by yet",
                    message = "Series, tags and audio will appear here as your library grows.",
                    actionTitle = "Show all books",
                    action = { app.showAllBooks(shelf = LibraryArrangement.Shelf.ALL) },
                )
            }
        }
        return
    }
    if (rails.recentlyAdded.isNotEmpty()) {
        item(key = "browse.recent") {
            BookRail("Recently added", rails.recentlyAdded, coverWidth = 74.dp) {
                app.showAllBooks(shelf = LibraryArrangement.Shelf.ALL, sort = LibraryArrangement.Sort.ADDED)
            }
        }
    }
    if (rails.series.isNotEmpty()) item(key = "browse.series") { SeriesRail(rails.series) }
    if (rails.withAudio.isNotEmpty()) {
        item(key = "browse.audio") {
            BookRail("With audio", rails.withAudio, coverWidth = 74.dp) {
                app.showAllBooks(shelf = LibraryArrangement.Shelf.WITH_NARRATION)
            }
        }
    }
    for (rail in rails.tagRails) {
        item(key = "browse.tag.${rail.tag}") {
            BookRail(rail.tag, rail.books, coverWidth = 74.dp) {
                app.showAllBooks(shelf = LibraryArrangement.Shelf.ALL, tags = setOf(rail.tag))
            }
        }
    }
}

/** Your series as stacked-cover tiles, with a "See all" to the full list. */
@Composable
fun SeriesRail(series: List<SeriesGroup>, modifier: Modifier = Modifier) {
    val navigator = LocalTabNavigator.current
    Column(modifier.testTag("rail.series"), verticalArrangement = Arrangement.spacedBy(Metrics.spacing8)) {
        RailHeader("Series", onSeeAll = { navigator.push(SeriesListRoute) })
        LazyRow(
            // The rotated back cover pokes above the tile's frame.
            contentPadding = PaddingValues(start = Metrics.screenMargin, end = Metrics.screenMargin, top = Metrics.spacing4),
            horizontalArrangement = Arrangement.spacedBy(Metrics.spacing12),
            verticalAlignment = Alignment.Top,
        ) {
            items(series, key = { it.name }) { group -> SeriesGroupTile(group) }
        }
    }
}

/** One series: its first two covers fanned, a count, its name. Opens the series in reading order. */
@Composable
fun SeriesGroupTile(group: SeriesGroup, modifier: Modifier = Modifier) {
    val navigator = LocalTabNavigator.current
    // Every group has at least two books — a one-book series is not one.
    SeriesTile(
        front = { BookCover(group.books[0]) },
        back = group.books.getOrNull(1)?.let { back -> { BookCover(back) } },
        name = group.name,
        count = group.books.size,
        onClick = { navigator.push(SeriesRoute(group.name)) },
        modifier = modifier,
    )
}

/** Every series, as tiles: the Series rail's "See all". Swift's `SeriesListView`. */
@Composable
fun SeriesListScreen() {
    val app = appModel
    PushedScreen("Series") { padding ->
        LazyVerticalGrid(
            columns = SeriesTileCells,
            modifier = Modifier.padding(padding).fillMaxSize(),
            contentPadding = PaddingValues(start = Metrics.spacing16, top = Metrics.spacing16, end = Metrics.spacing16, bottom = Metrics.spacing16 + LocalPlayerBand.current),
            horizontalArrangement = Arrangement.spacedBy(Metrics.spacing16),
            verticalArrangement = Arrangement.spacedBy(Metrics.spacing24),
        ) {
            items(app.rails.series, key = { it.name }) { group -> SeriesGroupTile(group, Modifier.width(104.dp)) }
        }
    }
}

/** `GridItem(.adaptive(minimum: 104, maximum: 140))`. */
private val SeriesTileCells: GridCells = object : GridCells {
    override fun Density.calculateCrossAxisCellSizes(availableSize: Int, spacing: Int): List<Int> {
        val (count, width) = CoverGrid.columns(availableSize, spacing, 104.dp.roundToPx(), 140.dp.roundToPx())
        return List(count) { width }
    }
}
