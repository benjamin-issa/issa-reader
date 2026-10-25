package com.benjaminissa.issareader.app.ui.library

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.benjaminissa.issareader.app.model.AppModel
import com.benjaminissa.issareader.app.ui.shell.appModel
import com.benjaminissa.issareader.core.sync.LibraryArrangement
import com.benjaminissa.issareader.ui.LibrarySearchField
import com.benjaminissa.issareader.ui.Metrics
import com.benjaminissa.issareader.ui.Palette
import com.benjaminissa.issareader.ui.ShelfChip
import com.benjaminissa.issareader.ui.SortCapsule
import com.benjaminissa.issareader.ui.Symbols
import com.benjaminissa.issareader.ui.SystemText
import com.benjaminissa.issareader.ui.Typography

/**
 * The library's navigation, made visible: the search capsule, the Browse and
 * shelf chips with the tags menu, and — over a grid or search results — the
 * count and the sort. Swift's `LibraryHeader`.
 *
 * Outside the scrolling content, so it never scrolls away, and its height
 * never depends on anything that loads: counts change the width of a label,
 * never the height of a row, and the chip row renders even when the library
 * is empty.
 *
 * @param displayedCount how many books are on screen: "6 books" above a grid
 *   of three reads as a bug in the library.
 */
@Composable
fun LibraryHeader(search: String, onSearchChange: (String) -> Unit, displayedCount: Int, isSearching: Boolean) {
    val app = appModel
    Column(
        Modifier
            .fillMaxWidth()
            .background(Palette.paper)
            .padding(top = Metrics.spacing8, bottom = Metrics.spacing12),
        verticalArrangement = Arrangement.spacedBy(Metrics.spacing12),
    ) {
        LibrarySearchField(search, onSearchChange, Modifier.padding(horizontal = Metrics.screenMargin).testTag("field.librarySearch"))
        ShelfChips(app)
        // A count and a sort describe a grid. Browse has rails, and search
        // results are already an answer — but the number of them is worth a
        // line. Mode and search are the reader's doing, never something that
        // loads.
        if (app.libraryMode == AppModel.LibraryMode.ALL || isSearching) {
            CountAndSort(app, displayedCount, isSearching, Modifier.padding(horizontal = Metrics.screenMargin))
        }
    }
}

/**
 * Browse first, then the shelves. Browse is the rails; a shelf is the flat
 * grid cut that way, so tapping one leaves Browse. The tags a reader picked
 * travel with them from shelf to shelf. Padded inside, so the chips scroll to
 * the screen's edges.
 */
@Composable
private fun ShelfChips(app: AppModel) {
    Row(
        Modifier
            .fillMaxWidth()
            .testTag("chips.shelf")
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = Metrics.screenMargin),
        horizontalArrangement = Arrangement.spacedBy(Metrics.spacing8),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        ShelfChip("Browse", count = null, isSelected = app.libraryMode == AppModel.LibraryMode.BROWSE, onClick = { app.libraryMode = AppModel.LibraryMode.BROWSE })
        for (shelf in LibraryArrangement.Shelf.entries) {
            val count = app.facets.count(shelf)
            ShelfChip(
                title = shelf.title,
                count = count,
                isSelected = app.libraryMode == AppModel.LibraryMode.ALL && app.arrangement.shelf == shelf,
                onClick = { app.showAllBooks(shelf = shelf, tags = app.arrangement.tags) },
                modifier = Modifier.semantics { contentDescription = "${shelf.title}, $count book${if (count == 1) "" else "s"}" },
            )
        }
        TagsChip(app)
    }
}

/**
 * Tags overflow into a menu: a library's tag list runs long, and a chip each
 * would push every shelf off the row. A tag is a cut through the grid, so
 * picking one opens the grid — Browse has its own tag rails.
 */
