package com.benjaminissa.issareader.core.model

import kotlinx.serialization.Serializable

/**
 * A Readium audiobook manifest, as `GET /books/{uuid}/listen/manifest.json`
 * returns it.
 *
 * Captured from a live 2.14.21 server: the reading order is one entry per
 * track with a title, a duration and a relative href. Two traps are folded in
 * below — a single-file audiobook advertises an `m4b` alternate link that
 * always 404s, and the file extension follows the server's transcoding
 * setting, so nothing may assume `.mp3`.
 *
 * Built in code, not only decoded.
 *
 * A read-along's audio is the EPUB's own narration chunks, and the track list
 * the server serves for the same book is the original upload — one file where
 * the overlay has a hundred and seventy-six. The two never match, so the
 * read-along path synthesises a manifest over the chunks instead. It is built
 * through this constructor rather than through a second manifest type, so
 * everything downstream — the book clock, the anchor bridge, the locator
 * written back to the server — is the same code either way.
 */
@Serializable
data class AudiobookManifest(
    val metadata: Metadata,
    val readingOrder: List<Track>,
    val links: List<Link>? = null,
    val toc: List<Track>? = null,
) {
    /**
     * Spelled out with defaults because a manifest is built in code as well as
     * decoded: the read-along path synthesises one from the book's own media
     * overlay.
     */
    @Serializable
    data class Metadata(
        /** Readium states titles per language: `{"und": "Peter and Wendy"}`. */
        val title: Map<String, String>? = null,
        val subtitle: Map<String, String>? = null,
        val language: List<String>? = null,
        val duration: Double? = null,
    ) {
        /** The title in whatever language the server offered. */
        val displayTitle: String?
            get() {
                val title = title
                if (title.isNullOrEmpty()) return null
                return title["en"] ?: title["und"] ?: title.entries.minByOrNull { it.key }?.value
            }
    }

    /**
     * One file of the book. See [Metadata]: the same type the server's is
     * decoded into, rather than a parallel one, for a synthesised manifest.
     */
    @Serializable
    data class Track(
        val href: String,
        val type: String? = null,
        val title: String? = null,
        val duration: Double? = null,
        val size: Long? = null,
        val bitrate: Double? = null,
        val rel: List<String>? = null,
    ) {
        val id: String get() = href
    }

    @Serializable
    data class Link(
        val href: String,
        val type: String? = null,
        val rel: List<String>? = null,
    )

    /** A point on the book clock: the playable track, and how far into it. */
    data class Located(val index: Int, val offset: Double)

    /**
     * The tracks worth playing.
     *
     * Anything with no duration is dropped: the m4b alternate link the server
     * advertises for a single-file audiobook has none, and following it always
     * 404s. Chapters are the reading order, not the links.
     */
    val playableTracks: List<Track>
        get() = readingOrder.filter { (it.duration ?: 0.0) > 0 }

    /**
     * Total running time, preferring the sum of the tracks over the stated
     * metadata: a book whose metadata says `00:00:00` still plays.
     */
    val totalDuration: Double
        get() {
            val summed = playableTracks.fold(0.0) { total, track -> total + (track.duration ?: 0.0) }
            return if (summed > 0) summed else metadata.duration ?: 0.0
        }

    /** Chapter titles, falling back to a track number rather than to nothing. */
    fun title(of: Track, at: Int): String {
        val title = of.title
        if (!title.isNullOrEmpty()) return title
        return "Track ${at + 1}"
    }

    /**
     * Where a track starts within the whole book, for a single scrubber over
     * a book split across many files.
     */
    fun startTime(ofTrackAt: Int): Double =
        playableTracks.take(ofTrackAt).fold(0.0) { total, track -> total + (track.duration ?: 0.0) }

    /**
     * The track playing at a point in the book, and how far into it.
     *
     * **The exact inverse of [startTime]**, which is a promise rather than an
     * accident: `locate(startTime(k))` must be `(k, 0)` for every `k`, and for
     * a while it was not. This used to subtract each duration off a running
     * remainder while `startTime` added them up from the left, and two
     * roundings of one sum do not agree — on four tracks of `100.1` seconds,
     * `startTime(3)` is `300.29999999999995`, a ULP short of the three
     * durations this walk had already taken off, so the residual stayed below
     * the third boundary and the answer came back as *the end of track two*.
     * Over two hundred random forty-track books with fractional durations,
     * 46.7% of the boundaries disagreed.
     *
     * It reads as a read-along problem and is not. When no chapter list is
     * supplied — every book playing the server's own manifest —
     * `AudiobookCoordinator` makes each chapter start exactly `startTime`, so
     * "previous, to restart this chapter" loaded the *previous* track a
     * fraction of a second from its end on about half the chapters of every
     * streamed audiobook. It ran out within the second, `advance()` read that
     * as a chapter ending, and an armed end-of-chapter sleep timer stopped the
     * book. [bookTime] sums the same way, so a resume landed a chunk early too.
     *
     * So the boundary is compared against a *running total* built by the same
     * left fold `startTime` uses, which makes the two bit-identical rather than
     * merely close. No binary search, and deliberately no cache: a cache over
     * the reading order would be a second answer waiting to go stale.
     */
    fun locate(bookTime: Double): Located? {
        val tracks = playableTracks
        if (tracks.isEmpty()) return null
        // Swift's `max(0, .nan)` is `0` — a comparison against NaN is false, so
        // the other operand wins — which is what a non-finite clock has always
        // resolved to here, and what `BookClockTests` feeds this on purpose.
        // Kept, not corrected: refusing it would be a new contract. Hence
        // `swiftMax`, not `maxOf`, which would pass the NaN through.
        val target = swiftMax(0.0, bookTime)
        var start = 0.0
        for ((index, track) in tracks.withIndex()) {
            val duration = track.duration ?: 0.0
            val end = start + duration
            if (target < end || index == tracks.size - 1) {
                return Located(index, swiftMin(swiftMax(0.0, target - start), duration))
            }
            start = end
        }
        return Located(tracks.size - 1, 0.0)
    }

    // The anchor bridge (`AudioAnchor.swift`'s extension of the manifest).

    /**
     * The playable track that names this file, if any.
     *
     * The exact href first, and only then the **file name alone**. The name
     * pass has to stay: the media overlay names an archive path inside the
     * EPUB (`OEBPS/audio/ch62.mp3`) while the manifest names whatever the
     * server serves (`ch62.mp3`) — the same file under two names.
     * `ReadiumLocator.normalizeHref` compares the last *two* components, which
     * is right for text, where `text/ch01` and `images/ch01` are different
     * resources, and wrong here for that very reason.
     *
     * But a file name is not always a name. A manifest synthesised over a
     * book's own narration chunks carries full archive paths on purpose, and a
     * book laid out `Audio/ch01/track.mp3`, `Audio/ch02/track.mp3` — the layout
     * `AudioExtraction.filename(for:)` exists to flatten — has one file name
     * for the whole book. On the name alone every chunk collapsed onto track
     * one: an anchor thirty seconds into chapter twelve resolved to thirty
     * seconds into the *book*, the resume reported success, and the position
     * guard let that zero be written over a part-read novel. The exact pass
     * costs a string compare and cannot be wrong.
     *
     * And the exact pass is not enough on its own, because it is only reached
     * when it misses. `ChunkManifest.make` drops a chunk with no extracted file
     * and a chunk with no length, and the moment one of those `track.mp3`s is
     * gone the anchor naming it falls through to the name pass — where the
     * *other* chapters still answer to `track.mp3`, and the first of them won.
     * A different chapter entirely, returned as `.anchor`: reported as a
     * success, and a success is what releases the hold on the audio clock. So a
     * name that two or more playable tracks answer to is not a name for any of
     * them, and this returns null rather than choosing between them.
     *
     * Not gated on where the manifest came from. This type does not know its
     * own provenance — `ManifestKind` is a label the caller attaches, over in
     * the playback module, and reaching for it from core would invert a module
     * dependency — and provenance is in any case only a proxy for the property
     * that actually decides the answer, which is whether the name is ambiguous.
     *
     * One residual risk, documented rather than coded around: if every
     * `track.mp3` but one is dropped, the survivor's name *is* unique again,
     * and any anchor from that book resolves onto it. The blast radius is a
     * manifest with one chunk left in it, where the wrong answer and the right
     * one are the same track.
     */
    fun trackIndex(matching: String): Int? {
        val tracks = playableTracks
        val exact = tracks.indexOfFirst { it.href == matching }
        if (exact >= 0) return exact
        val wanted = audioFileName(matching)
        if (wanted.isEmpty()) return null
        var match: Int? = null
        for ((index, track) in tracks.withIndex()) {
            if (audioFileName(track.href) != wanted) continue
            if (match != null) return null
            match = index
        }
        return match
    }

    /**
     * Where a file and an offset into it fall on this manifest's book clock.
     *
     * `null` when no track answers to that file — a book whose audio the
     * server serves under names the EPUB does not use. Returning `null` rather
     * than a guess is the point: a wrong number here is the bug [AudioAnchor]
     * exists for.
     *
     * Stated over the pair rather than only over an [AudioAnchor], because a
     * media-overlay entry is a file and an offset too and has no business
     * pretending to be an anchor to say so. `ListeningResume`'s overlay rung
     * used to fabricate one stamped `writtenAt: 0` purely to reach this
     * arithmetic, which was harmless until an anchor's age started deciding
     * anything — at which point a synthetic anchor dated 1970 is a landmine.
     */
    fun bookTime(inFile: String, offset: Double): Double? {
        val index = trackIndex(inFile) ?: return null
        val track = playableTracks[index]
        // The same door `AudioAnchor`'s constructor shuts: a non-finite offset
        // has reached a seek in this app before, and NaN propagates through
        // the clamp below rather than being stopped by it.
        val sane = if (offset.isFinite()) maxOf(0.0, offset) else 0.0
        // Clamped to the track: an anchor written against a differently
        // transcoded copy can overshoot, and overshooting rolls into the next
        // chapter silently.
        val within = swiftMin(sane, track.duration ?: sane)
        return startTime(index) + within
    }

    /** Where an anchor falls on this manifest's book clock. */
    fun bookTime(anchor: AudioAnchor): Double? = bookTime(anchor.audioHref, anchor.offset)

    companion object {
        /** The last path component, lowercased, with query and fragment removed. */
        fun audioFileName(href: String): String {
            var value = href.substringBefore('#').substringBefore('?')
            value = value.removingPercentEncoding() ?: value
            return value.split('/').lastOrNull { it.isNotEmpty() }?.lowercase() ?: ""
        }
    }
}
