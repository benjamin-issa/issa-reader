package com.benjaminissa.issareader.app.ui

import com.benjaminissa.issareader.app.ui.book.CoverGrid
import com.benjaminissa.issareader.app.ui.book.hasScrolledPast
import com.benjaminissa.issareader.app.ui.book.railTag
import com.benjaminissa.issareader.app.ui.book.stars
import com.benjaminissa.issareader.app.ui.downloads.DownloadsRowCommands
import com.benjaminissa.issareader.app.ui.downloads.downloadsSummary
import com.benjaminissa.issareader.app.ui.downloads.metaLine
import com.benjaminissa.issareader.app.ui.downloads.statusText
import com.benjaminissa.issareader.app.ui.fixture.FixtureLibrary
import com.benjaminissa.issareader.app.ui.library.countText
import com.benjaminissa.issareader.app.ui.library.tagFilterLabel
import com.benjaminissa.issareader.app.ui.reading.resumeLabel
import com.benjaminissa.issareader.app.ui.signin.countdown
import com.benjaminissa.issareader.app.ui.signin.isCleartext
import com.benjaminissa.issareader.core.download.BookContentService
import com.benjaminissa.issareader.core.download.DownloadManager
import com.benjaminissa.issareader.core.download.DownloadsInventory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

/** The small decisions the screens make from plain values. */
class ScreenDecisionsTest {
    @Test
    fun `the grid fits Swift's adaptive columns, never wider than the largest`() {
        // 375 − 32: two columns, held to 160 rather than stretched to 163.
        assertEquals(2 to 160, CoverGrid.columns(343, 16, 108, 160))
        // 402 − 32 and 440 − 32: three each.
        assertEquals(3 to 112, CoverGrid.columns(370, 16, 108, 160))
        assertEquals(3 to 125, CoverGrid.columns(408, 16, 108, 160))
        // Too narrow for even one at the minimum is still one.
        assertEquals(1 to 90, CoverGrid.columns(90, 16, 108, 160))
    }

    @Test
    fun `the count line counts what is on screen, against the shelf when tags narrow it`() {
        assertEquals("6 books", countText(6, isSearching = false, tagCount = 0, shelfTotal = 6))
        assertEquals("1 book", countText(1, isSearching = false, tagCount = 0, shelfTotal = 6))
        assertEquals("3 of 6 books", countText(3, isSearching = false, tagCount = 1, shelfTotal = 6))
        assertEquals("1 of 1 book", countText(1, isSearching = false, tagCount = 2, shelfTotal = 1))
        assertEquals("1 result", countText(1, isSearching = true, tagCount = 1, shelfTotal = 6))
        assertEquals("0 results", countText(0, isSearching = true, tagCount = 0, shelfTotal = 6))
    }

    @Test
    fun `the tag filter is spoken in the singular for one tag`() {
        assertEquals("Filter by tag", tagFilterLabel(0))
        assertEquals("1 tag selected", tagFilterLabel(1))
        assertEquals("3 tags selected", tagFilterLabel(3))
    }

    @Test
    fun `an address that would go in the clear says so`() {
        assertTrue(isCleartext("http://192.168.1.10:8001"))
        assertTrue("a bare address is what normalising makes of it", isCleartext("192.168.1.10:8001"))
        assertFalse(isCleartext("https://library.example.com"))
        assertFalse(isCleartext(""))
    }

    @Test
    fun `the device code counts down as a timer reads`() {
        val now = Instant.parse("2026-10-25T12:00:00Z")
        assertEquals("15:00", countdown(now, now.plusSeconds(900)))
        assertEquals("0:09", countdown(now, now.plusSeconds(9)))
        assertEquals("1:00:05", countdown(now, now.plusSeconds(3605)))
        assertEquals("0:00", countdown(now, now.minusSeconds(5)))
    }

    @Test
    fun `a Downloads row names the edition and the author`() {
        val dracula = FixtureLibrary.books.first { it.title == "Dracula" }
        val item = DownloadsInventory.DownloadedItem(dracula, BookContentService.Format.READALOUD, 40_000_000)
        assertEquals("Read-along · Bram Stoker", metaLine(item))
        val ebook = item.copy(format = BookContentService.Format.EBOOK)
        // Books, not rows: two editions of one book are one book.
        assertEquals("1 book · 80 MB", downloadsSummary(listOf(item, ebook)))
        assertEquals("0 books · Zero KB", downloadsSummary(emptyList()))
    }

    @Test
    fun `a transfer's line says how far it has come`() {
        val job = DownloadManager.Job("b", BookContentService.Format.AUDIOBOOK)
        assertEquals("Audiobook · Waiting", statusText(job, DownloadManager.State.Queued))
        assertEquals("Audiobook · Paused at 42%", statusText(job, DownloadManager.State.Paused(0.42)))
        assertEquals("Audiobook · 2 MB of 4 MB · 50%", statusText(job, DownloadManager.State.Downloading(0.5, 2_000_000, 4_000_000)))
        assertEquals("Audiobook · 2 MB", statusText(job, DownloadManager.State.Downloading(0.0, 2_000_000, 0)))
        assertEquals("Audiobook · Done", statusText(job, DownloadManager.State.Finished))
        assertEquals("No room.", statusText(job, DownloadManager.State.Failed("No room.")))
    }

    @Test
    fun `a row command is about one listed row or none`() {
        val book = FixtureLibrary.books.first()
        val item = DownloadsInventory.DownloadedItem(book, BookContentService.Format.EBOOK, 1)
        assertEquals(item, DownloadsRowCommands.target(setOf(item.id), listOf(item)))
        assertNull(DownloadsRowCommands.target(emptySet(), listOf(item)))
        assertNull(DownloadsRowCommands.target(setOf(item.id, "other"), listOf(item)))
        assertNull(DownloadsRowCommands.target(setOf("gone"), listOf(item)))
    }

    @Test
    fun `a resume row says how far in, once there is any way in`() {
        val peter = FixtureLibrary.books.first { it.uuid == FixtureLibrary.READALONG_UUID }
        assertEquals("Resume Peter and Wendy, 51% complete", resumeLabel(peter))
        val unstarted = FixtureLibrary.books.first { it.progress == null }
        assertEquals("Resume ${unstarted.title}", resumeLabel(unstarted))
    }

    @Test
    fun `the list page's title comes in once the name has gone under the bar`() {
        assertFalse(hasScrolledPast(nameBottom = 120, offset = 119))
        assertTrue(hasScrolledPast(nameBottom = 120, offset = 120))
    }

    @Test
    fun `rails and ratings are named as Swift names them`() {
        assertEquals("rail.recently-added", railTag("Recently added"))
        assertEquals("rail.up-next-·-to-read", railTag("Up next · To read"))
        assertEquals("1 star", stars(1))
        assertEquals("4 stars", stars(4))
    }
}
