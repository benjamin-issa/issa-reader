package com.benjaminissa.issareader.app.media

import android.net.Uri
import android.os.Bundle
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.MediaConstants
import androidx.media3.session.MediaLibraryService.LibraryParams
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.sync.CarCatalogue
import com.benjaminissa.issareader.playback.android.SessionMediaIds

/**
 * What Android Auto's browse tree holds: the CarPlay scene's templates, as
 * media items.
 *
 * Android Auto draws a media app's root children as tabs and their children
 * as lists, so the shape is CarPlay's: **Recent**, **Library** and
 * **Downloaded**, each a list of playable books — the same contents, order,
 * limits and empty messages, because they come from the same
 * [CarCatalogue]. A row says the title, "author · Xh Ym left", how far through
 * it is and whether it will play without a signal, with the square cover.
 *
 * Only the server's books are ever here. A book from the reader's own files
 * is the device's, not the account's, and never reaches the car.
 */
@OptIn(UnstableApi::class)
object AutoBrowseTree {
    const val ROOT = "root"
    private const val SHELF = "shelf/"
    private const val EMPTY = "empty/"

    /**
     * The most rows a shelf offers. CarPlay passed its head unit's
     * `CPListTemplate.maximumItemCount`; Android Auto states no such limit
     * for a list — it pages, and limits a list itself while the car moves —
     * so this is the edge that knows, set where a driver could still find a
     * book by scrolling.
     */
    const val ITEM_LIMIT = 100

    /** Android Auto's key in a browse request's hints: how many tabs it will draw. */
    const val ROOT_CHILDREN_LIMIT = MediaConstants.EXTRAS_KEY_ROOT_CHILDREN_LIMIT

    /** The legacy browser key that says search is supported, which voice search needs. */
    const val SEARCH_SUPPORTED = "android.media.browse.SEARCH_SUPPORTED"

    /** The legacy browser key that says the content-style hints are honoured. */
    private const val CONTENT_STYLE_SUPPORTED = "android.media.browse.CONTENT_STYLE_SUPPORTED"

    /**
     * The car's catalogue: the server's books and the downloaded set, never a
     * book from the reader's own files — by its local copy, or by the local
     * library's own list, whichever says so.
     */
    fun catalogue(books: List<Book>, downloadedUuids: Set<String>, localUuids: Set<String> = emptySet()): CarCatalogue =
        CarCatalogue(books.filter { it.localCopy == null && it.uuid !in localUuids }, downloadedUuids)

    fun shelfId(shelf: CarCatalogue.Shelf): String = SHELF + shelf.rawValue

    fun shelf(mediaId: String): CarCatalogue.Shelf? =
        mediaId.takeIf { it.startsWith(SHELF) }?.removePrefix(SHELF)?.let { raw -> CarCatalogue.Shelf.entries.firstOrNull { it.rawValue == raw } }

    /** Whether [mediaId] is a shelf's empty message, which plays nothing. */
    fun isEmptyMessage(mediaId: String): Boolean = mediaId.startsWith(EMPTY)

    /** The root: browsable, never playable. */
    fun root(): MediaItem = MediaItem.Builder()
        .setMediaId(ROOT)
        .setMediaMetadata(
            MediaMetadata.Builder()
                .setTitle("Issa Reader")
                .setIsBrowsable(true)
                .setIsPlayable(false)
                .setMediaType(MediaMetadata.MEDIA_TYPE_FOLDER_MIXED)
                .build(),
        )
        .build()

    /**
     * The root's hints: books as list rows, tabs as tabs, and search
     * supported — the switch voice search ("play Dracula on Issa Reader")
     * needs, which CarPlay never had.
     */
    fun rootParams(): LibraryParams = LibraryParams.Builder()
        .setExtras(
            Bundle().apply {
                putBoolean(SEARCH_SUPPORTED, true)
                putBoolean(CONTENT_STYLE_SUPPORTED, true)
                putInt(MediaConstants.EXTRAS_KEY_CONTENT_STYLE_BROWSABLE, MediaConstants.EXTRAS_VALUE_CONTENT_STYLE_LIST_ITEM)
                putInt(MediaConstants.EXTRAS_KEY_CONTENT_STYLE_PLAYABLE, MediaConstants.EXTRAS_VALUE_CONTENT_STYLE_LIST_ITEM)
            },
        )
        .build()

    /**
     * A shelf, as a tab.
     *
     * @param icon the tab's glyph: CarPlay's SF Symbol (`clock`,
     *   `books.vertical`, `arrow.down.circle`) as a monochrome vector.
     */
    fun tab(shelf: CarCatalogue.Shelf, icon: Uri?): MediaItem = MediaItem.Builder()
        .setMediaId(shelfId(shelf))
        .setMediaMetadata(
            MediaMetadata.Builder()
                .setTitle(shelf.title)
                .setDisplayTitle(shelf.title)
                .setArtworkUri(icon)
                .setIsBrowsable(true)
                .setIsPlayable(false)
                .setMediaType(MediaMetadata.MEDIA_TYPE_FOLDER_AUDIO_BOOKS)
                .build(),
        )
        .build()

