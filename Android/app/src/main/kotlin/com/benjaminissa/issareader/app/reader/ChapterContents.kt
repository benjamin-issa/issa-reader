package com.benjaminissa.issareader.app.reader

import com.benjaminissa.issareader.epub.EpubPackage

/**
 * The table of contents: built once, from the package, rather than per
 * rendered row. Swift's `ChapterListView.build`, here so the contents screen
 * only draws it.
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

        // href → first spine index, built once: a search per nav point made
        // this quadratic, and books that pack many chapters into a few files
        // have the most nav points of all.
        val spineIndexByHref = HashMap<String, Int>(epubPackage.spine.size)
        for ((index, item) in epubPackage.spine.withIndex()) spineIndexByHref.putIfAbsent(item.href, index)

        // One row per nav point, not per spine item. Books that pack many
        // chapters into a few large files distinguish them only by fragment.
        val result = ArrayList<Entry>()
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
}
