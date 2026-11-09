package com.benjaminissa.issareader.playback

import com.benjaminissa.issareader.core.diagnostics.IssaLog
import com.benjaminissa.issareader.core.model.AudioAnchor
import com.benjaminissa.issareader.core.model.AudiobookManifest
import com.benjaminissa.issareader.core.model.asProgression
import com.benjaminissa.issareader.core.toEpochSecondsDouble
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.io.File
import java.time.Instant
import java.util.Locale

/**
 * Plays a plain audiobook: many files, presented as one continuous book.
 *
 * A readaloud has a SMIL timeline to drive it; an audiobook has only a list of
 * tracks, so this builds the same virtual book clock from track durations —
 * one scrubber across the whole book, chapter navigation that knows where the
 * boundaries are, and a position that means something when it is written back
 * to the server as a fraction of the book rather than of a file.
 *
 * Main-thread-only, as the Swift type is `@MainActor`. [scope] runs the work an
 * end of file hops through; like [ReadalongCoordinator]'s, it must be a
 * main-thread scope whose dispatcher dispatches.
 *
 * @param chapters where this book's chapters start. Empty — the default, and
 *   what every caller playing the server's own manifest passes — means one
 *   chapter per playable track, named as the manifest names it, which is what
 *   this class did before chapters and tracks could differ. An entry naming a
 *   track this manifest does not have is dropped rather than trusted: the
 *   chapter list and the track list are built by different code, and an
 *   out-of-range index would fail on the first tick. So is one that does not
 *   start after the chapter in front of it — see `chapterStarts`.
 */
