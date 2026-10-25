package com.benjaminissa.issareader.core.sync

import com.benjaminissa.issareader.core.model.Book

/**
 * How many books sit on each shelf, counted once.
 *
 * The library's shelf chips each carry a number, and computing those the
 * obvious way — asking the arranged books per chip — is ruinous: arranging
 * builds a `BookContentService` on every access, and the downloaded shelf
 * then asks the filesystem once per book *per format*. Six chips reading
 * their counts in a composition is thousands of syscalls per scrolled frame.
 *
 * So: one pass, no filesystem, no network. The on-disk answer is injected as a
 * set gathered from a single directory read.
 */
class LibraryFacets(books: List<Book>, downloadedUuids: Set<String>) {
    /**
     * The whole library, not the filtered view. "142 books" means the library;
     * each shelf's own number is on its chip.
     */
    val total: Int = books.size
    val shelfCounts: Map<LibraryArrangement.Shelf, Int>

    /**
     * Sorted by count descending, then name — the same order the tag menu
     * already used.
     */
    val tagCounts: List<TagCount>

    data class TagCount(val name: String, val count: Int)

    init {
        val shelves = mutableMapOf(LibraryArrangement.Shelf.ALL to books.size)
        val tags = mutableMapOf<String, Int>()

        for (book in books) {
            // Once per book, not once per shelf: the three stage filters each
            // called this separately.
            when (LibraryArrangement.stage(book)) {
                LibraryArrangement.Stage.READING -> shelves.increment(LibraryArrangement.Shelf.READING)
                LibraryArrangement.Stage.TO_READ -> shelves.increment(LibraryArrangement.Shelf.TO_READ)
                LibraryArrangement.Stage.FINISHED -> shelves.increment(LibraryArrangement.Shelf.FINISHED)
            }
            // The same predicate the shelf filter uses, so a chip's number can
            // never disagree with the grid beneath it.
            if (book.hasServableAudio) shelves.increment(LibraryArrangement.Shelf.WITH_NARRATION)
            if (book.uuid in downloadedUuids) shelves.increment(LibraryArrangement.Shelf.DOWNLOADED)
            // Once per book: the tag filter keeps a book or does not, so a row
            // that names a tag twice counted two books the grid shows as one.
            for (tag in book.tags.map { it.name }.toSet()) tags.increment(tag)
        }

        shelfCounts = shelves
        tagCounts = tags
            .map { TagCount(it.key, it.value) }
            .sortedWith(compareByDescending<TagCount> { it.count }.thenBy { it.name })
    }

    fun count(shelf: LibraryArrangement.Shelf): Int = shelfCounts[shelf] ?: 0

    override fun equals(other: Any?): Boolean =
        other is LibraryFacets && other.total == total && other.shelfCounts == shelfCounts && other.tagCounts == tagCounts

    override fun hashCode(): Int = (total * 31 + shelfCounts.hashCode()) * 31 + tagCounts.hashCode()

    companion object {
        val empty = LibraryFacets(emptyList(), emptySet())

        private fun <K> MutableMap<K, Int>.increment(key: K) {
            this[key] = (this[key] ?: 0) + 1
        }
    }
}
