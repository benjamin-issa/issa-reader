package com.benjaminissa.issareader.core.download

import com.benjaminissa.issareader.core.bookJson
import com.benjaminissa.issareader.core.decodeBook
import com.benjaminissa.issareader.core.download.BookMenu.EditionAction
import com.benjaminissa.issareader.core.download.BookMenu.Item
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.Status
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The hold / right-click menu every book surface shares. Ported from
 * `BookMenuTests.swift`. Each case is something the menu can get quietly
 * wrong while still drawing.
 */
class BookMenuTest {
    private val ebookFormat = BookContentService.Format.EBOOK
    private val audiobookFormat = BookContentService.Format.AUDIOBOOK
    private val readaloudFormat = BookContentService.Format.READALOUD

    private fun book(
        uuid: String = "u",
        status: String? = null,
        progress: Double? = null,
        ebook: Boolean = true,
        audiobook: Boolean = false,
        readaloud: Boolean = false,
        ebookMissing: Boolean = false,
        authors: List<String> = listOf("Bram Stoker"),
        series: List<Pair<String, Double?>> = emptyList(),
    ): Book {
        val json = bookJson(uuid = uuid, title = "A Book")
        json["authors"] = authors.map { mapOf("uuid" to it, "name" to it) }
        json["series"] = series.map { (name, position) ->
            val row = mutableMapOf<String, Any?>("uuid" to name, "name" to name)
            if (position != null) row["position"] = position
            row
        }
        if (ebook) json["ebook"] = mapOf("uuid" to "e", "identifiers" to emptyList<Any>(), "missing" to ebookMissing)
        if (audiobook) json["audiobook"] = mapOf("uuid" to "a", "filepath" to "a.m4b", "identifiers" to emptyList<Any>())
        if (readaloud) {
            json["readaloud"] = mapOf("uuid" to "r", "filepath" to "r.epub", "status" to "ALIGNED", "identifiers" to emptyList<Any>())
        }
        if (status != null) json["status"] = mapOf("uuid" to status, "name" to status)
        if (progress != null) {
            json["position"] = mapOf(
                "locator" to mapOf("href" to "a", "type" to "t", "locations" to mapOf("totalProgression" to progress)),
                "timestamp" to 0,
            )
        }
        return decodeBook(json)
    }

    private fun status(name: String) = Status(uuid = name, name = name)

    private fun menu(book: Book, inputs: BookMenu.Inputs = BookMenu.Inputs()): BookMenu = BookMenu.resolve(book, inputs)

    // Opening the book

    /** The first group is View details, Read, Listen, in that order. */
    @Test
    fun openingOrder() {
        assertEquals(listOf(Item.Details, Item.Read("Read"), Item.Listen), menu(book(readaloud = true)).sections.first())
    }

    /** An audiobook-only book has no Read, because there is no text to open. */
    @Test
    fun audiobookOnlyHasNoRead() {
        val items = menu(book(ebook = false, audiobook = true)).items
        assertFalse(items.any { it is Item.Read })
        assertTrue(Item.Listen in items)
    }

    /** A book with a place to return to says Resume, as the book page does. */
    @Test
    fun resumeWhenStarted() {
        assertTrue(Item.Read("Resume") in menu(book(progress = 0.4)).items)
    }

    /** Listen is offered for a read-along and for an audiobook, and for neither on a plain ebook. */
    @Test
    fun listenNeedsAudio() {
        assertTrue(Item.Listen in menu(book(readaloud = true)).items)
        assertTrue(Item.Listen in menu(book(audiobook = true)).items)
        assertFalse(Item.Listen in menu(book()).items)
    }

    /** Listen becomes Now Playing while this book is the one playing. */
    @Test
    fun nowPlaying() {
        val items = menu(book(audiobook = true), BookMenu.Inputs(isPlaying = true)).items
        assertTrue(Item.NowPlaying in items)
        assertFalse(Item.Listen in items)
    }

    // Status and rating

    /** No statuses from the server means no Mark as. */
    @Test
    fun noStatusesNoMarkAs() {
        assertFalse(menu(book()).items.any { it is Item.MarkAs })
    }

