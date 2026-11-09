package com.benjaminissa.issareader.playback

import com.benjaminissa.issareader.core.diagnostics.IssaLog
import com.benjaminissa.issareader.core.model.AudioAnchor
import com.benjaminissa.issareader.core.model.asProgression
import com.benjaminissa.issareader.core.toEpochSecondsDouble
import com.benjaminissa.issareader.epub.SmilEntry
import com.benjaminissa.issareader.epub.SmilTimeline
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import java.io.File
import java.time.Instant

/**
 * Keeps narration and text in step.
 *
 * The audio clock is the source of truth. A periodic observer keeps the model
 * honest at a modest rate, and the view interpolates between observations, so
 * the highlight looks continuous without waking the CPU on every frame while
 * the screen is off.
 *
 * Main-thread-only, as the Swift type is `@MainActor`. [scope] runs the work an
 * end of file hops through; it must be a main-thread scope whose dispatcher
 * dispatches (`Dispatchers.Main`, not `Main.immediate`), because the hop is
 * part of the contract — see [advanceToNextFile].
 */
class ReadalongCoordinator(
    private val timeline: SmilTimeline,
    /** Archive href to the extracted file on disk. */
    private val audioFiles: Map<String, File>,
    override val player: AudioPlayer,
    private val scope: CoroutineScope,
) : Observed(), PlaybackDriving {
    var activeFragmentId: String? by observed(null)
        private set
    var activeEntry: SmilEntry? by observed(null)
        private set

    /** Progress through the whole book, 0…1, on the virtual gapless timeline. */
    override var bookProgress: Double by observed(0.0)
        private set

    /**
     * Called when the highlight moves to a fragment in a different chapter, so
     * the reader can load and turn to it.
     */
    var onChapterChange: ((String) -> Unit)? = null

    /**
     * A second, independent chapter-boundary hook.
     *
     * The reader owns [onChapterChange] to turn the page; the sleep timer needs
     * the same signal for "end of chapter" and must not have to fight it.
     */
    var onChapterChangeObserved: (() -> Unit)? = null

    /** Called whenever the highlighted fragment changes. */
    var onFragmentChange: ((String) -> Unit)? = null

    /**
     * Called when something other than the clock moved the playhead — a tapped
     * sentence, the scrubber, a skip, a chapter command.
     *
     * The reader uses it to tell a position the listener *chose* from one
     * narration merely wandered into. Notably [play] does not fire it: pressing
     * play asks for audio, it does not name a place, and when the app has to
     * work out where that is the guess must not be allowed to overwrite a
     * known-good position.
     *
     * Fired *after* the move, and only when something moved. Announcing the
     * seek first meant every early return behind it — the end of the book, a
     * missing audio file, a skip with no anchor yet — left the reader told of a
     * choice that never happened.
     */
    var onSeek: (() -> Unit)? = null

    /**
     * How many moves are between the highlight moving and the audio following
     * it.
     *
     * [AudiobookCoordinator]'s `loadsInFlight` and `seeksInFlight`, in the one
     * counter this engine needs. The player's periodic observer is attached to
     * the *engine*, not to the item, and neither a load nor a seek stops it
     * firing — so a sample lands in the middle of every deliberate move, and
     * [advance] answers it against a file the move has already changed. The
     * read-along needs no `fromTick` distinction to go with it: the clock
     * ([advance]) and the steer ([move]) are already two separate functions
     * here, and [advance] is scoped to the player's current file so it cannot
     * reach into another file at all.
     *
     * Counted rather than flagged, because two moves in a burst overlap and the
     * second must not reopen the clock while the first is still in flight.
     * Internal rather than private so a test can see the window it opens.
     */
    internal var movesInFlight = 0
        private set

    /**
     * How many times [clearPosition] has run.
     *
     * A move reads it before it starts and again when its audio has opened: a
     * clear that landed in between has taken the position back, and finishing
     * the move would put it straight back — and [play] would then press play
     * over a player with nothing in it. Counted rather than flagged, for the
     * reason [movesInFlight] is: a Stop followed at once by a new start must
     * not be mistaken, by the start it overtook, for its own.
     */
    private var clearances = 0

    init {
        player.onTimeUpdate = { time -> advance(time) }
        player.onFinishedFile = { scope.launch { advanceToNextFile() } }
    }

    val isEmpty: Boolean get() = timeline.isEmpty
    override val totalDuration: Double get() = timeline.totalDuration

    /**
     * Where the narration is, in terms the audiobook engine can also act on.
     *
     * This is the bridge between the two clocks — see [AudioAnchor]. The media
     * overlay already names the audio file and the offset within it for every
     * sentence, so the read-along can hand the audiobook an exact place rather
     * than a fraction of a different timeline.
     *
     * Anchored on the player's own clock rather than on [bookProgress], for the
     * reason [skipBook] gives: [bookProgress] is written by the periodic
     * observer and still reads zero in the first moments after a jump.
     *
     * Null before anything has played. A book with no anchor yet is exactly the
     * case the resume order exists to handle, and inventing one here would
     * defeat it.
     */
    val currentAnchor: AudioAnchor?
        get() {
            val entry = activeEntry ?: return null
            // The player's time is already an offset into the entry's file —
            // clip times restart per file — so it is the anchor's offset
            // directly. Clamped into the entry it belongs to: between clips the
            // clock can sit fractionally past the end.
            val time = player.currentTime
            if (!time.isFinite()) return null
            return AudioAnchor(
                audioHref = entry.audioHref,
                offset = minOf(maxOf(entry.start, time), entry.end),
                writtenAt = Instant.now().toEpochSecondsDouble(),
            )
        }

    // Clock

    /**
     * Maps the player's position within the current file onto a fragment.
     *
     * Scoped to the current file: clip times restart at zero in each track, so
     * a book-time search here would land on the wrong sentence.
     */
    private fun advance(time: Double) {
        // Mid-move the clock describes neither where the listener was nor where
        // they asked to go — and worse, it is read against a file the move has
        // already swapped, so a clock of zero from a freshly inserted item
        // resolves to the *first* sentence of the new chapter's audio rather
        // than to the one the listener asked for. Answering that dragged the
        // highlight off the destination, and, when the move crossed a document,
        // announced a chapter the listener had deliberately scrubbed into as
        // one that had *ended* — the listening layer hands that to
        // `SleepTimer.chapterDidEnd()`, and a read-along with a bedtime timer
        // paused itself mid-scrub.
        if (movesInFlight != 0) return
        val href = player.currentAudioHref ?: return
        val entry = timeline.entryInFile(href, time) ?: return

        // A sample a hair before the sentence the listener is already on
        // resolves to the sentence *before* it — the lookup is half-open — so a
        // clock that lands a fraction early would step the highlight back one,
        // and across a document boundary turn the page back and hand the sleep
        // timer a chapter that had not ended. The seek rounds up so this should
        // not arise; this is the second lock on the same door, because the cost
        // of being wrong is a book that pauses itself at bedtime.
        //
        // Only a hair: a deliberate move backwards is orders of magnitude larger
        // than this, and arrives through `move` rather than here.
        //
        // And only *before* the active sentence. A clock at or past its start is
        // not early, even when the entry it resolves to began earlier: in a run
        // the CTC aligner left out of order, the clip playing now can start
        // before the one that played last. v2's clips are ascending, where that
        // cannot happen, so for them this half changes nothing; without it, the
        // out-of-order answer was thrown away and the end of the file advanced
        // from the stale entry back into the same file.
        val active = activeEntry
        if (active != null && entry.start < active.start && time < active.start &&
            active.start - time < BACKWARDS_CLOCK_SLACK
        ) {
            return
        }

        // Two questions, which used to be one: has the *entry* changed, and has
        // the *fragment*? In a v2 book they are the same question. In a v3 book
        // one sentence owns several entries in a row — the audio-only holes
        // before and after it, the continuation of a sentence that runs into
        // the next file — and every one names the sentence's fragment. Asking
        // only about the fragment left `activeEntry` on the sentence while its
        // after-hole played, and everything that asks where the audio is reads
        // `activeEntry`: `currentAnchor` clamped the playhead back into the
        // sentence, `skipBook` measured from it, and a file that ended in the
        // hole advanced from the sentence, onto the hole, and replayed it for
        // ever.
        //
        // The highlight and the page still move on the fragment alone — as the
        // timeline scopes it, to its document. A hole names the sentence it
        // hangs off, which is what v2 lit for those same seconds, having folded
        // them into that sentence's clip; repainting it would change nothing
        // anybody can see, and the reader counts a fragment change as narration
        // arriving somewhere.
        if (entry != activeEntry) {
            val previousDocument = activeEntry?.textHref
            val fragmentMoved = entry.fragmentId != activeFragmentId || entry.textHref != previousDocument
            activeEntry = entry
            if (fragmentMoved) {
                activeFragmentId = entry.fragmentId
                onFragmentChange?.invoke(entry.fragmentId)
            }
            if (entry.textHref != previousDocument) {
                onChapterChange?.invoke(entry.textHref)
                // Only a real boundary, not the first fragment of a session.
                if (previousDocument != null) onChapterChangeObserved?.invoke()
            }
        }
        // Book progress uses the virtual timeline so it advances smoothly across
        // chapter and track boundaries.
        bookProgress = progression(entry, within = maxOf(0.0, time - entry.start))
    }

    /**
     * How far through the book a place [within] seconds into an entry is.
     *
     * The one answer to that question. The clock ([advance]), a move ([move])
     * and [readout] each worked it out with their own copy of the arithmetic,
     * and the last of those is what the player sheet shows before anything has
     * played — beside a position that, once narration starts, the other two
     * publish. A sheet that opened a rounding error away from where Play then
     * put the thumb would be a small lie told at the worst moment, so they
     * share this instead of agreeing by coincidence.
     */
    private fun progression(entry: SmilEntry, within: Double): Double =
        timeline.progressionAtBookTime(entry.cumulativeEnd - entry.duration + within)

    /** What [readout] answers: the book clock and the chapter bar for one sentence. */
    data class Readout(val bookProgress: Double, val chapterSpan: ChapterSpan?)

    /**
     * What the book clock and the chapter bar would read with the narration on
     * this sentence, without putting it there.
     *
     * For a surface that has to show where Play *would* begin before anything
     * has played — the player sheet opened on a read-along nobody has started,
     * which would otherwise draw the start of the book. Pure: it loads
     * nothing, cues nothing and leaves [activeEntry] where it is. Cueing the
     * player with [prepare] to read these numbers off it was the alternative,
     * and it leaves a position behind: the reader closes the sheet, reads on,
     * and Play resumes pages back.
     *
     * The same numbers [move] publishes for this entry at its start, and
     * [chapterSpan] reports once it is active, because it is the same code.
     */
    fun readout(at: SmilEntry): Readout = Readout(
        bookProgress = progression(at, within = 0.0),
        // The run the entry is actually in. A document the spine references
        // twice has two, and the merged range used to span both plus
        // everything between them.
        chapterSpan = timeline.spanOfDocumentContaining(at)?.let { ChapterSpan(it.start, it.duration) },
    )

    private suspend fun advanceToNextFile() {
        // An ending that arrives while a move is in flight is not one to act on:
        // the listener has already gone somewhere else. The ending reaches here
        // through the coroutine `init` launches it in, so a scrub or a tap whose
        // move starts before that coroutine runs has already put `activeEntry`
        // on its destination by the time it does. Answering it advanced from
        // *there*, past the rest of a file the listener had only just moved
        // into, and reported the chapter they moved into as ended. Nothing is
        // lost by dropping it: the move owns the playhead, and the file it lands
        // in posts its own ending when it runs out.
        //
        // The hop is the only window. A load replaces the engine's item before
        // it suspends, and the engine reports nothing more about the item it
        // replaced, so the player needs no guard of its own.
        if (movesInFlight != 0) return
        // The first entry of the next file, whatever it is — not the next
        // sentence. When a file runs out, what plays next is whatever audio the
        // book has next: a hole, the continuation of the sentence just heard,
        // or a whole audio chapter, which `entryAfter` would step over in
        // silence. Nor the next entry: in a file whose clips the aligner left
        // out of order, the entry playing at its end need not be its last, and
        // the entry after it was more of the same file — the advance seeked back
        // into it and the file ended, and seeked back, for ever. At the end of
        // the book there is nothing, and that is a pause, including when the
        // book ends on a hole.
        //
        // For a file whose clips ascend the two answers are the same, with one
        // exception: a last clip shorter than a tick of the screen-off clock,
        // where `activeEntry` is still the one before it. The next entry
        // replayed that sub-second clip once before moving on; the next file
        // does not, and the clip has already been heard.
        //
        // And not at all when there is no sentence to advance from. That is the
        // narration put back by [clearPosition] — a file that ended in the
        // moment before — and it is not the end of the book: it must neither
        // read as one nor give the audio route away.
        val entry = activeEntry ?: return
        val next = timeline.entryFollowingFileOf(entry)
        if (next == null) {
            // The end of the book: stopped, and the audio route given back so
            // whatever the narration interrupted can resume.
            player.endSession()
            return
        }
        val endedDocument = entry.textHref
        if (!move(next)) return
        // A chapter that ran out, which is what the end-of-chapter timer is
        // waiting for. `advance` cannot see this one: `move` has already set
        // `activeEntry`, so the clock's next tick finds its own boundary test
        // false. A book with one audio file per chapter therefore never
        // reported an ending at all, and a timer set at bedtime played through
        // the night.
        //
        // Announced from here rather than from inside `move`, which is what
        // keeps `movesInFlight` from swallowing the one ending that is real: the
        // counter is back to zero by the time `move` has returned, and the
        // document that ended was captured before it was called.
        if (endedDocument != next.textHref) onChapterChangeObserved?.invoke()
        // Only if the boundary left it playing — read *after* the callback,
        // exactly as `AudiobookCoordinator.advance()` reads it. An
        // end-of-chapter sleep timer pauses inside that callback, and the first
        // version of this guard latched `isPlaying` *before* `move`, so it then
        // called `play()` and undid the pause in the same turn, after the timer
        // had already reset itself — the book played on into the night, which is
        // the failure the callback above exists to stop.
        //
        // The same late read also covers what the early one was for: anything
        // that paused between the end of the file and here — the route handler
        // when headphones come out, an interruption — still reads as not
        // playing. `isPlaying` is the coordinator's intent, not the engine's
        // rate, and `load` preserves it, so a file boundary alone never clears
        // it.
        if (!player.isPlaying) return
        player.play()
    }

    // Seeking

    /**
     * Starts (or continues) playback at a specific narrated fragment.
     *
     * @return whether it moved there. False when the entry's audio file is
     *   missing, in which case nothing plays either.
     */
    suspend fun play(from: SmilEntry): Boolean {
        if (!move(from)) return false
        player.play()
        return true
    }

    /**
     * Positions the playhead and the highlight without making a sound.
     *
     * [play] minus the play, and deliberately not [seekToFragment]: this
     * announces nothing through [onSeek], because nobody named this place. It
     * exists for the hand-off back from the car — a driver who parked and
     * pressed pause wants the page they stopped on, in a quiet room, and a seek
     * would relabel that page as a position they *chose* and disarm the guard
     * that protects the real one.
     *
     * @return whether it moved there. False when the entry's audio file is
     *   missing, in which case nothing moved.
     */
    suspend fun prepare(at: SmilEntry): Boolean = move(at)

    /**
     * Puts the narration back to where it was before it first played.
     *
     * Paused, the file unloaded, and no sentence, highlight or progress: the
     * state of a coordinator nobody has pressed play on. "Stop Narration" in
     * the reader: after listening, the last sentence stays lit and
     * [activeEntry] stays put while the reader reads on, so Play resumes pages
     * back (and, following the narration, turns the page there).
     *
     * The file has to go as well as the entry. The player's clock fires on a
     * pause and on a seek as well as on playback, and [advance] re-derives
     * [activeEntry] from whichever file the player still holds, so a
     * coordinator that only forgot its entry had it back at the next tick.
     * With nothing loaded the clock has nothing to read, and the next [play]
     * opens its file afresh, as it does for any other move into a file the
     * player does not hold.
     *
     * Announces nothing: not [onFragmentChange], [onChapterChange] or
     * [onSeek]. Nobody named a place, and the reader that asked for this
     * clears its own copy of the highlight.
     */
    fun clearPosition() {
        clearances += 1
        player.unload()
        activeEntry = null
        activeFragmentId = null
        bookProgress = 0.0
    }

    /**
     * [play] for a place the listener named: the seek is announced once the
     * move has happened, and not at all if it did not.
     */
    private suspend fun jump(entry: SmilEntry) {
        if (play(entry)) onSeek?.invoke()
    }

    /**
     * Moves the playhead and the highlight without touching whether audio is
     * playing. False when the entry's audio file is missing and nothing moved,
     * or is there and would not open, in which case the highlight has moved and
     * the player has stopped.
     *
     * Split out of [play] because [seekToBookProgress] is an interface member
     * with a neutral contract — the audiobook implementation moves the playhead
     * and nothing else — and routing a lock-screen scrub through [play] made a
     * paused book start reading itself aloud in a quiet room, from the
     * scrubber, the skip buttons and the keyboard shortcuts alike.
     *
     * @param offset how far into the entry to land, for a scrub or a skip, which
     *   name a time rather than a sentence. Every other move lands at the
     *   entry's start. Clamped into the entry, and short of its very end by
     *   [END_OF_ENTRY_MARGIN].
     */
    private suspend fun move(entry: SmilEntry, offset: Double = 0.0): Boolean {
        // Resolved before a single piece of state moves, exactly as
        // `AudiobookCoordinator.load` resolves its own destination first: a
        // missing audio file is a refusal, not a move, and nothing may be
        // published for one — not the highlight, not the scrubber, not a page
        // turn. Null means the file is already loaded and only the playhead has
        // to travel.
        val destination: File? = if (player.currentAudioHref != entry.audioHref) {
            audioFiles[entry.audioHref] ?: return false
        } else {
            null
        }
        val within = if (offset.isFinite()) {
            minOf(maxOf(0.0, offset), maxOf(0.0, entry.duration - END_OF_ENTRY_MARGIN))
        } else {
            0.0
        }
        val clearancesAtStart = clearances

        // Everything published BEFORE the suspension, for the reason
        // `AudiobookCoordinator.seekToBookTime` publishes before its own: the
        // player's periodic observer keeps firing across a load and a seek
        // alike, and a sample landing in the middle is answered against
        // whatever this coordinator has already said. Left until afterwards,
        // the file had already been swapped while `activeEntry` still named the
        // old sentence, so `advance` resolved the new file's clock of zero to
        // its *first* sentence, announced that as a chapter the listener had
        // never reached, and — because the document had changed — reported it
        // as a chapter that *ended*. It also overwrote `activeEntry` before the
        // lines below read `previousDocument` off it, so the real page turn was
        // then skipped.
        val previousDocument = activeEntry?.textHref
        activeFragmentId = entry.fragmentId
        activeEntry = entry
        // Set here rather than left to the time observer: a paused player's
        // clock does not tick, so without this a paused scrub never reached the
        // scrubber or the lock screen.
        bookProgress = progression(entry, within)
        onFragmentChange?.invoke(entry.fragmentId)
        // The boundary, announced from the one funnel every seek, skip,
        // sentence, paragraph and chapter command passes through.
        //
        // `advance` cannot do it for these: this method sets `activeEntry`
        // before returning, so the clock's next tick finds its
        // `entry != activeEntry` test already false, and by the tick after that
        // `previousDocument` is the new document. A seek across a chapter
        // therefore fired `onChapterChange` *never* — not late — so the page did
        // not turn and `SleepTimer.chapterDidEnd()` was never called, and an
        // end-of-chapter timer set at bedtime played all night.
        //
        // `onChapterChange` only. **Not** `onChapterChangeObserved`: that one
        // means a chapter *ended*, and it drives the end-of-chapter sleep timer.
        // A seek, a skip, or a chapter picked from the list is not a chapter
        // ending — hanging the timer off the general signal is what used to stop
        // the book the moment a chapter was chosen. The natural end-of-file path
        // fires the other one, and only it.
        if (previousDocument != null && previousDocument != entry.textHref) {
            onChapterChange?.invoke(entry.textHref)
        }

        // And the clock ignored for the length of the move, exactly as the
        // audiobook engine ignores it for the length of a load or a seek. The
        // lines above answer the sample that arrives holding the new place; this
        // answers the one that arrives holding the old, which resolves against
        // the file already swapped underneath it.
        movesInFlight += 1
        try {
            if (destination != null) {
                // A later move into this same file, made while this load is
                // still opening it, takes the same-file branch below and owns the
                // playhead from then on: the player skips this load's trailing
                // seek rather than running it over the newer one, which is what
                // left the audio at the first target while the highlight named
                // the second. Nothing here needs undoing — this move published
                // before the suspension, and the newer one published after it.
                //
                // A file that will not open is a refusal, as a missing one is:
                // the player has already stopped, and saying `true` here sent
                // `play` on to press play over silence.
                val outcome = player.load(AudioLocation.LocalFile(destination), entry.audioHref, entry.start + within)
                if (outcome == AudioPlayer.LoadOutcome.FAILED) return false
            } else {
                // The same refusal for an item that turns out to be dead under
                // the seek: there is nowhere in it to land, and `true` here is
                // what sent `play` on to press play over it.
                player.seek(entry.start + within)
                if (player.itemHasFailed) return false
            }
            // A position taken back while the audio was opening is a move that
            // did not happen. [clearPosition] has already emptied the player,
            // which is why the load above came back superseded rather than
            // failed, and the caller's `true` would press play over nothing.
            return clearancesAtStart == clearances
        } finally {
            movesInFlight -= 1
        }
    }

    /**
     * Carries on from where the narration is: the play button, and every
     * remote "play".
     *
     * When the file the player holds would not play, the press is a retry — the
     * file is opened again at the sentence the narration is on — rather than
     * [AudioPlayer.play], which refuses a dead item. Nothing else stood that
     * item down: the player had stopped once, when it failed, and every later
     * press played over it.
     *
     * With no sentence there is nothing to carry on from: nothing has been
     * loaded yet, or [clearPosition] unloaded it. [AudioPlayer.play] would
     * still claim the audio route and call that playing, so the transport drew
     * Pause over silence. Where to begin is the caller's to choose; the reader
     * starts from its page.
     *
     * @return whether the narration is playing now. False when the file still
     *   will not open, which the caller can tell the reader, and when there is
     *   no sentence to carry on from.
     */
    suspend fun resume(): Boolean {
        val entry = activeEntry
        if (entry == null) {
            IssaLog.info("resume refused: the narration has no place yet", emptyMap())
            return false
        }
        if (player.itemHasFailed) return play(entry)
        player.play()
        return player.isPlaying
    }

    /**
     * Plays from a fragment named by id alone, falling back to the first chapter
     * that uses it. Best effort; a caller that knows which document the id came
     * from uses the overload that takes one.
     */
    suspend fun seekToFragment(fragmentId: String) {
        val entry = timeline.entryForFragment(fragmentId) ?: return
        jump(entry)
    }

    /**
     * Plays from a fragment in exactly this document, or does nothing.
     *
     * Ids are unique per document, not per book, and only Storyteller's aligner
     * happens to prefix them. Resolved by id alone, a tap in chapter twelve of a
     * book that numbers its sentences per chapter played chapter one, and turned
     * the page there. [document] is the archive path the timeline uses — the
     * reader's spine href.
     */
    suspend fun seekToFragment(fragmentId: String, document: String) {
        val entry = timeline.exactEntryForFragment(fragmentId, document) ?: return
        jump(entry)
    }

    /**
     * Skips within the BOOK, not within the current audio file.
     *
     * [AudioPlayer.skip] moves the playhead inside whichever file is loaded and
     * clamps at that file's zero, so a fifteen-second rewind five seconds into a
     * file landed at the start of the file rather than ten seconds earlier in
     * the book — while the elapsed time published to the lock screen was
     * book-wide. The audiobook coordinator already worked this way; this is the
     * same contract for narration.
     */
    suspend fun skipBook(by: Double) {
        val total = totalDuration
        if (!(total > 0)) return
        // Refuse rather than guess when narration has never played: the
        // coordinator is built eagerly on open and the reader footer draws the
        // skip buttons regardless, so with no anchor a skip resolved to sentence
        // one of the whole book — a third of a novel away from the reader. The
        // same contract as the audiobook's skip from a broken clock.
        val entry = activeEntry ?: return
        // Anchored to the active entry and the player's own clock, not to
        // `bookProgress`: that field is written only by the periodic observer,
        // so in the first moments after `play` it still reads 0.
        val within = minOf(maxOf(0.0, player.currentTime - entry.start), entry.duration)
        val current = entry.cumulativeEnd - entry.duration + within
        if (!current.isFinite()) return
        seekToBookProgress(maxOf(0.0, minOf(current + by, total)) / total)
    }

    /**
     * Seeks by fraction of the whole book, for a scrubber, and for [skipBook] —
     * to the time that fraction names, not to the start of the entry it falls
     * in.
     *
     * The entry says which file and which fragment; how far into it the time
     * falls is the other half of the place, and it used to be thrown away, so
     * every scrub and skip landed at the start of the containing entry. On a v2
     * book that is a sentence, a few seconds early. On a v3 book a hole or an
     * audio chapter is one entry minutes long: a scrub anywhere inside it went
     * back to its start, a thirty-second skip forward from its middle went
     * *backwards* — and every skip after it back to the same place — and the
     * reader saved that start as a position the listener had chosen.
     */
    override suspend fun seekToBookProgress(progress: Double) {
        // A non-finite progress is not a place in the book. Refusing it is the
        // point: the inline clamp let NaN through, `totalDuration * NaN` is NaN,
        // and the seek that followed was announced, so the position writer
        // persisted the result as a listener-*chosen* position — the one origin
        // the position guard may not refuse.
        val place = progress.asProgression ?: return
        val time = timeline.totalDuration * place
        val entry = timeline.entryAtBookTime(time) ?: return
        // Past the entry's end only at the end of the book, where the lookup
        // answers the last entry; `move` clamps it back.
        val within = time - (entry.cumulativeEnd - entry.duration)
        // A seek is not a play button: it lands paused when paused, playing when
        // playing, exactly as the audiobook implementation of this same member
        // always has.
        if (move(entry, within)) onSeek?.invoke()
    }

    // Actions

    /**
     * Applies a mapped control action. This is the single funnel every surface
     * goes through — screen, lock screen, headphones, the car and the wheel —
     * so a remapping applies everywhere at once.
     */
    override suspend fun perform(action: PlaybackAction, map: CommandMap) {
        // Navigation names a place; playing, speed and the sleep timer do not.
        // Each navigation route announces its own seek, after it has moved.
        when (action) {
            PlaybackAction.PLAY_PAUSE -> if (player.isPlaying) player.pause() else resume()
            PlaybackAction.SKIP_FORWARD -> skipBook(map.skipForwardInterval)
            PlaybackAction.SKIP_BACKWARD -> skipBook(-map.skipBackwardInterval)
            PlaybackAction.NEXT_SENTENCE -> {
                val next = activeEntry?.let { timeline.entryAfter(it) }
                if (next != null) jump(next)
            }
            PlaybackAction.PREVIOUS_SENTENCE -> {
                val previous = activeEntry?.let { timeline.entryBefore(it) }
                if (previous != null) jump(previous)
            }
            PlaybackAction.NEXT_PARAGRAPH -> moveParagraph(forward = true)
            PlaybackAction.PREVIOUS_PARAGRAPH -> moveParagraph(forward = false)
            PlaybackAction.NEXT_CHAPTER -> moveChapter(forward = true)
            PlaybackAction.PREVIOUS_CHAPTER -> moveChapter(forward = false)
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

    private suspend fun moveParagraph(forward: Boolean) {
        var entry = activeEntry ?: return
        for (step in 0 until SENTENCES_PER_PARAGRAPH) {
            entry = (if (forward) timeline.entryAfter(entry) else timeline.entryBefore(entry)) ?: break
        }
        jump(entry)
    }

    /**
     * From the run of the document the listener is in, to the start of the run
     * beside it — refused at either end of the book.
     *
     * By run, not by document name: a document the timeline visits twice is two
     * places, and looking it up by name found its first visit, so "next" from
     * the second visit went backwards and "previous" from it was refused.
     */
    private suspend fun moveChapter(forward: Boolean) {
        val current = activeEntry ?: return
        val entry = timeline.firstEntryOfRunAdjacentTo(current, forward) ?: return
        jump(entry)
    }

    // PlaybackDriving

    /**
     * A readaloud's chapter name lives in the book's navigation document, not in
     * the timeline, so the reader supplies it; the timeline knows only which
     * text document is playing.
     */
    override val currentChapterTitle: String get() = activeEntry?.textHref ?: ""

    /**
     * The current text document's extent on the virtual book timeline: the run
     * the listener is actually in. A document the spine references twice has
     * two, and a merged range used to span both plus everything between them.
     */
    override val chapterSpan: ChapterSpan?
        get() = activeEntry?.let { readout(it).chapterSpan }

    companion object {
        /**
         * How far before the active sentence a sample may fall and still be
         * read as clock jitter rather than as a move. One frame of the player's
         * 1/600 s timescale is 1.7 ms; twenty is far below the smallest
         * deliberate skip and far above any rounding.
         */
        const val BACKWARDS_CLOCK_SLACK: Double = 0.02

        /**
         * How far short of an entry's end a move into it may land.
         *
         * A scrub to the far end of the bar names the very end of the last
         * entry, which is the end of its file. A seek that lands exactly on an
         * item's end may never be told it played to the end, and without that
         * report `isPlaying` stays true over a player that has stopped — the
         * failure `AudioPlayer.load` guards against for an offset of zero.
         * Landing a hair short lets the file play out and the book end the
         * ordinary way.
         *
         * Two frames of the player's 1/600 s timescale rather than one, because
         * `AudioPlayer.seek` rounds its target *up* to the next frame: a target
         * one frame short of an end that sits on a frame boundary comes back up
         * onto it about one time in fifty.
         */
        const val END_OF_ENTRY_MARGIN: Double = 2.0 / 600

        /**
         * A paragraph boundary is approximated by a run of sentences: the
         * aligner numbers sentences per chapter, so stepping several sentences
         * is the closest reliable equivalent without re-parsing the source
         * markup.
         */
        private const val SENTENCES_PER_PARAGRAPH = 3
    }
}
