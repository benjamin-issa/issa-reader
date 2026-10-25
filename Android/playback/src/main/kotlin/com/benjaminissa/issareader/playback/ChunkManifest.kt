package com.benjaminissa.issareader.playback

import com.benjaminissa.issareader.core.diagnostics.IssaLog
import com.benjaminissa.issareader.core.model.AudiobookManifest
import com.benjaminissa.issareader.epub.EpubPackage
import com.benjaminissa.issareader.epub.SmilEntry
import com.benjaminissa.issareader.epub.SmilTimeline
import java.io.File

/**
 * A place in the book a listener would call a chapter, and the place in the
 * audio it starts.
 *
 * Not a track. Storyteller cuts a book's narration into chunks by *silence*,
 * not by chapter — a hundred and seventy-six files for a novel with forty
 * chapters — so a chapter boundary lands wherever it lands inside one of them,
 * and the pair of numbers below is the whole of the difference. Everything the
 * app shows as a chapter used to be a track index, which was true only because
 * the server's own upload happened to be cut that way.
 */
data class AudiobookChapter(
    val title: String,
    /** Which track of the manifest this chapter begins in. */
    val trackIndex: Int,
    /**
     * Seconds into that track. Zero for a chapter that begins with its file,
     * which is the common case and the only one the old track-per-chapter
     * model could express.
     */
    val offset: Double = 0.0,
)

/**
 * Builds an audiobook manifest over a read-along's own narration chunks.
 *
 * The bug this exists for: one book, two engines, two track lists. The
 * read-along plays the EPUB's embedded chunks (`OEBPS/Audio/00000-00085.mp3`
 * and 175 more); the server's `listen/manifest.json` lists the *original*
 * upload, one file named after the book. [com.benjaminissa.issareader.core.model.AudioAnchor]
 * bridges the two engines by file name and offset, and across those two lists
 * no name ever matches — so a book part-read on the phone started the car at
 * zero, and the fifteen-second writer then saved that zero.
 *
 * Synthesising the manifest from the overlay removes the mismatch rather than
 * papering over it: the tracks *are* the chunks the read-along names, so every
 * anchor matches by construction, in both directions, with no arithmetic
 * between two clocks. The chapters come from the overlay too — one per run of
 * text document — which is why they can start mid-track when the track list
 * cannot.
 *
 * Nothing here streams. A book whose read-along is not downloaded keeps the
 * server's manifest and today's behaviour exactly.
 */
object ChunkManifest {
    /**
     * Everything the listening path needs to start: what to play, what to call
     * the places in it, and where the bytes are.
     */
    data class Result(
        val manifest: AudiobookManifest,
        val chapters: List<AudiobookChapter>,
        /**
         * Archive href to file on disk, filtered to the tracks that survived —
         * so [AudiobookCoordinator.Source.Files] can be handed this map whole
         * and every track in the manifest is guaranteed to have a file.
         */
        val files: Map<String, File>,
    )