    /** Mark as lists every status in the server's order with the book's own marked. */
    @Test
    fun markAsMarksCurrent() {
        val statuses = listOf("To read", "Reading", "Read").map(::status)
        val items = menu(book(status = "Reading"), BookMenu.Inputs(statuses = statuses)).items
        val choices = items.filterIsInstance<Item.MarkAs>().first().choices
        assertEquals(listOf("To read", "Reading", "Read"), choices.map { it.status.name })
        assertEquals(listOf(false, true, false), choices.map { it.isCurrent })
    }

    /** Rate carries the current rating, so Clear rating appears only when there is one. */
    @Test
    fun rateCarriesRating() {
        assertTrue(Item.Rate(null) in menu(book()).items)
        assertTrue(Item.Rate(4) in menu(book(), BookMenu.Inputs(rating = 4.0)).items)
    }

    /** R-07. A rating far outside five stars is clamped, not a crash. */
    @Test
    fun absurdRatingIsClamped() {
        for ((rating, stars) in listOf(1e300 to 5, -1e300 to 0, 7.6 to 5, -2.0 to 0, 3.4 to 3)) {
            assertTrue("$rating", Item.Rate(stars) in menu(book(), BookMenu.Inputs(rating = rating)).items)
        }
    }

    // Editions

    /** Each edition's one action follows its download state. */
    @Test
    fun editionActionFollowsState() {
        assertEquals(EditionAction.Kind.SAVE, BookMenu.kind(state = null, onDisk = false))
        assertEquals(EditionAction.Kind.PAUSE, BookMenu.kind(state = DownloadManager.State.Queued, onDisk = false))
        assertEquals(
            EditionAction.Kind.PAUSE,
            BookMenu.kind(state = DownloadManager.State.Downloading(0.5, 5, 10), onDisk = false),
        )
        assertEquals(EditionAction.Kind.RESUME, BookMenu.kind(state = DownloadManager.State.Paused(0.5), onDisk = false))
        assertEquals(EditionAction.Kind.RETRY, BookMenu.kind(state = DownloadManager.State.Failed("nope"), onDisk = false))
        assertEquals(EditionAction.Kind.REMOVE, BookMenu.kind(state = null, onDisk = true))
        // A good file and a failed re-download: the file wins, as on the page.
        assertEquals(EditionAction.Kind.REMOVE, BookMenu.kind(state = DownloadManager.State.Failed("nope"), onDisk = true))
    }

    /** One edition is drawn inline; several go behind a Downloads submenu. */
    @Test
    fun inlineOrSubmenu() {
        val single = menu(book()).items
        assertTrue(Item.Edition(EditionAction(ebookFormat, EditionAction.Kind.SAVE)) in single)

        val several = menu(book(audiobook = true, readaloud = true), BookMenu.Inputs(downloadedFormats = setOf(readaloudFormat))).items
        assertTrue(
            Item.Downloads(
                listOf(
                    EditionAction(ebookFormat, EditionAction.Kind.SAVE),
                    EditionAction(audiobookFormat, EditionAction.Kind.SAVE),
                    EditionAction(readaloudFormat, EditionAction.Kind.REMOVE),
                ),
            ) in several,
        )
    }

    /** An edition the server has lost gets no action. */
    @Test
    fun lostEditionGetsNothing() {
        val items = menu(book(audiobook = true, ebookMissing = true)).items
        assertTrue(Item.Edition(EditionAction(audiobookFormat, EditionAction.Kind.SAVE)) in items)
        assertFalse(items.any { it is Item.Downloads })
    }

    /** A Downloads row's own removal comes last and is not repeated among the editions. */
    @Test
    fun focusedRemovalIsLast() {
        val subject = menu(
            book(readaloud = true),
            BookMenu.Inputs(downloadedFormats = setOf(ebookFormat, readaloudFormat), focusEdition = ebookFormat),
        )
        assertEquals(listOf(Item.RemoveFocused(ebookFormat)), subject.sections.last())
        // The other edition stays, inline now that it is the only one left.
        assertTrue(Item.Edition(EditionAction(readaloudFormat, EditionAction.Kind.REMOVE)) in subject.items)
        assertFalse(Item.Edition(EditionAction(ebookFormat, EditionAction.Kind.REMOVE)) in subject.items)
    }

    // Series and author