class AudiobookCoordinator(
    val manifest: AudiobookManifest,
    private val source: Source,
    chapters: List<AudiobookChapter> = emptyList(),
    override val player: AudioPlayer,
    private val scope: CoroutineScope,
) : Observed(), PlaybackDriving {
    sealed interface Source {
        /** Tracks streamed from the server, with the headers its audio routes need. */
        data class Streaming(val base: String, val headers: Map<String, String>) : Source

        /** A file already on disk, played whole. */
        data class Local(val file: File) : Source

        /**
         * One file per track, keyed by `Track.href` — the archive path the media
         * overlay names and [AudioAnchor] carries.
         *
         * [Local] cannot stand in: it hands the *same* file to every track, so a
         * manifest synthesised over a book's hundred and seventy-six narration
         * chunks would play chunk one under every one of them while the book
         * clock counted on regardless.
         */
        data class Files(val files: Map<String, File>) : Source

        companion object {
            /**
             * Tracks streamed from [base], authenticated with [token] the two
             * ways the server's audio routes accept: as a bearer, and as the
             * `st_token` cookie its own web player sends.
             */
            fun streaming(base: String, token: String): Streaming = Streaming(
                base,
                mapOf("Authorization" to "Bearer $token", "Cookie" to "st_token=$token"),
            )
        }
    }

    /**
     * What became of an attempt to put the audio somewhere.
     *
     * Three outcomes, because a `Boolean` had two and the middle one was being
     * silently rounded into the wrong neighbour. `load` can end in any of them —
     * no such track, no file behind the href, or a newer load that took over
     * while this one was awaiting the engine — and `false` said the same word
     * for all three. The two that matter are opposites: one is a book that will
     * not play and has to be reported, the other is this call losing a race it
     * was never going to win, where the *correct* response is to keep quiet and
     * let the winner get on with it.
     *
     * Deliberately not a nullable `Boolean`, which would have left `null`
     * quietly meaning "superseded" at five call sites, and deliberately not an
     * exception: a thrown error invites `runCatching`, which collapses straight
     * back into the two-way loss this exists to undo.
     */
    enum class MoveOutcome {
        /** The audio is where it was asked to be, and this call owns the state. */
        LANDED,

        /**
         * There is no audio behind the place that was asked for — a time that
         * names no track, or a [Source.Files] track whose chunk is not on disk.
         * The one outcome worth telling a listener about.
         */
        UNPLAYABLE,

        /**
         * A newer load took over while this one was suspended, and owns the
         * player and the clock now.
         *
         * **Not a refusal.** Nothing may pause, tear down, or say the book would
         * not play on the strength of this: the audio is fine, it is simply
         * somewhere else, because something asked for somewhere else.
         */
        SUPERSEDED,
    }

    var trackIndex: Int by observed(0)
        private set

    /** Seconds into the whole book, not into the current file. */
    var bookTime: Double by observed(0.0)
        private set

    /**
     * The places in this book a listener would call chapters.
     *
     * Not the tracks. For the server's own upload the two coincide and this is
     * built from the track list, which is exactly the old behaviour; for a
     * manifest synthesised over a read-along's narration chunks a chapter starts
     * wherever the overlay says, which is usually part-way into a file.
     * Everything that shows a chapter — the media session, the scrubber, Android
     * Auto's queue, the sleep timer's "end of chapter" — reads this rather than
     * [trackIndex].
     */
    val chapters: List<AudiobookChapter>

    /** Which of them is playing. */
    var chapterIndex: Int by observed(0)
        private set

    /**
     * Where each chapter begins on the book clock. Computed once: it is read on
     * every tick, and `startTime(ofTrackAt)` folds over a computed filter.
     *
     * **Strictly ascending**, which is a promise the chapter list itself does
     * not make. An overlay that revisits a chunk gives a later chapter an
     * earlier track — `ChunkManifest.fileOrder` records each file at its first
     * appearance and must, or one file would answer to two stretches of book
     * clock — and starts of `[0, 9, 5]` broke every reader of them at once: the
     * binary search below returned chapter one for a time inside chapter three,
     * [chapterSpan] computed `5 - 9` and handed the scrubber the whole book
     * instead, and [nextChapter] seeked *backwards* and marked it steered, the
     * one origin the position guard never refuses.
     */
    private val chapterStarts: List<Double>

    /**
     * How many loads are between choosing a track and having loaded it.
     *
     * A load moves [trackIndex] and [bookTime] before it suspends, and the
     * player's periodic observer keeps firing across the change with the *old*
     * item's time. Announcing a chapter off that arithmetic is announcing one
     * the listener is not in, so the clock is ignored until the load settles.
     *
     * Internal rather than private so a test can see the window it opens.
     */
    internal var loadsInFlight = 0
        private set

    /**
     * How many seeks are between the clock moving and the audio following it.
     *
     * [loadsInFlight]'s twin, for the branch that loads nothing: a scrub inside
     * the current file never reaches `load`, so nothing counted it, and the
     * player's periodic observer keeps firing across the suspension.
     *
     * The clock and the chapter are set before that suspension — see
     * [seekToBookTime] — which already makes a sample carrying the *post*-seek
     * time harmless. This is for the one carrying a *pre*-seek time: it drags
     * the announced chapter back to where the scrub started, which fires
     * nothing on its own because going backwards is never an ending, and then
     * the next honest sample reads that as an advance and hands the sleep timer
     * an "end of chapter" in the middle of a deliberate skip.
     *
     * Internal rather than private so a test can see the window it opens.
     */
    internal var seeksInFlight = 0
        private set

    /**
     * Called from inside a seek, once, while [seeksInFlight] is still up.
     *
     * A test seam, null on every path a listener can reach, and the only honest
     * way to *state* that window rather than race for it. Spent when it fires,
     * which is load-bearing twice: a second scrub made from inside it — the
     * thing one of those tests is about — cannot re-enter it and recurse, and a
     * function stored here that captured this object stops holding it the
     * moment it has been used.
     */
    internal var whileSeeking: (suspend () -> Unit)? = null

    /**
     * [whileSeeking]'s twin for the other window, called once the track, the
     * clock and the chapter have all moved and before the player has been asked
     * to open anything — which is the state a load is judged on, and the state
     * a superseded load has not yet returned from.
     */
    internal var whileLoading: (suspend () -> Unit)? = null

    /**
     * Called when the playing chapter changes, for the media session and the
     * UI.
     *
     * Carries the chapter index, which is an index into [chapters] and no
     * longer a track index — the two differ the moment a chapter starts
     * mid-file.
     */
    var onChapterChange: ((Int) -> Unit)? = null

    /**
     * Called only when a chapter *ended* — the audio ran off the end of one
     * chapter into the next under the listener. Not for a chapter the listener
     * picked, nor a scrub that crossed a boundary.
     *
     * A chapter, not a file. A book played from its own narration chunks
     * crosses a file boundary every couple of minutes; only some of those are
     * chapter boundaries, and only some chapter boundaries are file boundaries
     * at all — see [AudiobookChapter].
     *
     * The sleep timer's "end of chapter" hangs off this and nothing else. It
     * used to hang off [onChapterChange], which every track load fires, so
     * picking a chapter from the list stopped the book and disarmed the timer.
     * The read-along coordinator draws the same line.
     */
    var onChapterChangeObserved: (() -> Unit)? = null

    init {
        val playable = manifest.playableTracks
        val inRange = chapters.filter { it.trackIndex in playable.indices }
        val candidates = inRange.ifEmpty {
            playable.mapIndexed { index, track -> AudiobookChapter(manifest.title(track, index), index) }
        }
        // One at a time, keeping only the chapters that move the clock forward.
        // Not a fallback to one chapter per track: a book with one bad boundary
        // still has forty good ones, and throwing them away would cost the
        // listener every chapter marker to fix a marker they never asked for.
        val kept = ArrayList<AudiobookChapter>()
        val starts = ArrayList<Double>()
        for (chapter in candidates) {
            val start = manifest.startTime(chapter.trackIndex) + chapter.offset
            val previous = starts.lastOrNull()
            if (!start.isFinite() || !(if (previous != null) start > previous else start >= 0)) {
                IssaLog.warning(
                    "chapter does not start after the one before it",
                    mapOf(
                        "chapter" to kept.size.toString(),
                        "start" to String.format(Locale.ROOT, "%.1f", start),
                        "previousStart" to String.format(Locale.ROOT, "%.1f", previous ?: 0.0),
                    ),
                )
                continue
            }
            kept.add(chapter)
            starts.add(start)
        }
        this.chapters = kept
        chapterStarts = starts

        player.onTimeUpdate = { time ->
            if (time.isFinite()) {
                val candidate = manifest.startTime(trackIndex) + time
                // Belt as well as braces. The book clock is what the media
                // session publishes and what every skip is measured from, so
                // nothing non-finite may enter it — a single NaN latched here
                // and never cleared itself.
                if (candidate.isFinite()) {
                    bookTime = candidate
                    syncChapter(fromTick = true)
                }
            }
        }
        // Tracks are contiguous: the end of one is the start of the next, and a
        // listener should hear no seam at a chapter boundary.
        player.onFinishedFile = { scope.launch { advance() } }
    }

    val tracks: List<AudiobookManifest.Track> get() = manifest.playableTracks

    /**
     * Where the audiobook is, in terms the read-along engine can also act on.
     *
     * The other half of [AudioAnchor]'s bridge — see [ReadalongCoordinator]'s
     * property of the same name. A track and an offset into it, which is what
     * this engine natively knows and what the media overlay can be matched
     * against, so the two clocks never have to be converted by arithmetic.
     */
    val currentAnchor: AudioAnchor?
        get() {
            // Nothing has been loaded, so there is nowhere to name. `trackIndex`
            // is zero from birth and `bookTime` with it, so without this a
            // coordinator that never played a note answered "chunk one, offset
            // zero" — which is the ordinary outcome when the files source
            // refuses a chunk, and which `ListeningHandoff.Skip.NO_ANCHOR`'s own
            // doc already claims is impossible. `ReadalongCoordinator.currentAnchor`
            // makes that promise through `activeEntry`; this is the same promise,
            // through the one thing that says a file was actually opened.
            if (player.currentAudioHref == null) return null
            val all = tracks
            if (trackIndex !in all.indices) return null
            val start = manifest.startTime(trackIndex)
            // Derived from the book clock rather than read off the player, so it
            // agrees with whatever this coordinator last published — the
            // player's own time is per-item and briefly zero across a track
            // change.
            val within = bookTime - start
            if (!within.isFinite()) return null
            return AudioAnchor(all[trackIndex].href, within, Instant.now().toEpochSecondsDouble())
        }

    override val totalDuration: Double get() = manifest.totalDuration
    val isEmpty: Boolean get() = tracks.isEmpty()

    /** Fraction of the whole book, for a scrubber and for the saved position. */
    val progress: Double
        get() {
            if (!(totalDuration > 0) || !bookTime.isFinite()) return 0.0
            // An explicit gate, not incidental comparison semantics: Swift's
            // min/max return the other operand when a comparison with NaN is
            // false, so `min(max(NaN, 0), 1)` is NaN, not 0.
            return minOf(maxOf(bookTime / totalDuration, 0.0), 1.0)
        }

    override val bookProgress: Double get() = progress

    /**
     * The current chapter's extent on the book clock, cached against the
     * chapter index because a scrubber asks for this on every tick.
     */
    private var cachedChapterSpan: Pair<Int, ChapterSpan>? = null

    /**
     * The current chapter's extent on the book clock.
     *
     * The chapter, not the file it happens to start in: a scrubber scoped to
     * the chapter runs from one chapter marker to the next, and on a
     * synthesised manifest a chapter spans several chunks and begins inside
     * one. (This used to be a track span bridged through the interface, which
     * was honest only while a chapter and a track were the same thing — see
     * [AudiobookChapter].)
     */
    override val chapterSpan: ChapterSpan?
        get() {
            val index = chapterIndex
            if (index !in chapters.indices) return null
            cachedChapterSpan?.let { (cachedIndex, span) -> if (cachedIndex == index) return span }
            val start = chapterStarts[index]
            // The next chapter's start, or the end of the book for the last one.
            val end = if (index + 1 in chapterStarts.indices) chapterStarts[index + 1] else totalDuration
            val duration = end - start
            if (!(duration > 0)) return null
            val span = ChapterSpan(start, duration)
            cachedChapterSpan = index to span
            return span
        }

    val chapterTitle: String
        get() = if (chapterIndex in chapters.indices) chapters[chapterIndex].title else ""

    override val currentChapterTitle: String get() = chapterTitle

    /**
     * The chapter playing at a point on the book clock: the last one that starts
     * at or before it. Binary search, because a tick asks per second.
     */
    private fun chapterIndexAtBookTime(time: Double): Int {
        if (chapterStarts.isEmpty()) return 0
        var low = 0
        var high = chapterStarts.size - 1
        var result = 0
        while (low <= high) {
            val mid = (low + high) / 2
            if (chapterStarts[mid] <= time) {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }

    /**
     * Brings the announced chapter into line with the book clock.
     *
     * @param fromTick whether this came from the player's clock rather than from
     *   a load or a seek. **A tick may never move into a later file.** Every
     *   duration a media overlay can offer is an estimate — the last clip ends a
     *   beat before the file does — so a stated duration shorter than the real
     *   one leaves the clock running past the track boundary while that same
     *   file is still playing, and the listener would be told the next chapter
     *   had begun before a word of it was spoken. Only [advance] moves between
     *   files, so only [advance] may announce a chapter that lives in the next
     *   one.
     *
     *   It also decides whether the in-flight counters apply. They exist to
     *   ignore *the player's clock* while it is describing somewhere the
     *   listener is not — mid-load it describes neither the old file nor the new
     *   one, mid-seek neither where the listener was nor where they asked to go.
     *   The other caller is the thing that moved the clock, so there is nothing
     *   about it to disbelieve, and the guard used to swallow it: the second of
     *   two overlapping scrubs published nothing because the first was still
     *   counted, the clock crossed a chapter boundary with [chapterIndex] left
     *   behind, and the next honest sample read that as an advance and handed
     *   the sleep timer an "end of chapter" mid-burst.
     *
     *   The asymmetry is the safe direction. A suppressed steer leaves the
     *   chapter stale for a tick to misread as an ending; an extra steer during
     *   a load is one redundant media-session rebuild, which the landing load
     *   corrects a moment later — and this path can never reach
     *   [onChapterChangeObserved], so the sleep timer cannot hear it either way.
     */
    private fun syncChapter(fromTick: Boolean) {
        var index = chapterIndexAtBookTime(bookTime)
        if (fromTick) {
            if (loadsInFlight != 0 || seeksInFlight != 0) return
            while (index > 0 && chapters[index].trackIndex > trackIndex) index -= 1
        }
        if (index == chapterIndex) return
        val advanced = index > chapterIndex
        chapterIndex = index
        onChapterChange?.invoke(index)
        // A chapter that *ended* under the listener, which is the one thing the
        // sleep timer waits for. Going backwards is a scrub, not an ending.
        if (fromTick && advanced) onChapterChangeObserved?.invoke()
    }

    // Playback

    /**
     * Starts, or resumes, at a fraction of the whole book.
     *
     * Clears no steering latch on the way out. Nothing reachable from this
     * method has ever *set* the latch, so clearing one here could only destroy a
     * latch that a [playChapter] or [skip] running concurrently had set, which
     * turns a place the listener named into ordinary drift for the position
     * guard to second-guess. The contract it would stand in for — resuming is
     * the app choosing a place, not the listener — is kept by [seekToBookTime]
     * simply not latching, which is where it belongs.
     */
    suspend fun start(atProgress: Double = 0.0): MoveOutcome {
        // See ReadalongCoordinator: a NaN survived the inline clamp and was then
        // written back as a chosen position.
        val place = atProgress.asProgression ?: return MoveOutcome.UNPLAYABLE
        // Not `play()` regardless. With one file per track a missing chunk is a
        // real outcome — a half-deleted extraction, a book whose download went
        // while it sat paused — and calling play on a player holding nothing
        // leaves a book that claims to be playing in silence, which is what the
        // fifteen-second writer then persists progress against.
        //
        // `LANDED` and nothing else, so `SUPERSEDED` does not play either: the
        // newer load owns the player, and pressing play from here would start
        // audio at a place this call no longer has any say over.
        val outcome = seekToBookTime(totalDuration * place)
        if (outcome != MoveOutcome.LANDED) return outcome
        player.play()
        return outcome
    }

    /**
     * @return what became of it. See [MoveOutcome], and note that `SUPERSEDED`
     *   means the audio is fine and somewhere else, not that this book would
     *   not play.
     */
    suspend fun seekToBookTime(time: Double): MoveOutcome {
        val located = manifest.locate(time) ?: return MoveOutcome.UNPLAYABLE
        return seekToTrack(located.index, located.offset)
    }

    /**
     * The same move, for a caller that already knows the track and the offset
     * and has no reason to say it in book seconds first.
     *
     * A chapter is stored as a track and an offset into it — that is what
     * [AudiobookChapter] *is* — so restarting one by converting it to a book
     * time and asking `locate` to convert it back is a round trip through
     * arithmetic that can only lose. [playChapter] already addresses a chapter
     * this way; this is the same address for the branch that stays in the file
     * it is already playing.
     */
    private suspend fun seekToTrack(index: Int, requested: Double): MoveOutcome {
        // Never exactly onto the end of the book. `locate` answers a time at or
        // past the end with the last track at its full duration, so a skip in
        // the last half minute, a scrub to the far end of the bar, or resuming a
        // finished book all seeked onto the end of the file and restored the
        // rate. Whether the engine then reports the end is the one thing the
        // read-along declines to rely on — see its `END_OF_ENTRY_MARGIN` — and
        // this engine had no counterpart: without that report `advance()` never
        // runs and `isPlaying` stays true over a stopped player. Landing a hair
        // short lets the file play out and the book end the ordinary way.
        var offset = requested
        val lastDuration = if (index == tracks.size - 1) tracks[index].duration else null
        if (lastDuration != null) {
            offset = minOf(offset, maxOf(0.0, lastDuration - ReadalongCoordinator.END_OF_ENTRY_MARGIN))
        }
        if (index != trackIndex || player.currentAudioHref == null) {
            // `load` sets the clock and the chapter itself, and is the only one
            // of the two branches that can decline.
            return load(index, offset)
        }
        // Both BEFORE the suspension, for the reason `load` corrects its own
        // clock before one: the player's periodic observer keeps firing across
        // the seek, and a tick that lands mid-seek is answered against whatever
        // this coordinator has already published. Left until afterwards, the
        // post-seek time arrived while the chapter was still the pre-seek one,
        // so the tick — not the scrub — announced the crossing, `advanced` was
        // true, and a deliberate skip reached the sleep timer as "the chapter
        // ended" and paused the book mid-skip.
        bookTime = manifest.startTime(index) + offset
        // A scrub inside one file can still cross a chapter boundary — chunks
        // are cut by silence, chapters by the book — but crossing one this way
        // is the listener steering, not a chapter ending.
        syncChapter(fromTick = false)
        // And the clock ignored for the length of the seek, exactly as it is for
        // the length of a load. Belt as well as braces: the lines above answer
        // the sample that arrives holding the new time, this one the sample that
        // arrives still holding the old. Counted rather than flagged, because two
        // scrubs in a burst overlap and the second must not reopen the clock
        // while the first is still in flight.
        seeksInFlight += 1
        try {
            player.seek(offset)
            // Still inside the window: the engine has been asked and the counter
            // is not down yet, which is where a sample generated before the seek
            // arrives — the observer's cadence is a second, and a seek is not.
            // After the engine call rather than before it, because the
            // overlapping-scrub test issues its second seek from here and a drag
            // really does reach the player in that order.
            whileSeeking?.let { hook ->
                whileSeeking = null
                hook()
            }
        } finally {
            seeksInFlight -= 1
        }
        return MoveOutcome.LANDED
    }

    /**
     * Set when the listener steered, cleared when the answer is read.
     *
     * The fifteen-second position writer is a timer and cannot know a scrub
     * happened, so the coordinator — which owns every seek entry point —
     * records it instead. Deliberately not set by [start]: resuming a book is
     * the app choosing a place, not the listener.
     *
     * Set once the move has *landed*, never on the way in. Every entry point
     * below can decline after being asked — a chapter index the book does not
     * have, a files track whose chunk is missing, a clock with no duration
     * behind it — and a latch set first survives the refusal. The writer then
     * labels the next tick chosen, and the position guard's chosen branch
     * re-baselines the high-water mark to the candidate and clears its hold
     * unconditionally: a chapter tap that produced no audio released the hold
     * protecting a part-read novel and wrote roughly zero over it. Latching
     * afterwards costs at most one tick — a scrub that lands while the writer is
     * mid-flight is read as chosen fifteen seconds later instead of now — and
     * that is a delay, not a loss.
     *
     * `SUPERSEDED` does not latch it either, and that is right rather than an
     * oversight. The latch means "the position that is about to be persisted
     * was named by the listener" — and under supersession this call did not
     * determine that position at all. The load that overtook it did, and latches
     * for itself if whoever asked for it was the listener.
     */
    private var steeredAt = false

    /** Whether the listener has steered since this was last asked. */
    fun consumeSteering(): Boolean {
        val steered = steeredAt
        steeredAt = false
        return steered
    }

    /**
     * Latched only if the seek actually landed — see `steeredAt`. A
     * non-progression is refused a line below, and a refusal that still counted
     * as steering is a position the guard is not allowed to question.
     */
    suspend fun seekToProgress(progress: Double) {
        // See ReadalongCoordinator: a NaN survived the inline clamp and was then
        // written back as a chosen position.
        val place = progress.asProgression ?: return
        if (seekToBookTime(totalDuration * place) == MoveOutcome.LANDED) steeredAt = true
    }

    override suspend fun seekToBookProgress(progress: Double) {
        seekToProgress(progress)
    }

    /**
     * Latched after the load, not before it — see `steeredAt`. Both refusals
     * here are ordinary: the car's queue can outlive a chapter list that has
     * been rebuilt, and a files track whose chunk was deleted under a paused
     * book declines every time.
     */
    suspend fun playChapter(index: Int) {
        if (index !in chapters.indices) return
        val chapter = chapters[index]
        // Into the chapter's own start, which on a synthesised manifest is part
        // of the way into its chunk. Loading the track at zero would land the
        // listener at the end of the *previous* chapter.
        if (load(chapter.trackIndex, chapter.offset) != MoveOutcome.LANDED) return
        steeredAt = true
        player.play()
    }

    /**
     * Moves a whole chapter, or back to the start of this one.
     *
     * Restarting the current chapter when a few seconds in is what every audio
     * player does, and what a listener who taps "previous" by reflex means.
     */
    suspend fun nextChapter() {
        // Refuse at the end rather than clamp. `min` on the last track resolved
        // to the *current* track, restarting it at zero — and because
        // `playChapter` marks the move as steered, the position writer sent that
        // backwards jump to the server as chosen, the one origin the position
        // guard never refuses. The read-along's `moveChapter` already refuses at
        // the boundary; this is the same contract.
        if (chapterIndex + 1 !in chapters.indices) return
        playChapter(chapterIndex + 1)
    }

    /**
     * Latched by whichever branch lands — see `steeredAt`. The restart branch
     * reports for itself; the other delegates to [playChapter], which latches on
     * its own load.
     */
    suspend fun previousChapter() {
        if (chapterIndex !in chapterStarts.indices) return
        val start = chapterStarts[chapterIndex]
        // Measured against the chapter's start on the book clock, not against
        // the player's position in the file. A chapter that begins mid-chunk is
        // already several seconds into its file when it starts, so the player's
        // own clock would report "well into this chapter" the instant it began
        // and "previous" would restart a chapter nobody had heard yet.
        if (bookTime - start > 3) {
            // Addressed the way `playChapter` addresses one — the chapter's own
            // track and offset — rather than by handing its start back through
            // the book clock. `chapterStarts` is built from exactly that pair, so
            // the round trip could only ever agree with itself or lose.
            val chapter = chapters[chapterIndex]
            if (seekToTrack(chapter.trackIndex, chapter.offset) == MoveOutcome.LANDED) steeredAt = true
        } else {
            playChapter(maxOf(chapterIndex - 1, 0))
        }
    }

    /**
     * Skips within the book rather than within the file, so a skip near a
     * chapter boundary crosses it instead of stopping dead at the edge.
     *
     * Latched only once the seek lands — see `steeredAt`. A book with no
     * playable track at all reaches the lock screen anyway, because a start
     * that produced no audio leaves the coordinator installed, and its skip
     * button used to report a chosen position for a book holding nothing.
     */
    suspend fun skip(by: Double) {
        // Refuse rather than guess. With a non-finite clock the clamp below
        // collapsed to exactly 0, so both rewind and fast-forward threw the
        // listener back to the start of the book — and the position writer then
        // persisted that zero.
        if (!bookTime.isFinite() || !(totalDuration > 0)) return
        if (seekToBookTime(maxOf(0.0, minOf(bookTime + by, totalDuration))) == MoveOutcome.LANDED) {
            steeredAt = true
        }
    }

    /**
     * Applies a mapped control action, so the lock screen, headphones, the car
     * and steering-wheel buttons all funnel through one place.
     */
    override suspend fun perform(action: PlaybackAction, map: CommandMap) {
        when (action) {
            PlaybackAction.PLAY_PAUSE -> if (player.isPlaying) player.pause() else resume()
            PlaybackAction.SKIP_FORWARD -> skip(map.skipForwardInterval)
            PlaybackAction.SKIP_BACKWARD -> skip(-map.skipBackwardInterval)
            PlaybackAction.NEXT_CHAPTER -> nextChapter()
            PlaybackAction.PREVIOUS_CHAPTER -> previousChapter()
            // An audiobook has no sentence or paragraph structure to step
            // through, so those map to the nearest thing that exists rather than
            // doing nothing at all when a wheel button is pressed in the car.
            PlaybackAction.NEXT_SENTENCE, PlaybackAction.NEXT_PARAGRAPH -> skip(map.skipForwardInterval)
            PlaybackAction.PREVIOUS_SENTENCE, PlaybackAction.PREVIOUS_PARAGRAPH -> skip(-map.skipBackwardInterval)
            // Chosen, not merely set, so the speed is remembered — see
            // `AudioPlayer.choose`.
            PlaybackAction.SPEED_UP ->
                player.choose(PlaybackRate.clamped(player.rate.toDouble() + PlaybackRate.STEP).toFloat())
            PlaybackAction.SPEED_DOWN ->
                player.choose(PlaybackRate.clamped(player.rate.toDouble() - PlaybackRate.STEP).toFloat())
            // Discrete on purpose, never a toggle: the system sends these when
            // it has already decided which one it means, and its idea of the
            // state — the published rate — can lag `isPlaying` through a stall.
            PlaybackAction.PLAY -> resume()
            PlaybackAction.PAUSE -> player.pause()
            PlaybackAction.SLEEP_TIMER, PlaybackAction.NONE -> Unit
        }
    }

    /**
     * Carries on from where the book is: every remote "play".
     *
     * When the track the player holds would not play, the press reopens the
     * book's place rather than calling [AudioPlayer.play], which refuses a dead
     * item — a stream whose request failed can work a minute later, and a press
     * that only ever played over silence never found out.
     *
     * @return what became of the reopening, or null when there was nothing to
     *   reopen and the player was simply asked to play.
     */
    suspend fun resume(): MoveOutcome? {
        if (!player.itemHasFailed || trackIndex !in tracks.indices) {
            player.play()
            return null
        }
        val offset = maxOf(0.0, bookTime - manifest.startTime(trackIndex))
        val outcome = seekToTrack(trackIndex, if (offset.isFinite()) offset else 0.0)
        if (outcome == MoveOutcome.LANDED) player.play()
        return outcome
    }

    // Plumbing

    private suspend fun advance() {
        if (trackIndex + 1 >= tracks.size) {
            // The end of the book: stopped, and the audio route given back so
            // whatever the book interrupted can resume.
            player.endSession()
            return
        }
        val before = chapterIndex
        if (load(trackIndex + 1, 0.0) != MoveOutcome.LANDED) return
        // Only when the *chapter* changed, not whenever a file did. A book
        // synthesised over narration chunks crosses a file boundary every couple
        // of minutes and a chapter boundary every half hour; telling the sleep
        // timer that the first was the second ended the book at the next chunk,
        // which is nowhere a listener would have chosen to stop.
        if (chapterIndex != before) onChapterChangeObserved?.invoke()
        // Only if the boundary left it playing. An "end of chapter" sleep timer
        // pauses in the call above, and an unconditional play() here undid that
        // pause in the same turn, after the timer had already reset itself, so
        // the rest of the book played on into the night.
        if (!player.isPlaying) return
        player.play()
    }

    /**
     * @return which of the three things happened. See [MoveOutcome]: there is
     *   no audio here, or a newer load owns the state, or this one does — and
     *   the first two used to be the same word. A load a same-track scrub
     *   overtook has landed: its track is the one playing, and the place in it
     *   is the scrub's.
     */
    private suspend fun load(index: Int, offset: Double): MoveOutcome {
        if (index !in tracks.indices) return MoveOutcome.UNPLAYABLE
        val track = tracks[index]
        // Resolved before a single piece of state moves. A files track with no
        // file is a refusal, not a load, and the old order — index and clock
        // first, then find something to play — would have left the coordinator
        // claiming to be in a track it never reached, with the book clock and
        // every position written from it counting through silence.
        val destination: AudioLocation = when (source) {
            // Hrefs in the manifest are relative to the listen directory.
            is Source.Streaming -> {
                val url = source.base.toHttpUrlOrNull()?.newBuilder()?.addPathSegments(track.href)?.build()
                if (url == null) {
                    IssaLog.warning("audio track has no address", mapOf("href" to track.href, "track" to index.toString()))
                    player.pause()
                    return MoveOutcome.UNPLAYABLE
                }
                AudioLocation.Remote(url.toString(), source.headers)
            }
            is Source.Local -> AudioLocation.LocalFile(source.file)
            is Source.Files -> {
                val file = source.files[track.href]
                if (file == null) {
                    IssaLog.warning("audio chunk has no file", mapOf("href" to track.href, "track" to index.toString()))
                    player.pause()
                    return MoveOutcome.UNPLAYABLE
                }
                AudioLocation.LocalFile(file)
            }
        }

        // Where the book was, for a load that turns out to have nowhere to go:
        // see the `FAILED` case below.
        val beforeTrack = trackIndex
        val beforeTime = bookTime
        val beforeChapter = chapterIndex

        // All three of them together, and all three BEFORE the suspension. The
        // clock was already corrected here — a publish during the load used to
        // report the start of the target track and silently drop the offset —
        // but the chapter was left until afterwards, and for a streaming load
        // that is one or two seconds in which `chapterIndex` names a chapter the
        // book clock is no longer inside.
        //
        // Every reader of the pair assumes `chapterIndex ==
        // chapterIndexAtBookTime(bookTime)`, so all of them were wrong at once,
        // in different ways: `chapterSpan` measured the new book time against
        // the *old* chapter's start and handed the lock-screen chapter scrubber a
        // negative elapsed or one past the end; `chapterTitle` named the chapter
        // the listener had just left, and the car's queue highlighted that row;
        // and `nextChapter()` — which is `chapterIndex + 1` — sent a second tap
        // during the same load back to the chapter the first tap had already
        // reached.
        //
        // Assigning it here is safe rather than merely convenient: there is no
        // suspension between this and `loadsInFlight += 1`, so no tick can
        // interleave; `syncChapter`'s `index != chapterIndex` test is reached
        // only when that counter is zero; and `advance()` captures its `before`
        // *outside* this call, so it still compares against the pre-load
        // chapter.
        trackIndex = index
        bookTime = manifest.startTime(index) + offset
        chapterIndex = chapterIndexAtBookTime(bookTime)
        loadsInFlight += 1
        val outcome = try {
            // Inside the window and before the engine is asked, which is where
            // the lock screen samples: the track, the clock and the chapter have
            // moved and nothing has been announced yet.
            whileLoading?.let { hook ->
                whileLoading = null
                hook()
            }
            // One load at a time. Two interleaved loads left `trackIndex` and
            // `bookTime` set by whichever coroutine resumed last while the audio
            // came from whichever insert won, which is the one way the book clock
            // could genuinely disagree with the playing track.
            //
            // The player's own count says which load is the newest — every load
            // it sees comes from here, and nothing suspends between the
            // assignments above and its call — so this keeps no second count of
            // its own.
            player.load(destination, track.href, offset)
        } finally {
            loadsInFlight -= 1
        }
        when (outcome) {
            // A newer load started while this one was awaiting; it owns the
            // state.
            AudioPlayer.LoadOutcome.SUPERSEDED -> return MoveOutcome.SUPERSEDED
            AudioPlayer.LoadOutcome.FAILED -> {
                // The file is there by name and will not open: a chunk deleted
                // from disk, a stream whose request failed. The same refusal as a
                // track with no file at all, said in the one word that reaches a
                // listener — this used to come back `LANDED`, and the caller then
                // pressed play on silence.
                //
                // And the book put back where it was. The track, the clock and
                // the chapter moved before the suspension — they have to, see
                // above — and left there, the media session and the car named a
                // chapter with no audio in it, and the fifteen-second writer
                // persisted that place, with an anchor, for a file that never
                // loaded. Nothing has been announced yet, so there is nothing to
                // take back but the three. The player holds nothing now, so the
                // next play opens this place afresh — see `resume()`.
                trackIndex = beforeTrack
                bookTime = beforeTime
                chapterIndex = beforeChapter
                player.pause()
                return MoveOutcome.UNPLAYABLE
            }
            AudioPlayer.LoadOutcome.LOADED -> {
                // Restated rather than trusted: the player's periodic observer
                // writes `bookTime` on every tick without consulting the counter
                // — only the chapter announcement is gated — so a sample that
                // landed during the load has left the clock describing the file
                // being replaced.
                bookTime = manifest.startTime(index) + offset
                chapterIndex = chapterIndexAtBookTime(bookTime)
            }
            // A scrub inside this same track, made while it was opening, owns
            // the playhead: it took `seekToTrack`'s same-track branch, which set
            // the clock and the chapter itself, and the player has left the
            // audio where it put them. Restating them from this call's offset is
            // the write that used to throw the scrub away — the clock went back
            // to where the load began, and the player's own trailing seek took
            // the audio with it.
            AudioPlayer.LoadOutcome.OVERTAKEN -> Unit
        }
        // Announced late, and unconditionally, as every load has always
        // announced: the media session rebuilds from this and a reloaded track
        // is a new item there whether or not the chapter around it changed. The
        // assignment moved; the announcement did not, because announcing a
        // chapter the audio has not reached yet is what `loadsInFlight` exists to
        // prevent.
        onChapterChange?.invoke(chapterIndex)
        return MoveOutcome.LANDED
    }
}