    /**
     * @param durations measured file lengths, keyed by archive href. The
     *   overlay knows clip times and nothing else, so where a file has been
     *   measured that number wins — see [estimatedDurations] for what stands in.
     * @param title the book's title as the library knows it, which is better
     *   than the one baked into the EPUB when the two disagree.
     *
     * Every track this returns has a length, so `readingOrder` and
     * `playableTracks` are the same list. They have to be: the chapters below
     * are numbered off the reading order while every consumer of them —
     * [AudiobookCoordinator]'s chapter clock, `play(chapter)` — walks the
     * playable list, and `playableTracks` drops anything with no duration. One
     * zero-length chunk kept here shifted every chapter after it onto the
     * wrong track, and a range check cannot see a shift.
     */
    fun make(
        timeline: SmilTimeline,
        epubPackage: EpubPackage,
        audioFiles: Map<String, File>,
        durations: Map<String, Double>,
        title: String?,
    ): Result {
        // Media types come from the OPF manifest, which is the book saying what
        // its own files are. Storyteller writes mp3, but a CLI-aligned book may
        // carry m4a, and guessing is how an extension became a claim.
        val types = HashMap<String, String>()
        for (item in epubPackage.manifest.values) {
            if (!types.containsKey(item.href)) types[item.href] = item.mediaType
        }
        val estimates = estimatedDurations(timeline)

        val order = ArrayList<String>()
        val tracks = ArrayList<AudiobookManifest.Track>()
        for (href in fileOrder(timeline.entries)) {
            if (audioFiles[href] == null) {
                // A track with no bytes behind it would still take its share of
                // the book clock, and every position written afterwards would
                // be measured against audio that cannot play.
                IssaLog.warning("chunk has no extracted file", mapOf("href" to href))
                continue
            }
            // Resolved here rather than in the map below, because the length is
            // what decides whether this is a track at all — see `make`'s note
            // on why the two lists have to stay the same list.
            val duration = durations[href] ?: estimates[href] ?: 0.0
            if (!(duration > 0)) {
                IssaLog.warning("chunk has no length", mapOf("href" to href))
                continue
            }
            order.add(href)
            tracks.add(
                AudiobookManifest.Track(
                    // Verbatim. This is the key `AudioAnchor` matches on, and the
                    // whole point of the synthesis is that it is the same string
                    // the read-along writes. Normalising or shortening it here
                    // would rebuild the mismatch this file exists to remove.
                    href = href,
                    type = audioType(types[href]),
                    duration = duration,
                ),
            )
        }
        val total = tracks.fold(0.0) { sum, track -> sum + (track.duration ?: 0.0) }
        val manifest = AudiobookManifest(
            metadata = AudiobookManifest.Metadata(
                title = mapOf("und" to (title ?: epubPackage.metadata.title ?: "")),
                duration = total,
            ),
            readingOrder = tracks,
        )
        val kept = order.toHashSet()
        return Result(
            manifest = manifest,
            chapters = chapters(timeline, epubPackage, order),
            files = audioFiles.filterKeys { it in kept },
        )
    }

    /**
     * The media type to file a chunk's track under: the book's own claim where
     * that claim is about audio, and `audio/mpeg` where it is not.
     *
     * Not a tidying-up. `ReadiumLocator.isAudioScaled` is an `audio/` prefix
     * test on exactly this string, and it is the only thing in the app that
     * says which of two clocks a written `totalProgression` is a fraction of —
     * so a chunk the OPF types as anything else filed the *audiobook's* own
     * positions under the reader's guard, where they were measured against a
     * fraction of the text as though the two were the same quantity. This is
     * not exotic: `EpubPackage` gives an item with no `media-type` attribute at
     * all `application/octet-stream`.
     *
     * And the claim is kept verbatim when it is an audio one, because a
     * CLI-aligned book saying `audio/mp4` rather than `audio/mpeg` is the book
     * telling the truth about itself, which is why [make] reads the OPF at all.
     */
    internal fun audioType(declaredAs: String?): String {
        if (declaredAs == null || !declaredAs.lowercase().startsWith("audio/")) return "audio/mpeg"
        return declaredAs
    }

    /**
     * The distinct audio files an overlay names, in the order the book reaches
     * them.
     *
     * One track per file, at its **first** appearance. A file the spine returns
     * to later — a shared intro sting, a chapter split across two itemrefs —
     * gets no second track: two tracks with one href would give `AudioAnchor`
     * two answers for one file, and it resolves by first match, so the second
     * would be a stretch of book clock nothing could ever seek to. Said out
     * loud in the log, because it is rare enough that the first book to do it
     * is worth knowing about.
     */
    internal fun fileOrder(entries: List<SmilEntry>): List<String> {
        val order = ArrayList<String>()
        val seen = HashSet<String>()
        val warned = HashSet<String>()
        var previous: String? = null
        for (entry in entries) {
            val href = entry.audioHref
            if (seen.add(href)) {
                order.add(href)
            } else if (previous != href && warned.add(href)) {
                // Already have a track for it. Contiguous repetition is just the
                // next sentence in the same file; a gap means the book came back.
                IssaLog.warning("chunk file recurs in overlay", mapOf("href" to href))
            }
            previous = href
        }
        return order
    }

