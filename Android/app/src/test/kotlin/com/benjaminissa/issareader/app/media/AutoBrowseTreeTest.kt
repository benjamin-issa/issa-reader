package com.benjaminissa.issareader.app.media

import android.net.Uri
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.session.MediaConstants
import com.benjaminissa.issareader.core.sync.CarCatalogue
import com.benjaminissa.issareader.playback.android.SessionMediaIds
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * What may be a tab, and how many — ported from `CarPlayRootTemplateTests` —
 * and what each tab holds.
 *
 * The Swift suite exists because of a crash: build 24 put
 * `CPNowPlayingTemplate.shared` in the root tab bar and
 * `-[CPTabBarTemplate validateTemplates:]` threw over it, five identical
 * `SIGABRT`s, one per time the car connected. Android Auto does not throw, but
 * it asks the same of its root — browsable folders only, no more than it
 * draws — and a root that breaks that is a car screen that breaks. So
 * `AutoBrowseTree.tabs(candidates, limit)` keeps Swift's allow-list and its
 * clamp, and these keep its tests.
 */
@RunWith(RobolectricTestRunner::class)
class AutoBrowseTreeTest {
    private fun list(title: String): MediaItem = MediaItem.Builder()
        .setMediaId("shelf/$title")
        .setMediaMetadata(MediaMetadata.Builder().setTitle(title).setIsBrowsable(true).setIsPlayable(false).build())
        .build()

    private val nowPlaying: MediaItem = MediaItem.Builder()
        .setMediaId("now-playing")
        .setMediaMetadata(MediaMetadata.Builder().setTitle("Now Playing").setIsBrowsable(false).setIsPlayable(true).build())
        .build()

    // CarPlayRootTemplateTests

    /** List templates are tabs. */
    @Test
    fun listsAreKept() {
        val templates = listOf(list("Recent"), list("Library"), list("Downloaded"))
        val chosen = AutoBrowseTree.tabs(templates, limit = 5)
        assertEquals(3, chosen.size)
        chosen.zip(templates).forEach { (a, b) -> assertSame(b, a) }
    }

    /** The regression itself: a playable item is not a tab, as Now Playing was not. */
    @Test
    fun nowPlayingIsExcluded() {
        val chosen = AutoBrowseTree.tabs(listOf(list("Recent"), nowPlaying), limit = 5)
        assertEquals(1, chosen.size)
        assertFalse(chosen.any { it === nowPlaying })
    }

    /** No more tabs than the car allows: its root-children limit, which varies by car. */
    @Test
    fun clampsToTheLimit() {
        for (limit in listOf(1, 2, 3)) {
            val chosen = AutoBrowseTree.tabs(listOf(list("a"), list("b"), list("c"), list("d")), limit)
            assertEquals("$limit", limit, chosen.size)
        }
    }

    /** A limit of nothing yields nothing rather than a tab bar of nothing; the service then offers one list. */
    @Test
    fun zeroLimit() {
        assertTrue(AutoBrowseTree.tabs(listOf(list("a")), limit = 0).isEmpty())
    }

    /** An allow-list: an item that is neither a folder nor playable is not admitted for not being Now Playing. */
    @Test
    fun unknownTypesAreRefused() {
        val message = AutoBrowseTree.emptyMessage(CarCatalogue.Shelf.RECENT)
        val chosen = AutoBrowseTree.tabs(listOf(list("a"), message), limit = 5)
        assertEquals(1, chosen.size)
        assertEquals("shelf/a", chosen.single().mediaId)
    }

    // The tree

    /** The three shelves as tabs, with their titles: CarPlay's, in CarPlay's order. */
    @Test
    fun theTabsAreCarPlays() {
        val tabs = CarCatalogue.Shelf.entries.map { AutoBrowseTree.tab(it, null) }
        assertEquals(listOf("Recent", "Library", "Downloaded"), tabs.map { it.mediaMetadata.title.toString() })
        assertTrue(tabs.all { it.mediaMetadata.isBrowsable == true && it.mediaMetadata.isPlayable == false })
        assertEquals(tabs, AutoBrowseTree.tabs(tabs, limit = 4))
        assertEquals(CarCatalogue.Shelf.DOWNLOADED, AutoBrowseTree.shelf(tabs[2].mediaId))
    }

    /** The root says search is supported, which voice search needs, and that rows are list rows. */
    @Test
    fun theRootSupportsSearch() {
        val extras = AutoBrowseTree.rootParams().extras
        assertTrue(extras.getBoolean(AutoBrowseTree.SEARCH_SUPPORTED))
        assertEquals(MediaConstants.EXTRAS_VALUE_CONTENT_STYLE_LIST_ITEM, extras.getInt(MediaConstants.EXTRAS_KEY_CONTENT_STYLE_PLAYABLE))
        assertEquals(MediaConstants.EXTRAS_VALUE_CONTENT_STYLE_LIST_ITEM, extras.getInt(MediaConstants.EXTRAS_KEY_CONTENT_STYLE_BROWSABLE))
        val root = AutoBrowseTree.root()
        assertEquals(true, root.mediaMetadata.isBrowsable)
        assertEquals(false, root.mediaMetadata.isPlayable)
    }

