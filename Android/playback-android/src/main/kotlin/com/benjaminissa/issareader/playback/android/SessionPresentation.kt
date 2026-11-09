package com.benjaminissa.issareader.playback.android

import android.net.Uri

/**
 * What the media session shows for the book playing now: Swift's Now Playing
 * dictionary (`RemoteCommandCenter.updateNowPlaying`) and CarPlay's Up Next
 * list in one value, so the lock screen, the notification and Android Auto
 * read one thing and cannot disagree.
 *
 * Built by the app from `NowPlayingController`'s published entry, which is
 * already scoped — [elapsed] and [duration] are the chapter's or the book's,
 * as the reader chose — so a drag on the system's bar inverts exactly what was
 * published.
 */
data class SessionPresentation(
    /** The book's uuid: what the session's ids are made from. */
    val bookId: String,
    val title: String,
    /** The book's byline. */
    val artist: String,
    /** The chapter playing, when it has a name worth showing. */
    val chapter: String?,
    /** The square cover, already checked to decode. */
    val artworkData: ByteArray? = null,
    /** The same art by address, for a car that reads covers by URI. */
    val artworkUri: Uri? = null,
    /** Seconds into the published span. */
    val elapsed: Double,
    /** The published span, in seconds. */
    val duration: Double,
    /**
     * Whether the listener wants it playing. Through a buffering stall this
     * stays true while [effectiveRate] is zero, and the session says
     * buffering rather than paused: the system's clock must stop, and its
     * button must not offer ▶ to a book that is trying to play.
     */
    val isPlaying: Boolean,
    /** What the audio is actually doing: the chosen rate, or zero. */
    val effectiveRate: Float,
    /** The listener's chosen speed, playing or not. */
    val rate: Float,
    /** The chapters, as the queue: Android Auto's Up Next. */
    val chapters: List<String> = emptyList(),
    /** Which of [chapters] is playing. */
    val chapterIndex: Int? = null,
) {
    override fun equals(other: Any?): Boolean =
        other is SessionPresentation && bookId == other.bookId && title == other.title && artist == other.artist &&
            chapter == other.chapter && artworkUri == other.artworkUri && sameArtwork(other.artworkData) &&
            elapsed == other.elapsed && duration == other.duration && isPlaying == other.isPlaying &&
            effectiveRate == other.effectiveRate && rate == other.rate && chapters == other.chapters &&
            chapterIndex == other.chapterIndex

    private fun sameArtwork(other: ByteArray?): Boolean {
        val mine = artworkData ?: return other == null
        return other != null && mine.contentEquals(other)
    }

    override fun hashCode(): Int =
        listOf(bookId, title, artist, chapter, artworkUri, elapsed, duration, isPlaying, effectiveRate, rate, chapters, chapterIndex)
            .hashCode() * 31 + (artworkData?.contentHashCode() ?: 0)
}

/**
 * The media ids the session and the car's browse tree share.
 *
 * A book is `book/<uuid>`, a chapter of the book playing `chapter/<uuid>/<n>`.
 * A uuid is the server's and never holds a slash, so the split is unambiguous.
 */
object SessionMediaIds {
    private const val BOOK = "book/"
    private const val CHAPTER = "chapter/"

    fun book(uuid: String): String = BOOK + uuid

    fun chapter(uuid: String, index: Int): String = "$CHAPTER$uuid/$index"

    /** The book a `book/` id names, or null for any other id. */
    fun bookUuid(mediaId: String): String? =
        mediaId.takeIf { it.startsWith(BOOK) }?.removePrefix(BOOK)?.takeIf { it.isNotEmpty() && '/' !in it }

    /** The book and chapter a `chapter/` id names, or null for any other id. */
    fun chapter(mediaId: String): Pair<String, Int>? {
        if (!mediaId.startsWith(CHAPTER)) return null
        val rest = mediaId.removePrefix(CHAPTER)
        val slash = rest.lastIndexOf('/')
        if (slash <= 0) return null
        val index = rest.substring(slash + 1).toIntOrNull() ?: return null
        if (index < 0) return null
        return rest.substring(0, slash) to index
    }
}