    /**
     * The longest clip end in each file — the only length a media overlay
     * knows.
     *
     * The read-along clock is a sum of *clip* durations and the audiobook clock
     * a sum of *file* durations, and SMIL states no file durations at all. The
     * last clip usually ends a beat before the file does, so this understates
     * by fractions of a second per chunk, which is why [ChunkDurations.measure]
     * exists and why a measured number wins. It is the honest fallback: derived
     * from the book's own narration rather than from an extension or a bitrate
     * guess.
     */
    internal fun estimatedDurations(timeline: SmilTimeline): Map<String, Double> {
        val longest = HashMap<String, Double>()
        for (entry in timeline.entries) {
            longest[entry.audioHref] = maxOf(longest[entry.audioHref] ?: 0.0, entry.end)
        }
        return longest
    }

    /**
     * Chapters as the overlay describes them: one per run of text document.
     *
     * A run, not a document. A spine that revisits a document — a notes page, a
     * chapter split across two itemrefs, both legal — is two places in the
     * book, and collapsing them to one would put a chapter marker tens of
     * minutes from where the listener is. [SmilTimeline] draws the same
     * distinction for its own spans, for the same reason.
     *
     * Titles come from the navigation document, matched on the archive-resolved
     * href both sides already hold, which is how the reader names a chapter
     * too. A document the contents does not list gets a numbered name rather
     * than its path: a path is not a name anybody wrote, and it is what the
     * mini bar used to print under the book's title.
     *
     * A run is held and emitted at its first **playable** entry, not at its
     * first entry. A chapter whose opening chunk was dropped above still has
     * chunks that play, and pinning it to the entry that started the run threw
     * the whole chapter away with them — after which every chapter for that
     * stretch of the book was one out, and playing chapter n played the wrong
     * one. The marker then sits where this manifest's audio for the chapter
     * actually begins, which is the only place it could honestly sit.
     */
    internal fun chapters(
        timeline: SmilTimeline,
        epubPackage: EpubPackage,
        trackOrder: List<String>,
    ): List<AudiobookChapter> {
        val track = HashMap<String, Int>()
        for ((index, href) in trackOrder.withIndex()) {
            if (!track.containsKey(href)) track[href] = index
        }
        val titles = HashMap<String, String>()
        for (point in epubPackage.navigation) {
            if (!titles.containsKey(point.href)) titles[point.href] = point.title
        }

        val chapters = ArrayList<AudiobookChapter>()
        var current: String? = null
        // Whether the run this entry belongs to is still waiting for a chunk
        // that plays, and what to call it when one arrives. Cleared the moment
        // it is emitted, so the rest of the run does not become a chapter of
        // its own.
        var awaitingAPlayableChunk = false
        var pendingTitle: String? = null
        for (entry in timeline.entries) {
            if (entry.textHref != current) {
                // The run has started whether or not it can be played, so this
                // moves even when the chunk below was dropped — otherwise the
                // next sentence of the same document would look like a fresh
                // chapter.
                current = entry.textHref
                awaitingAPlayableChunk = true
                pendingTitle = titles[entry.textHref]
            }
            if (!awaitingAPlayableChunk) continue
            val trackIndex = track[entry.audioHref] ?: continue
            chapters.add(
                AudiobookChapter(
                    title = pendingTitle ?: "Section ${chapters.size + 1}",
                    trackIndex = trackIndex,
                    // Where the chapter's first sentence starts *inside* its
                    // chunk. Zero only when the two happen to line up.
                    offset = entry.start,
                ),
            )
            awaitingAPlayableChunk = false
        }
        return chapters
    }
}
