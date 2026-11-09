package com.benjaminissa.issareader.app.ui.reader

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.benjaminissa.issareader.app.reader.ReaderModel
import com.benjaminissa.issareader.epub.EpubPackage
import com.benjaminissa.issareader.ui.Metrics
import com.benjaminissa.issareader.ui.Palette
import com.benjaminissa.issareader.ui.Symbols
import com.benjaminissa.issareader.ui.Typography

/**
 * The table of contents' rows: built from the EPUB's own navigation document,
 * falling back to the NCX for older books. Entries whose target is not in the
 * spine are dropped rather than shown as dead rows.
 */
object ChapterContents {
    data class Entry(
        val spineIndex: Int,
        val fragment: String?,
        val title: String,
        val depth: Int,
        val id: Int,
    )

    /** @param epubPackage the open book, or null before it opens. */
    fun build(epubPackage: EpubPackage?): List<Entry> {
        epubPackage ?: return emptyList()
        // href → first spine index, built once. A search per nav point made
        // this quadratic, and books that pack many chapters into a few files
        // have the most nav points of all.
        val spineIndexByHref = HashMap<String, Int>(epubPackage.spine.size)
        for ((index, item) in epubPackage.spine.withIndex()) spineIndexByHref.putIfAbsent(item.href, index)

        val result = ArrayList<Entry>()
        // One row per nav point, not per spine item. Books that pack many
        // chapters into a few large files distinguish them only by fragment,
        // so deduping by spine index collapses a seventeen-chapter book to
        // four rows that all open on page one.
        for (point in epubPackage.navigation) {
            val index = spineIndexByHref[point.href] ?: continue
            result.add(
                Entry(
                    spineIndex = index,
                    fragment = point.fragment,
                    title = point.title.ifEmpty { "Chapter ${result.size + 1}" },
                    depth = point.depth,
                    id = result.size,
                ),
            )
        }
        // A book with no usable navigation still needs a way to move around.
        if (result.isEmpty()) {
            return epubPackage.spine.indices.map { Entry(it, null, "Section ${it + 1}", 0, it) }
        }
        return result
    }

    /**
     * Which row to mark. With several rows per spine item, the marker belongs
     * on the one the reader is actually inside, not on every row for the file.
     * Resolved once per list, never once per row.
     */
    fun currentId(entries: List<Entry>, chapterIndex: Int, visibleFragments: () -> Set<String>): Int? {
        val siblings = entries.filter { it.spineIndex == chapterIndex }
        if (siblings.size <= 1) return siblings.firstOrNull()?.id
        val visible = visibleFragments()
        return siblings.lastOrNull { row -> row.fragment?.let { it in visible } ?: false }?.id ?: siblings.first().id
    }
}

/**
 * The table of contents, with where you are in it: the Contents sheet.
 *
 * @param onSelect a row's spine index and fragment; the sheet closes after.
 */
@Composable
fun ChapterListView(model: ReaderModel, onSelect: (Int, String?) -> Unit, onDismiss: () -> Unit) {
    // Built once per book and spine rather than per row: opening the contents
    // of a book with 400 nav points used to rebuild a 400-entry list 800 times.
    // Keyed on the spine as well, so contents opened while the book is still
    // being read off disk fill in when it arrives.
    val epubPackage = model.epubPackage
    val entries = remember(model.book.uuid, epubPackage?.spine?.size ?: 0) { ChapterContents.build(epubPackage) }
    val current = ChapterContents.currentId(entries, model.chapterIndex) { model.visibleFragments() }
    Column(Modifier.fillMaxWidth()) {
        SheetLargeTitle("Contents")
        LazyColumn(contentPadding = PaddingValues(start = Metrics.screenMargin, end = Metrics.screenMargin, bottom = Metrics.spacing32)) {
            itemsIndexed(entries, key = { _, entry -> entry.id }) { index, entry ->
                val isCurrent = entry.id == current
                val indent = (entry.depth * 16).dp
                Column(
                    Modifier
                        .groupedRow(index, entries.size)
                        .clickable(role = Role.Button) {
                            onSelect(entry.spineIndex, entry.fragment)
                            onDismiss()
                        }
                        .semantics { selected = isCurrent },
                ) {
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .heightIn(min = 50.dp)
                            .padding(start = 16.dp + indent, end = 16.dp, top = 10.dp, bottom = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(Metrics.spacing8),
                    ) {
                        Text(
                            entry.title,
                            style = if (entry.depth == 0) Typography.callout else Typography.footnote,
                            color = if (isCurrent) Palette.tangerine else Palette.ink,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f),
                        )
                        if (isCurrent) {
                            Icon(painterResource(Symbols.bookFill), contentDescription = null, tint = Palette.tangerine, modifier = Modifier.size(15.dp))
                        } else {
                            Spacer(Modifier.size(15.dp))
                        }
                    }
                    if (index < entries.size - 1) {
                        // Inset to the row's own text, as a grouped list's
                        // separator is.
                        GroupedRowDivider(start = 16.dp + indent)
                    }
                }
            }
        }
    }
}
