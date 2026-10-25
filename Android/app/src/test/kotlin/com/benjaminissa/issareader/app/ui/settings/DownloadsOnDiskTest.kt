package com.benjaminissa.issareader.app.ui.settings

import com.benjaminissa.issareader.app.model.AppModel
import com.benjaminissa.issareader.core.download.BookContentService
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * What the storage screen scans for during a removal's undo window: Swift's
 * `DownloadsOnDiskTests`.
 *
 * `downloadedUuids` already leaves out the book being removed, so the rest of
 * the app stops offering it. Its file is still on disk, and the scan files
 * whatever no book claims under "No longer in your library": for six seconds
 * the bar drew the book just swiped away as an alert-red band.
 */
class DownloadsOnDiskTest {
    @Test
    fun `the book being removed is still scanned as the library's`() {
        val pending = AppModel.PendingRemoval(bookUuid = "dracula", format = BookContentService.Format.EBOOK, title = "Dracula")
        assertEquals(setOf("carmilla", "dracula"), DownloadsStorage.onDisk(setOf("carmilla"), pending))
    }

    @Test
    fun `with nothing pending the app's own set is scanned unchanged`() {
        assertEquals(setOf("carmilla"), DownloadsStorage.onDisk(setOf("carmilla"), null))
    }
}
