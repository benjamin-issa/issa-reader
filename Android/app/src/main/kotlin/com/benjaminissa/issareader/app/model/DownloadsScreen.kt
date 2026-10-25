package com.benjaminissa.issareader.app.model

import com.benjaminissa.issareader.core.download.DownloadsInventory

/**
 * What the Downloads screen decides from plain values, so the screen only
 * draws it. Swift's `DownloadsView.onDisk` and `DownloadsRowCommands`.
 */
object DownloadsScreen {
    /**
     * The books the storage scan should count as the library's own.
     *
     * [AppModel.downloadedUuids] already leaves out the book being removed,
     * so every other screen stops offering it — but its file is still there
     * during the undo window, and the scan files whatever no book claims under
     * "No longer in your library": for six seconds the bar drew the book just
     * removed as an alert-red band, under a toast offering to undo it.
     */
    fun onDisk(downloaded: Set<String>, pending: AppModel.PendingRemoval?): Set<String> {
        pending ?: return downloaded
        return downloaded + pending.bookUuid
    }

    /**
     * The item a long-press menu or a row's delete is about: the one row
     * named, if it is still listed. Several, or none, is no one row — and two
     * editions of one book are two rows.
     */
    fun target(ids: Set<String>, items: List<DownloadsInventory.DownloadedItem>): DownloadsInventory.DownloadedItem? {
        if (ids.size != 1) return null
        val id = ids.first()
        return items.firstOrNull { it.id == id }
    }
}
