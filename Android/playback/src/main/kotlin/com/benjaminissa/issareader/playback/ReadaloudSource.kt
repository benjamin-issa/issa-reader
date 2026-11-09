package com.benjaminissa.issareader.playback

import com.benjaminissa.issareader.epub.EpubPackage
import com.benjaminissa.issareader.epub.SmilParser
import com.benjaminissa.issareader.epub.SmilTimeline
import java.io.File

/**
 * A downloaded read-along, opened far enough to play it: the package, the
 * media overlay, and the narration on disk.
 *
 * The three steps were already written down separately — [EpubPackage.open],
 * [SmilParser.timeline], [AudioExtraction.extractAudio] — and the reader
 * performs them in that order when a book is opened. The car cannot: Android
 * Auto starts a book with no reader anywhere, so starting to listen has to be
 * able to do the same three things from a cold launch. Naming them once keeps
 * the two paths from drifting into two ideas of what a read-along is.
 */
data class ReadaloudSource(
    val epubPackage: EpubPackage,
    val timeline: SmilTimeline,
    /** Archive href to file on disk, as [AudioExtraction] returns it. */
    val audioFiles: Map<String, File>,
) {
    companion object {
        /**
         * @param epubPackage an already-open package, when the caller has one.
         *   A reader on screen holds both this and the timeline, and reopening
         *   the archive to build them a second time is a ZIP inflate and a full
         *   overlay parse for an answer already in memory.
         * @param timeline likewise.
         *
         * Blocking, all three steps: inflating a few hundred megabytes of
         * narration is not something to do on the main thread. Callers run it
         * on an I/O dispatcher, interruptibly — see [AudioExtraction].
         */
        fun load(
            epubFile: File,
            bookId: String,
            epubPackage: EpubPackage? = null,
            timeline: SmilTimeline? = null,
            directory: File? = null,
            isCancelled: (() -> Boolean)? = null,
        ): ReadaloudSource {
            val opened = epubPackage ?: EpubPackage.open(epubFile)
            // With whatever file lengths an earlier listen measured: a clip whose
            // overlay states no end runs to the end of its file, and the cache is
            // the only place that length is known before the audio is extracted.
            // Empty for every book a server aligned, and for a book never
            // listened to, where such a clip keeps its placeholder length.
            val overlay = timeline ?: SmilParser.timeline(
                opened,
                directory?.let(ChunkDurations::loadFromDirectory) ?: ChunkDurations.load(bookId),
            )
            val files = if (isCancelled != null) {
                AudioExtraction.extractAudio(opened, overlay, bookId, directory, isCancelled)
            } else {
                AudioExtraction.extractAudio(opened, overlay, bookId, directory)
            }
            return ReadaloudSource(opened, overlay, files)
        }
    }
}
