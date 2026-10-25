package com.benjaminissa.issareader.core.download

import com.benjaminissa.issareader.core.bookJson
import com.benjaminissa.issareader.core.decodeBook
import com.benjaminissa.issareader.core.model.Book
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Book JSON as both primary-action suites build it. */
private fun actionBook(
    progress: Double? = null,
    ebookSize: Long? = null,
    ebookMissing: Boolean? = null,
    hasEbook: Boolean = true,
    audiobookOnly: Boolean = false,
    alignedReadaloud: Boolean = false,
): Book {
    val json = bookJson(uuid = "u", title = "A Book")
    if (audiobookOnly) {
        json["audiobook"] = mapOf("uuid" to "a", "filepath" to "a.m4b", "identifiers" to emptyList<Any>())
    } else if (hasEbook) {
        val ebook = mutableMapOf<String, Any?>("uuid" to "e", "identifiers" to emptyList<Any>())
        if (ebookSize != null) ebook["fileSize"] = ebookSize
        if (ebookMissing != null) ebook["missing"] = ebookMissing
        json["ebook"] = ebook
    }
    // An aligned read-along the server can serve, which the reading format
    // prefers over a plain ebook.
    if (alignedReadaloud) {
        json["readaloud"] = mapOf("uuid" to "r", "filepath" to "r.epub", "status" to "ALIGNED", "identifiers" to emptyList<Any>())
    }
    if (progress != null) {
        json["position"] = mapOf(
            "locator" to mapOf("href" to "a", "type" to "t", "locations" to mapOf("totalProgression" to progress)),
            "timestamp" to 0,
        )
    }
    return decodeBook(json)
}

/**
 * The book screen's primary control. Ported from
 * `BookPrimaryActionTests.swift`. Most of these are ordering questions, and
 * ordering is where this kind of state machine goes wrong quietly.
 */
class BookPrimaryActionTest {
    private fun action(subject: Book, state: DownloadManager.State? = null, isDownloaded: Boolean = false): BookPrimaryAction? =
        BookPrimaryAction.resolve(subject, state, isDownloaded)

    // The gate

    /** A book with nothing readable gets no control at all, rather than a dead end. */
    @Test
    fun audiobookOnlyGetsNoControl() {
        assertNull(action(actionBook(audiobookOnly = true)))
    }

    /** A book whose only edition the server has lost gets no control. */
    @Test
    fun missingEbookGetsNoControl() {
        assertNull(action(actionBook(ebookMissing = true)))
    }

    // Labels

    /** A book that is not here offers to fetch it, and says how big it is. */
    @Test
    fun notDownloadedOffersDownload() {
        val subject = action(actionBook(ebookSize = 312_000_000))!!
        assertTrue(subject.title().startsWith("Download · "))
        assertEquals(BookPrimaryAction.Intent.START_DOWNLOAD, subject.intent)
    }

    /** A size the server did not give is simply not claimed. */
    @Test
    fun unknownSizeIsNotInvented() {
        assertEquals("Download", action(actionBook())!!.title())
    }

    /** A transfer in flight shows its percentage. */
    @Test
    fun downloadingShowsPercent() {
        val subject = action(actionBook(), state = DownloadManager.State.Downloading(0.64, 64, 100))!!
        assertEquals("64%", subject.title())
        assertTrue(subject.isDeterminate)
        assertEquals(BookPrimaryAction.Intent.PAUSE_DOWNLOAD, subject.intent)
    }

    /** A download of unknown size never reads as 0%: that is what a stall looks like. */
    @Test
    fun indeterminateDownloadIsNotZeroPercent() {
        val subject = action(actionBook(), state = DownloadManager.State.Downloading(0.0, 5_000_000, 0))!!
        assertNotEquals("0%", subject.title())
        assertFalse(subject.isDeterminate)
    }

    /** A queued download says it is waiting, not that it is at zero. */
    @Test
    fun queuedSaysWaiting() {
        val subject = action(actionBook(), state = DownloadManager.State.Queued)!!
        assertEquals("Waiting…", subject.title())
        assertFalse(subject.isDeterminate)
        assertEquals(BookPrimaryAction.Intent.PAUSE_DOWNLOAD, subject.intent)
    }

    /** A paused download never says Resume: that is already the reading action in this very button. */
    @Test
    fun pausedNeverSaysResume() {
        val subject = action(actionBook(), state = DownloadManager.State.Paused(0.64))!!
        assertEquals("Paused · 64%", subject.title())
        assertFalse(subject.title().contains("Resume"))
        assertEquals(BookPrimaryAction.Intent.RESUME_DOWNLOAD, subject.intent)
    }

    /** A book on the device that was never opened says Read. */
    @Test
    fun downloadedUnopenedSaysRead() {
        val subject = action(actionBook(), isDownloaded = true)!!
        assertEquals("Read", subject.title())
        assertEquals(BookPrimaryAction.Intent.OPEN_READER, subject.intent)
    }

    /** A book with somewhere to return to says where. */
    @Test
    fun downloadedWithProgressSaysResume() {
        assertEquals("Resume · 42%", action(actionBook(progress = 0.42), isDownloaded = true)!!.title())
    }

