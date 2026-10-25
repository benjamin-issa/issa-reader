package com.benjaminissa.issareader.core.download

import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.ByteCountText
import com.benjaminissa.issareader.core.model.ReadingProgress

/**
 * The one control a book screen offers, and what it currently means.
 *
 * The screen used to show Resume and Download as two permanent controls, so it
 * offered to resume a book it did not have while hiding the thing that would
 * fetch it. One control that follows the state answers both.
 *
 * Here rather than in a view because every decision below is one that can go
 * quietly wrong, and a pure value is the only way any of it gets checked.
 */
data class BookPrimaryAction(
    /** The edition the control acts on: the aligned readaloud when the server has one, otherwise the plain ebook. */
    val format: BookContentService.Format,
    val kind: Kind,
) {
    sealed interface Kind {
        /** Not on the device. [bytes] is null when the server did not say. */
        data class Download(val bytes: Long?) : Kind

        /** Asked for, nothing arriving yet. */
        data object Waiting : Kind

        data class Downloading(val fraction: Double, val bytesWritten: Long, val isDeterminate: Boolean) : Kind

        data class PausedDownload(val fraction: Double) : Kind

        /** On the device, never opened. */
        data object Read : Kind

        /** On the device, with somewhere to return to. */
        data class Resume(val progress: Double) : Kind

        data class Retry(val reason: String) : Kind
    }

    /** What the control should do, so the view's tap handler carries no logic. */
    enum class Intent { OPEN_READER, START_DOWNLOAD, PAUSE_DOWNLOAD, RESUME_DOWNLOAD }

    // Presentation

    /**
     * The button's label. [compact] drops the trailing size or percentage: at
     * an accessibility text size "Download · 312 MB" is wider than the screen,
     * and shrinking a primary action's type is not an honest way to fit it.
     */
    fun title(compact: Boolean = false): String = when (val kind = kind) {
        is Kind.Download -> {
            val bytes = kind.bytes
            if (bytes == null || compact) "Download" else "Download · ${ByteCountText.text(bytes)}"
        }
        Kind.Waiting -> "Waiting…"
        is Kind.Downloading -> when {
            !kind.isDeterminate -> if (compact) "Downloading" else "Downloading · ${ByteCountText.text(kind.bytesWritten)}"
            else -> "${(kind.fraction * 100).toInt()}%"
        }
        // Never "Resume": that is already the reading action in this very
        // button, and the two would be indistinguishable.
        is Kind.PausedDownload -> if (compact) "Paused" else "Paused · ${(kind.fraction * 100).toInt()}%"
        Kind.Read -> "Read"
        is Kind.Resume -> {
            val percent = ReadingProgress.percent(kind.progress)
            if (percent < 1 || compact) "Resume" else "Resume · $percent%"
        }
        is Kind.Retry -> "Retry"
    }

    /** The line beneath the button. Only a failure has one, so the reason is on screen and not only spoken. */
    val detail: String? get() = (kind as? Kind.Retry)?.reason

    val fraction: Double?
        get() = when (val kind = kind) {
            is Kind.Downloading -> kind.fraction
            is Kind.PausedDownload -> kind.fraction
            else -> null
        }

    val isDeterminate: Boolean
        get() = when (val kind = kind) {
            is Kind.Downloading -> kind.isDeterminate
            Kind.Waiting -> false
            else -> true
        }

    val intent: Intent
        get() = when (kind) {
            Kind.Read, is Kind.Resume -> Intent.OPEN_READER
            is Kind.Download, is Kind.Retry -> Intent.START_DOWNLOAD
            Kind.Waiting, is Kind.Downloading -> Intent.PAUSE_DOWNLOAD
            is Kind.PausedDownload -> Intent.RESUME_DOWNLOAD
        }

    val accessibilityLabel: String
        get() {
            val detail = detail ?: return title()
            return "${title()}. $detail"
        }

    companion object {
        /**
         * Resolves the control for a book, or null when there is nothing to
         * read. Null is the gate: an audiobook-only book, or one whose every
         * readable edition the server has lost, gets no primary control rather
         * than one that leads nowhere.
         */
        fun resolve(book: Book, state: DownloadManager.State?, isDownloaded: Boolean): BookPrimaryAction? {
            val format = BookContentService.preferredReadingFormat(book) ?: return null
            return BookPrimaryAction(format, kind(book, format, state, isDownloaded))
        }

        /**
         * The reading control, which always leads with **Read**.
         *
         * [resolve] is the download-state machine; this one is deliberately
         * blind to all of it: the primary control is a promise to *read*, and
         * opening the reader fetches the file on demand when it is absent. So
         * a book not yet on disk still says "Read", and a transfer in flight
         * never hijacks the verb. Null on the same gate as [resolve]. The
         * [format] it carries is the edition Read will open.
         */
        fun reading(book: Book): BookPrimaryAction? {
            val format = BookContentService.preferredReadingFormat(book) ?: return null
            val progress = book.progress
            val kind = if (progress != null && progress > 0) Kind.Resume(progress) else Kind.Read
            return BookPrimaryAction(format, kind)
        }

        /** Order matters here more than anything else in this type. */
        private fun kind(
            book: Book,
            format: BookContentService.Format,
            state: DownloadManager.State?,
            isDownloaded: Boolean,
        ): Kind {
            when (state) {
                // Not "0%": a fraction of zero is also what a stalled transfer
                // looks like, and the two should not read the same.
                DownloadManager.State.Queued -> return Kind.Waiting
                // A transfer in flight is the more urgent truth even when an
                // older copy is already on disk.
                is DownloadManager.State.Downloading ->
                    return Kind.Downloading(state.fractionCompleted, state.bytesWritten, isDeterminate = state.totalBytes > 0)
                is DownloadManager.State.Paused -> return Kind.PausedDownload(state.fractionCompleted)
                else -> Unit
            }

            // Deliberately above a failure. A non-2xx response never touches
            // the destination file, so a book that downloaded cleanly and later
            // failed a re-download has both a good file and a failed state —
            // and offering "Retry" over a readable book would be wrong.
            if (isDownloaded) {
                val progress = book.progress
                if (progress != null && progress > 0) return Kind.Resume(progress)
                return Kind.Read
            }
            if (state is DownloadManager.State.Failed) return Kind.Retry(state.reason)
            // Finished with the file since deleted lands here and reads
            // "Download", which is what it is.
            return Kind.Download(size(book, format))
        }

        private fun size(book: Book, format: BookContentService.Format): Long? = when (format) {
            BookContentService.Format.EBOOK -> book.ebook?.fileSize
            BookContentService.Format.AUDIOBOOK -> book.audiobook?.fileSize
            BookContentService.Format.READALOUD -> book.readaloud?.fileSize
        }
    }
}

/**
 * What an edition row says about itself, now that it carries no buttons.
 * Shared with the downloads screen so the "size unknown" rule is written once.
 */
object DownloadStatusText {
    fun short(state: DownloadManager.State?, isDownloaded: Boolean): String = when (state) {
        DownloadManager.State.Queued -> "Waiting"
        is DownloadManager.State.Downloading ->
            if (state.totalBytes > 0) "${(state.fractionCompleted * 100).toInt()}%" else ByteCountText.text(state.bytesWritten)
        is DownloadManager.State.Paused -> "Paused · ${(state.fractionCompleted * 100).toInt()}%"
        is DownloadManager.State.Failed -> "Failed"
        DownloadManager.State.Finished -> "Downloaded"
        null -> if (isDownloaded) "Downloaded" else "Not downloaded"
    }
}
