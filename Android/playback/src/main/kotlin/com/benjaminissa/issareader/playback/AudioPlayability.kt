package com.benjaminissa.issareader.playback

import com.benjaminissa.issareader.epub.EpubInspection

/**
 * What this device's player can decode, as the platform answers it.
 *
 * On iOS the answer is `AVURLAsset.isPlayableExtendedMIMEType`, and the type an
 * extension stands for is `UTType`'s. On Android it is the codec list and the
 * MIME map (`playback-android`'s `AndroidMediaSupport`).
 */
interface MediaSupport {
    /** Whether a stream declared as [mimeType] plays here. */
    fun isPlayable(mimeType: String): Boolean

    /** The MIME type a file extension stands for, or null when it stands for none. */
    fun mimeType(extension: String): String?
}

/**
 * Whether this device can play a book's narration, asked before the book is
 * added.
 *
 * A book from a server was aligned by Storyteller, which writes audio this app
 * plays. A book from the reader's own files can carry anything a media overlay
 * may name — Opus in a `.opus` file is a common one — and narration that is
 * offered and then plays nothing is worse than a book added as text with a
 * note saying why.
 */
object AudioPlayability {
    /**
     * Whether the platform says it plays this file.
     *
     * By the media type the manifest declares, as the player is asked about any
     * stream; where the manifest declares none, by the type the file's
     * extension stands for. A file nothing can be said about is not playable.
     */
    fun isPlayable(mediaType: String?, href: String, platform: MediaSupport): Boolean {
        val declared = mediaType?.trim { it == ' ' || it == '\t' }
        if (!declared.isNullOrEmpty()) return platform.isPlayable(declared)
        val extension = AudioExtraction.pathExtension(href)
        if (extension.isEmpty()) return false
        val mime = platform.mimeType(extension) ?: return false
        return platform.isPlayable(mime)
    }

    /**
     * Whether every file of an inspected book's narration is in the archive and
     * playable here. False for a book with no narration at all.
     */
    fun canNarrate(inspection: EpubInspection, platform: MediaSupport): Boolean =
        inspection.hasCompleteNarration &&
            inspection.audioFiles.all { isPlayable(it.mediaType, it.href, platform) }
}
