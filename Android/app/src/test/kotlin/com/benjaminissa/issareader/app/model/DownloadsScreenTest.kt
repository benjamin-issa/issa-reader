package com.benjaminissa.issareader.app.model

import com.benjaminissa.issareader.app.AppSuite
import com.benjaminissa.issareader.app.SharedFixtures
import com.benjaminissa.issareader.core.download.BookContentService
import com.benjaminissa.issareader.core.download.DownloadsInventory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * What the storage screen scans for during a removal's undo window. Ported
 * from `DownloadsOnDiskTests.swift`; Swift's `DownloadsView.onDisk` is
 * [DownloadsScreen.onDisk].
 */
class DownloadsOnDiskTest : AppSuite() {
    /** The book being removed is still scanned as the library's. */
    @Test
    fun pendingBookIsScanned() {
        val pending = AppModel.PendingRemoval("dracula", BookContentService.Format.EBOOK, "Dracula")
        assertEquals(setOf("carmilla", "dracula"), DownloadsScreen.onDisk(setOf("carmilla"), pending))
    }

    /** With nothing pending the app's own set is scanned unchanged. */
    @Test
    fun nothingPending() {
        assertEquals(setOf("carmilla"), DownloadsScreen.onDisk(setOf("carmilla"), null))
    }
}

/**
 * Which item a row's menu or delete is about. Ported from
 * `DownloadsRowCommandsTests.swift` (the Mac's right-click and ⌫; on Android a
 * long-press menu); [DownloadsScreen.target].
 */
class DownloadsRowCommandsTest : AppSuite() {
    private fun item(title: String, format: BookContentService.Format = BookContentService.Format.READALOUD) =
        DownloadsInventory.DownloadedItem(SharedFixtures.book(title, uuid = title.lowercase()), format, 1)

    /** A row's menu and delete act on the row named, not the first. */
    @Test
    fun downloadsRowTarget() {
        val items = listOf(item("Dracula"), item("Emma"), item("Emma", BookContentService.Format.EBOOK))
        assertEquals(items[1], DownloadsScreen.target(setOf(items[1].id), items))
        assertEquals("two editions of one book are two rows", items[2], DownloadsScreen.target(setOf(items[2].id), items))
        assertNull(DownloadsScreen.target(emptySet(), items))
        assertNull(DownloadsScreen.target(setOf(items[0].id, items[1].id), items))
        assertNull("a row removed under the menu is no row", DownloadsScreen.target(setOf("gone-readaloud"), items))
    }
}