    /** A row: the title, "author · Xh Ym left", how far through, whether it is on the phone, and its cover. */
    @Test
    fun aRowSaysWhatCarPlaySaid() {
        val catalogue = AutoBrowseTree.catalogue(
            listOf(book("Dracula", author = "Bram Stoker", progress = 0.5, positionTimestamp = 10.0, audioDuration = 7200.0)),
            downloadedUuids = setOf("dracula"),
        )
        val cover = Uri.parse("content://com.benjaminissa.issareader.covers/key")
        val row = AutoBrowseTree.items(catalogue, CarCatalogue.Shelf.RECENT) { cover }.single()
        assertEquals(SessionMediaIds.book("dracula"), row.mediaId)
        assertEquals("Dracula", row.mediaMetadata.title.toString())
        assertEquals("Bram Stoker · 1h 0m left", row.mediaMetadata.subtitle.toString())
        assertEquals(cover, row.mediaMetadata.artworkUri)
        assertEquals(true, row.mediaMetadata.isPlayable)
        assertEquals(false, row.mediaMetadata.isBrowsable)
        val extras = checkNotNull(row.mediaMetadata.extras)
        assertEquals(MediaConstants.EXTRAS_VALUE_COMPLETION_STATUS_PARTIALLY_PLAYED, extras.getInt(MediaConstants.EXTRAS_KEY_COMPLETION_STATUS))
        assertEquals(0.5, extras.getDouble(MediaConstants.EXTRAS_KEY_COMPLETION_PERCENTAGE), 0.0)
        assertEquals(MediaConstants.EXTRAS_VALUE_STATUS_DOWNLOADED, extras.getLong(MediaConstants.EXTRAS_KEY_DOWNLOAD_STATUS))
    }

    /** Not started, and finished, read as such. */
    @Test
    fun completion() {
        val catalogue = AutoBrowseTree.catalogue(listOf(book("Fresh"), book("Done", progress = 1.0, positionTimestamp = 1.0)), emptySet())
        val rows = AutoBrowseTree.items(catalogue, CarCatalogue.Shelf.LIBRARY).associateBy { it.mediaMetadata.title.toString() }
        assertEquals(MediaConstants.EXTRAS_VALUE_COMPLETION_STATUS_NOT_PLAYED, rows.getValue("Fresh").mediaMetadata.extras?.getInt(MediaConstants.EXTRAS_KEY_COMPLETION_STATUS))
        assertEquals(MediaConstants.EXTRAS_VALUE_COMPLETION_STATUS_FULLY_PLAYED, rows.getValue("Done").mediaMetadata.extras?.getInt(MediaConstants.EXTRAS_KEY_COMPLETION_STATUS))
        assertEquals(MediaConstants.EXTRAS_VALUE_STATUS_NOT_DOWNLOADED, rows.getValue("Fresh").mediaMetadata.extras?.getLong(MediaConstants.EXTRAS_KEY_DOWNLOAD_STATUS))
    }

    /** Every empty shelf says why, in CarPlay's words, in a row that plays nothing. */
    @Test
    fun emptyShelvesSayWhy() {
        val empty = AutoBrowseTree.catalogue(emptyList(), emptySet())
        val messages = CarCatalogue.Shelf.entries.map { AutoBrowseTree.items(empty, it).single() }
        assertEquals(
            listOf("Nothing started yet", "No audiobooks in your library", "No downloads on this phone"),
            messages.map { it.mediaMetadata.title.toString() },
        )
        assertTrue(messages.all { it.mediaMetadata.isPlayable == false && it.mediaMetadata.isBrowsable == false })
        assertTrue(messages.all { AutoBrowseTree.isEmptyMessage(it.mediaId) })
    }

    /** A shelf is cut to the car's limit, in the catalogue's order. */
    @Test
    fun theLimit() {
        val books = (1..150).map { book("Book %03d".format(it)) }
        val catalogue = AutoBrowseTree.catalogue(books, emptySet())
        val rows = AutoBrowseTree.items(catalogue, CarCatalogue.Shelf.LIBRARY)
        assertEquals(AutoBrowseTree.ITEM_LIMIT, rows.size)
        assertEquals("Book 001", rows.first().mediaMetadata.title.toString())
        assertEquals(12, AutoBrowseTree.items(catalogue, CarCatalogue.Shelf.LIBRARY, limit = 12).size)
    }

    /** A text-only book is never offered: a row that does nothing at 70mph. */
    @Test
    fun onlyBooksWithAudio() {
        val catalogue = AutoBrowseTree.catalogue(listOf(book("Silent", ebookOnly = true), book("Spoken"), book("Narrated", narrated = true)), emptySet())
        val titles = AutoBrowseTree.items(catalogue, CarCatalogue.Shelf.LIBRARY).map { it.mediaMetadata.title.toString() }
        assertEquals(listOf("Narrated", "Spoken"), titles)
    }

    /** A book from the reader's own files never reaches the car, however it is marked. */
    @Test
    fun localBooksAreNeverOffered() {
        val catalogue = AutoBrowseTree.catalogue(
            listOf(
                book("Mine", narrated = true, local = true, progress = 0.3, positionTimestamp = 50.0),
                book("Listed Locally", progress = 0.2, positionTimestamp = 40.0),
                book("Server", progress = 0.1, positionTimestamp = 30.0),
            ),
            downloadedUuids = setOf("mine", "listed-locally", "server"),
            localUuids = setOf("listed-locally"),
        )
        for (shelf in CarCatalogue.Shelf.entries) {
            val titles = AutoBrowseTree.items(catalogue, shelf).map { it.mediaMetadata.title.toString() }
            assertEquals("$shelf", listOf("Server"), titles)
        }
    }

    /** Paging, including Media3's page size of everything. */
    @Test
    fun paging() {
        val items = (1..5).map { list("$it") }
        assertEquals(listOf("shelf/3", "shelf/4"), AutoBrowseTree.page(items, 1, 2).map { it.mediaId })
        assertEquals(5, AutoBrowseTree.page(items, 0, Int.MAX_VALUE).size)
        assertTrue(AutoBrowseTree.page(items, 3, 2).isEmpty())
        assertTrue(AutoBrowseTree.page(items, 1, Int.MAX_VALUE).isEmpty())
        assertTrue(AutoBrowseTree.page(items, -1, 2).isEmpty())
    }
}
