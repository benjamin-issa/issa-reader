package com.benjaminissa.issareader.app.ui.book

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import com.benjaminissa.issareader.app.ui.shell.PushedScreen
import com.benjaminissa.issareader.app.ui.shell.appModel
import com.benjaminissa.issareader.core.download.BookMenu
import com.benjaminissa.issareader.core.model.SeriesText
import com.benjaminissa.issareader.ui.LocalPlayerBand
import com.benjaminissa.issareader.ui.Metrics
import com.benjaminissa.issareader.ui.Overline
import com.benjaminissa.issareader.ui.PalettePlaceholder
import com.benjaminissa.issareader.ui.Symbols

/**
 * A series in reading order: Swift's `SeriesView`.
 *
 * Looked up by name on every composition, as the book page looks up its book:
 * the group is derived from the catalogue, and a value handed over at
 * navigation time would stop reflecting a status or position change. A group
 * that has gone — its books removed, or down to one — says so.
 */
@Composable
fun SeriesScreen(name: String) {
    val app = appModel
    val series = app.rails.series.firstOrNull { it.name == name }
    BookRoutes(place = BookMenu.Place.Series(name)) {
        PushedScreen(name, Modifier.testTag("screen.series")) { padding ->
            if (series == null) {
                Box(Modifier.padding(padding).fillMaxSize().padding(bottom = LocalPlayerBand.current), contentAlignment = Alignment.Center) {
                    PalettePlaceholder(
                        symbol = Symbols.booksVertical,
                        title = "Series unavailable",
                        message = "These books are no longer in your library.",
                    )
                }
                return@PushedScreen
            }
            Column(
                Modifier
                    .padding(padding)
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .padding(start = Metrics.spacing16, top = Metrics.spacing16, end = Metrics.spacing16, bottom = Metrics.spacing16 + LocalPlayerBand.current),
                verticalArrangement = Arrangement.spacedBy(Metrics.spacing12),
            ) {
                Overline("${series.books.size} books")
                // The series' name is what puts the numeral on these covers:
                // the one screen a series number answers a question on. The
                // caption spells the same position out in words.
                StaticBookGrid(
                    series.books,
                    Modifier.fillMaxWidth(),
                    series = series.name,
                    caption = { book -> series.position(book)?.let(SeriesText::position) },
                )
            }
        }
    }
}
