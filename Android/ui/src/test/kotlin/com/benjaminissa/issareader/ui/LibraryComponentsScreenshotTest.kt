package com.benjaminissa.issareader.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.material3.Text
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.github.takahirom.roborazzi.captureRoboImage
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** The library family's pieces laid out as the iPhone's Library and Reading tabs, for comparing by eye. */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(qualifiers = "w402dp-h874dp-xxhdpi")
class LibraryComponentsScreenshotTest {
    private val books = listOf(
        Triple("a1", "This Is How You Lose the Time War", "Amal El-Mohtar"),
        Triple("j2", "Peter and Wendy", "J. M. Barrie"),
        Triple("m3", "Frankenstein; or, the Modern Prometheus", "Mary Shelley"),
        Triple("s4", "The Ballad of Songbirds and Snakes", "Suzanne Collins"),
        Triple("j5", "Pride and Prejudice", "Jane Austen"),
    )

    @Test
    fun library() {
        captureRoboImage("build/specimen/library.png") {
            IssaTheme(darkTheme = false) {
                Column(Modifier.size(402.dp, 874.dp).background(Palette.paper), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("Library", style = SystemText.largeTitle, color = Palette.ink, modifier = Modifier.padding(start = 16.dp, top = 56.dp))
                    LibrarySearchField("", {}, Modifier.padding(horizontal = 16.dp))
                    LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        item { ShelfChip("Browse", null, true, {}) }
                        item { ShelfChip("All books", 6, false, {}) }
                        item { ShelfChip("Reading", 3, false, {}) }
                        item { ShelfChip("To read", 2, false, {}) }
                        item { ShelfChip("Finished", 1, false, {}) }
                    }
                    CoverRail("Recently added", books, key = { it.first }, onSeeAll = {}) { (uuid, title, author) ->
                        RailBook({ CoverArt(null, uuid, author) }, title, 74.dp)
                    }
                    RailHeader("Series", onSeeAll = {})
                    SeriesTile({ CoverArt(null, "s4", "Suzanne Collins") }, { CoverArt(null, "x", "B") }, "Gothic Horror", 2, {}, Modifier.padding(start = 16.dp))
                    Row(Modifier.padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                        for ((uuid, title, author) in books.take(3)) {
                            BookCell({ CoverArt(null, uuid, author) }, title, author, Modifier.width(112.dp), progress = 0.4, formatMark = FormatMark.READALONG, seriesOrdinal = "2")
                        }
                    }
                }
            }
        }
    }

    @Test
    fun reading() {
        captureRoboImage("build/specimen/reading.png") {
            IssaTheme(darkTheme = false) {
                Column(Modifier.size(402.dp, 874.dp).background(Palette.paper).padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("Reading", style = SystemText.largeTitle, color = Palette.ink, modifier = Modifier.padding(top = 56.dp))
                    ContinueCard({ CoverArt(null, "j2", "J. M. Barrie") }, "Peter and Wendy", "J. M. Barrie", 0.51, {}, {})
                    Overline("Also reading", Modifier.padding(top = 12.dp))
                    ResumeRow({ CoverArt(null, "m3", "Mary Shelley") }, "Frankenstein; or, the Modern Prometheus", 0.04, {})
                    ResumeRow({ CoverArt(null, "j5", "Jane Austen") }, "Pride and Prejudice", 0.33, {})
                    PalettePlaceholder(Symbols.bookmark, "Nothing in progress", "Books you start appear here.", actionTitle = "Go to Library", action = {}, modifier = Modifier.fillMaxSize())
                }
            }
        }
    }
}
