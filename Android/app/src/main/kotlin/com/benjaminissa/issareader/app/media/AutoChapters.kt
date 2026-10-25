package com.benjaminissa.issareader.app.media

import com.benjaminissa.issareader.epub.EpubPackage

/**
 * Chapter titles and jump targets for Android Auto's queue, derived from an
 * EPUB's own navigation document: Swift's `CarPlayChapters`.
 *
 * Used while a read-along narrates from the reader, whose coordinator has no
 * chapter list of its own — only the document the current sentence lives in.
 * A separate, small derivation from the Contents sheet's rather than a shared
 * one, as on iOS: duplicating a dozen lines costs less than reaching into a
 * screen for a car-only need.
 */
object AutoChapters {
    data class Entry(
        val spineIndex: Int,
        val fragment: String?,
        val title: String,
    )

    /**
     * One row per nav point, matched back to its spine item — not one row per
     * spine item — because a book that packs many chapters into a few large
     * files (Gutenberg's do) distinguishes them only by fragment, and rows per
     * file would collapse a seventeen-chapter book to four that all open on
     * page one.
     */
    fun entries(epubPackage: EpubPackage): List<Entry> {
        val result = mutableListOf<Entry>()
        for (point in epubPackage.navigation) {
            val index = epubPackage.spine.indexOfFirst { it.href == point.href }
            if (index < 0) continue
            result += Entry(
                spineIndex = index,
                fragment = point.fragment,
                title = point.title.ifEmpty { "Chapter ${result.size + 1}" },
            )
        }
        // A book with no usable navigation still needs a way to move around.
        if (result.isEmpty()) {
            return epubPackage.spine.indices.map { Entry(spineIndex = it, fragment = null, title = "Section ${it + 1}") }
        }
        return result
    }

    /**
     * The row being read: the last entry in the reader's spine item that
     * starts at or before the page.
     *
     * By offset, the way `ReaderModel.title(inSpineItem, atOffset)` names the
     * chapter on screen, not by spine index alone. The rows are one per nav
     * point, and a book that packs several chapters into one file
     * distinguishes them only by fragment, so matching the spine index put the
     * "now playing" mark on the file's first chapter whichever of them was
     * being narrated.
     *
     * @param offset where the page starts in the spine item's text.
     * @param location where a fragment starts in the laid-out spine item, or
     *   null when it is not laid out or not found. An entry with no fragment
     *   starts at the top of its file.
     */
    fun currentIndex(entries: List<Entry>, spineIndex: Int, offset: Int, location: (String) -> Int?): Int? {
        var best: Pair<Int, Int>? = null
        var first: Int? = null
        for ((index, entry) in entries.withIndex()) {
            if (entry.spineIndex != spineIndex) continue
            if (first == null) first = index
            val start = if (entry.fragment != null) location(entry.fragment) else 0
            if (start == null || start > offset) continue
            // `>=`, so of two entries at one place the later wins, as it does
            // in the reader's own title.
            if (start >= (best?.second ?: -1)) best = index to start
        }
        return best?.first ?: first
    }
}