@Composable
private fun TagsChip(app: AppModel) {
    var open by remember { mutableStateOf(false) }
    val selected = app.arrangement.tags
    Box {
        ShelfChip(
            title = if (selected.isEmpty()) "Tags" else "Tags · ${selected.size}",
            count = null,
            isSelected = selected.isNotEmpty(),
            onClick = { open = true },
            showsChevron = true,
            modifier = Modifier.semantics { contentDescription = tagFilterLabel(selected.size) },
        )
        DropdownMenu(expanded = open, onDismissRequest = { open = false }, containerColor = Palette.surface, shape = RoundedCornerShape(Metrics.radiusLarge)) {
            if (selected.isNotEmpty()) {
                DropdownMenuItem(
                    text = { Text("Clear tags", style = SystemText.body, color = Palette.ink) },
                    onClick = {
                        open = false
                        app.arrangement = app.arrangement.copy(tags = emptySet())
                    },
                )
                HorizontalDivider(thickness = 0.5.dp, color = Palette.border)
            }
            for (tag in app.facets.tagCounts.take(12)) {
                val isOn = tag.name in app.arrangement.tags
                DropdownMenuItem(
                    text = { Text("${tag.name} (${tag.count})", style = SystemText.body, color = Palette.ink) },
                    trailingIcon = if (isOn) {
                        { Icon(painterResource(Symbols.checkmark), contentDescription = "Selected", tint = Palette.tangerine) }
                    } else {
                        null
                    },
                    onClick = {
                        open = false
                        val tags = app.arrangement.tags.toMutableSet()
                        if (!tags.remove(tag.name)) tags.add(tag.name)
                        app.showAllBooks(shelf = app.arrangement.shelf, tags = tags)
                    },
                )
            }
        }
    }
}

/** What the tag filter is called aloud: "1 tag selected", not "1 tags selected". */
fun tagFilterLabel(selectedCount: Int): String = when (selectedCount) {
    0 -> "Filter by tag"
    1 -> "1 tag selected"
    else -> "$selectedCount tags selected"
}

/**
 * The line over a grid: how many books are on screen, and the sort as a
 * control. Against the shelf's own total when tags narrow it ("3 of 6
 * books"), so the line and the highlighted chip describe the same set.
 */
fun countText(displayedCount: Int, isSearching: Boolean, tagCount: Int, shelfTotal: Int): String {
    if (isSearching) return "$displayedCount result${if (displayedCount == 1) "" else "s"}"
    if (tagCount > 0) return "$displayedCount of $shelfTotal book${if (shelfTotal == 1) "" else "s"}"
    return "$displayedCount book${if (displayedCount == 1) "" else "s"}"
}

@Composable
private fun CountAndSort(app: AppModel, displayedCount: Int, isSearching: Boolean, modifier: Modifier = Modifier) {
    Row(modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(
            countText(displayedCount, isSearching, app.arrangement.tags.size, app.facets.count(app.arrangement.shelf)),
            style = Typography.caption.copy(fontFeatureSettings = "tnum"),
            color = Palette.inkTertiary,
            maxLines = 1,
        )
        Spacer(Modifier.weight(1f))
        SortMenu(app)
    }
}

/**
 * The sort as a control rather than a caption: the capsule with the current
 * sort's name, opening Material's menu with every sort, the current one
 * checked, and "Reverse order".
 */
@Composable
private fun SortMenu(app: AppModel) {
    var open by remember { mutableStateOf(false) }
    val arrangement = app.arrangement
    Box {
        SortCapsule(
            arrangement.sort.title,
            onClick = { open = true },
            modifier = Modifier.semantics { contentDescription = "Sort by ${arrangement.sort.title}" },
        )
        DropdownMenu(expanded = open, onDismissRequest = { open = false }, containerColor = Palette.surface, shape = RoundedCornerShape(Metrics.radiusLarge)) {
            for (sort in LibraryArrangement.Sort.entries) {
                DropdownMenuItem(
                    text = { Text(sort.title, style = SystemText.body, color = Palette.ink) },
                    trailingIcon = if (sort == arrangement.sort) {
                        { Icon(painterResource(Symbols.checkmark), contentDescription = "Selected", tint = Palette.tangerine) }
                    } else {
                        null
                    },
                    onClick = {
                        open = false
                        app.arrangement = app.arrangement.copy(sort = sort)
                    },
                )
            }
            HorizontalDivider(thickness = 0.5.dp, color = Palette.border)
            DropdownMenuItem(
                text = { Text("Reverse order", style = SystemText.body, color = Palette.ink) },
                trailingIcon = if (arrangement.ascending) {
                    { Icon(painterResource(Symbols.checkmark), contentDescription = "On", tint = Palette.tangerine) }
                } else {
                    null
                },
                onClick = {
                    open = false
                    app.arrangement = app.arrangement.copy(ascending = !app.arrangement.ascending)
                },
            )
        }
    }
}