    /** A percentage that would round to nothing is left off. */
    @Test
    fun barelyStartedDropsThePercentage() {
        assertEquals("Resume", action(actionBook(progress = 0.004), isDownloaded = true)!!.title())
    }

    /** A failure offers to try again, and says why on screen. */
    @Test
    fun failureShowsItsReason() {
        val subject = action(actionBook(), state = DownloadManager.State.Failed("The server returned 404."))!!
        assertEquals("Retry", subject.title())
        assertEquals("The server returned 404.", subject.detail)
        assertEquals(BookPrimaryAction.Intent.START_DOWNLOAD, subject.intent)
    }

    // Precedence, which is where this goes wrong

    /**
     * A readable book on disk beats a stale failure: a non-2xx never touches
     * the destination file, so a good file and a failed re-download coexist.
     */
    @Test
    fun onDiskBeatsFailed() {
        val subject = action(actionBook(progress = 0.5), state = DownloadManager.State.Failed("nope"), isDownloaded = true)!!
        assertEquals("Resume · 50%", subject.title())
        assertNull(subject.detail)
    }

    /** A transfer in flight beats an older copy on disk. */
    @Test
    fun downloadingBeatsOnDisk() {
        val subject = action(actionBook(), state = DownloadManager.State.Downloading(0.3, 3, 10), isDownloaded = true)!!
        assertEquals("30%", subject.title())
    }

    /** A finished download whose file has gone offers to fetch it again. */
    @Test
    fun finishedButDeletedOffersDownload() {
        assertEquals("Download", action(actionBook(), state = DownloadManager.State.Finished, isDownloaded = false)!!.title())
    }

    /** The compact label drops every suffix, for accessibility text sizes. */
    @Test
    fun compactDropsSuffixes() {
        assertEquals("Download", action(actionBook(ebookSize = 312_000_000))!!.title(compact = true))
        assertEquals("Resume", action(actionBook(progress = 0.42), isDownloaded = true)!!.title(compact = true))
        assertEquals("Paused", action(actionBook(), state = DownloadManager.State.Paused(0.6))!!.title(compact = true))
    }
}

/**
 * The book screen's reading control, which always leads with Read. Ported
 * from `BookReadingActionTests` in `BookPrimaryActionTests.swift`.
 */
class BookReadingActionTest {
    // The gate is unchanged

    /** A book with nothing readable still gets no reading control. */
    @Test
    fun audiobookOnlyGetsNoControl() {
        assertNull(BookPrimaryAction.reading(actionBook(audiobookOnly = true)))
    }

    /** A book whose only edition the server has lost gets no reading control. */
    @Test
    fun missingEbookGetsNoControl() {
        assertNull(BookPrimaryAction.reading(actionBook(ebookMissing = true)))
    }

    // Always Read, never Download

    /** A book that is not on the device still leads with Read, not a download. */
    @Test
    fun notDownloadedStillReads() {
        val subject = BookPrimaryAction.reading(actionBook())!!
        assertEquals("Read", subject.title())
        assertEquals(BookPrimaryAction.Intent.OPEN_READER, subject.intent)
    }

    /** A book with a saved position resumes, on or off the device. */
    @Test
    fun withProgressResumes() {
        val subject = BookPrimaryAction.reading(actionBook(progress = 0.42))!!
        assertEquals("Resume · 42%", subject.title())
        assertEquals(BookPrimaryAction.Intent.OPEN_READER, subject.intent)
    }

    /** A barely-started book drops the percentage, like resolve does. */
    @Test
    fun barelyStartedDropsThePercentage() {
        assertEquals("Resume", BookPrimaryAction.reading(actionBook(progress = 0.004))!!.title())
    }

    // Which edition Read opens

    /** An aligned book reads the read-along edition, so the screen can say narration is included. */
    @Test
    fun alignedBookTargetsReadaloud() {
        val subject = BookPrimaryAction.reading(actionBook(alignedReadaloud = true))!!
        assertEquals(BookContentService.Format.READALOUD, subject.format)
        assertEquals(BookPrimaryAction.Intent.OPEN_READER, subject.intent)
    }

    /** A plain text book reads the ebook edition. */
    @Test
    fun plainBookTargetsEbook() {
        assertEquals(BookContentService.Format.EBOOK, BookPrimaryAction.reading(actionBook())!!.format)
    }
}

/** What an edition row says. Ported from `DownloadStatusTextTests` in `BookPrimaryActionTests.swift`. */
class DownloadStatusTextTest {
    /** A size the server did not give shows bytes, not a percentage. */
    @Test
    fun unknownTotalShowsBytes() {
        assertNotEquals("0%", DownloadStatusText.short(DownloadManager.State.Downloading(0.0, 5_000_000, 0), isDownloaded = false))
    }

    /** A row with no state says whether the file is there. */
    @Test
    fun noStateReportsDisk() {
        assertEquals("Downloaded", DownloadStatusText.short(null, isDownloaded = true))
        assertEquals("Not downloaded", DownloadStatusText.short(null, isDownloaded = false))
    }
}