    /** Go to Series follows the library's grouping: a series of one has no page. */
    @Test
    fun seriesNeedsAGroup() {
        val inSeries = book(series = listOf("Gothic Horror" to 1.0))
        assertTrue(Item.GoToSeries("Gothic Horror") in menu(inSeries, BookMenu.Inputs(groupedSeries = setOf("Gothic Horror"))).items)
        assertFalse(Item.GoToSeries("Gothic Horror") in menu(inSeries, BookMenu.Inputs(groupedSeries = emptySet())).items)
    }

    /** Go to Series names the numbered membership, as the cover badge does. */
    @Test
    fun seriesIsThePrimaryOne() {
        val omnibus = book(series = listOf("Shelf" to null, "Gothic Horror" to 2.0))
        assertTrue(
            Item.GoToSeries("Gothic Horror") in menu(omnibus, BookMenu.Inputs(groupedSeries = setOf("Shelf", "Gothic Horror"))).items,
        )
    }

    /** Go to Series is hidden on that series' own page. */
    @Test
    fun seriesHiddenOnItsPage() {
        val inSeries = book(series = listOf("Gothic Horror" to 1.0))
        val inputs = BookMenu.Inputs(groupedSeries = setOf("Gothic Horror"), place = BookMenu.Place.Series("Gothic Horror"))
        assertFalse(Item.GoToSeries("Gothic Horror") in menu(inSeries, inputs).items)
    }

    /** More by needs another book by the author, and is hidden on the author's own page. */
    @Test
    fun moreByRules() {
        val subject = book()
        assertFalse(Item.MoreBy("Bram Stoker") in menu(subject, BookMenu.Inputs(firstAuthorBookCount = 1)).items)
        assertTrue(Item.MoreBy("Bram Stoker") in menu(subject, BookMenu.Inputs(firstAuthorBookCount = 2)).items)
        assertFalse(
            Item.MoreBy("Bram Stoker") in
                menu(subject, BookMenu.Inputs(firstAuthorBookCount = 2, place = BookMenu.Place.Author("Bram Stoker"))).items,
        )
    }

    // Platforms

    /** The television keeps Mark as, Rate and the editions, and nothing that leads off its one screen. */
    @Test
    fun television() {
        val subject = menu(
            book(audiobook = true, series = listOf("Gothic Horror" to 1.0)),
            BookMenu.Inputs(
                statuses = listOf(status("Reading")), groupedSeries = setOf("Gothic Horror"),
                firstAuthorBookCount = 3, capabilities = BookMenu.Capabilities.TELEVISION,
            ),
        )
        for (item in subject.items) {
            when (item) {
                is Item.MarkAs, is Item.Rate, is Item.Edition, is Item.Downloads -> continue
                else -> throw AssertionError("the television offered $item")
            }
        }
        assertTrue(subject.items.any { it is Item.MarkAs })
    }

    /** A settings window keeps details and reading but cannot push a page. */
    @Test
    fun settingsWindow() {
        val items = menu(
            book(series = listOf("Gothic Horror" to 1.0)),
            BookMenu.Inputs(groupedSeries = setOf("Gothic Horror"), firstAuthorBookCount = 3, capabilities = BookMenu.Capabilities.SETTINGS_WINDOW),
        ).items
        assertTrue(Item.Details in items)
        assertFalse(Item.GoToSeries("Gothic Horror") in items)
        assertFalse(Item.MoreBy("Bram Stoker") in items)
    }

    /** Signed out, only removing a file on this device is offered. */
    @Test
    fun signedOut() {
        val subject = menu(
            book(readaloud = true),
            BookMenu.Inputs(
                isSignedIn = false, statuses = listOf(status("Reading")),
                downloadedFormats = setOf(ebookFormat, readaloudFormat), focusEdition = readaloudFormat,
            ),
        )
        assertEquals(
            listOf(
                listOf(Item.Edition(EditionAction(ebookFormat, EditionAction.Kind.REMOVE))),
                listOf(Item.RemoveFocused(readaloudFormat)),
            ),
            subject.sections,
        )
        assertTrue(menu(book(), BookMenu.Inputs(isSignedIn = false)).isEmpty)
    }

    /** An edition's words name the edition only inside the submenu. */
    @Test
    fun editionTitles() {
        val action = EditionAction(readaloudFormat, EditionAction.Kind.SAVE)
        assertEquals("Save for offline", action.title(namingEdition = false))
        assertEquals("Save Read-along for offline", action.title(namingEdition = true))
        assertTrue(EditionAction(ebookFormat, EditionAction.Kind.REMOVE).isDestructive)
    }
}