    /**
     * The items that may legally be tabs, at most [limit] of them: Swift's
     * `CarPlaySceneDelegate.tabs(from:limit:)`.
     *
     * Stated as an allow-list, as there: a browsable folder and nothing else.
     * Android Auto asks for its root's children to be browsable only, as
     * CarPlay's tab bar admitted lists and grids only — and threw over Now
     * Playing — so a playable item, or one that is neither, is not admitted
     * on the strength of not being recognised. [limit] is the car's
     * [ROOT_CHILDREN_LIMIT], clamped to rather than trusted to be met.
     */
    fun tabs(candidates: List<MediaItem>, limit: Int): List<MediaItem> {
        if (limit <= 0) return emptyList()
        return candidates
            .filter { it.mediaMetadata.isBrowsable == true && it.mediaMetadata.isPlayable != true }
            .take(limit)
    }

    /**
     * One shelf's rows, in the order the car should draw them, or the
     * shelf's empty message: a blank list in a car is indistinguishable from
     * an app that has crashed.
     *
     * @param artwork the cover's address for a book, or null for none yet.
     */
    fun items(
        catalogue: CarCatalogue,
        shelf: CarCatalogue.Shelf,
        limit: Int = ITEM_LIMIT,
        artwork: (String) -> Uri? = { null },
    ): List<MediaItem> {
        val entries = catalogue.entries(shelf, limit)
        if (entries.isEmpty()) return listOf(emptyMessage(shelf))
        val byUuid = catalogue.books.associateBy { it.uuid }
        return entries.map { bookItem(it, byUuid[it.bookUuid], artwork(it.bookUuid)) }
    }

    /** A playable book row. */
    fun bookItem(entry: CarCatalogue.Entry, book: Book?, artwork: Uri?): MediaItem = MediaItem.Builder()
        .setMediaId(SessionMediaIds.book(entry.bookUuid))
        .setMediaMetadata(
            MediaMetadata.Builder()
                .setTitle(entry.title)
                .setDisplayTitle(entry.title)
                .setSubtitle(entry.subtitle)
                .setArtist(book?.byline?.takeIf { it.isNotEmpty() })
                .setArtworkUri(artwork)
                .setIsBrowsable(false)
                .setIsPlayable(true)
                .setMediaType(MediaMetadata.MEDIA_TYPE_AUDIO_BOOK)
                .setExtras(rowExtras(entry))
                .build(),
        )
        .build()

    /** A shelf with nothing on it says so, in a row that plays nothing. */
    fun emptyMessage(shelf: CarCatalogue.Shelf): MediaItem = MediaItem.Builder()
        .setMediaId(EMPTY + shelf.rawValue)
        .setMediaMetadata(
            MediaMetadata.Builder()
                .setTitle(shelf.emptyMessage)
                .setDisplayTitle(shelf.emptyMessage)
                .setIsBrowsable(false)
                .setIsPlayable(false)
                .build(),
        )
        .build()

    /**
     * How far through, as the car's progress bar on a row (CarPlay's
     * `playbackProgress`), and whether it will play with no signal.
     */
    fun rowExtras(entry: CarCatalogue.Entry): Bundle = Bundle().apply {
        val progress = entry.progress?.takeIf { it.isFinite() }?.coerceIn(0.0, 1.0)
        when {
            progress == null || progress <= 0.0 ->
                putInt(MediaConstants.EXTRAS_KEY_COMPLETION_STATUS, MediaConstants.EXTRAS_VALUE_COMPLETION_STATUS_NOT_PLAYED)
            progress >= FINISHED ->
                putInt(MediaConstants.EXTRAS_KEY_COMPLETION_STATUS, MediaConstants.EXTRAS_VALUE_COMPLETION_STATUS_FULLY_PLAYED)
            else -> {
                putInt(MediaConstants.EXTRAS_KEY_COMPLETION_STATUS, MediaConstants.EXTRAS_VALUE_COMPLETION_STATUS_PARTIALLY_PLAYED)
                putDouble(MediaConstants.EXTRAS_KEY_COMPLETION_PERCENTAGE, progress)
            }
        }
        putLong(
            MediaConstants.EXTRAS_KEY_DOWNLOAD_STATUS,
            if (entry.isDownloaded) MediaConstants.EXTRAS_VALUE_STATUS_DOWNLOADED else MediaConstants.EXTRAS_VALUE_STATUS_NOT_DOWNLOADED,
        )
    }

    /** Where a book counts as finished, for the car's "played" mark. */
    private const val FINISHED = 0.999

    /** One page of [items]: Media3's paging, without overflowing on a page size of everything. */
    fun page(items: List<MediaItem>, page: Int, pageSize: Int): List<MediaItem> {
        if (page < 0 || pageSize <= 0) return emptyList()
        val start = page.toLong() * pageSize.toLong()
        if (start >= items.size) return emptyList()
        val end = minOf(items.size.toLong(), start + pageSize.toLong())
        return items.subList(start.toInt(), end.toInt())
    }
}
