package com.benjaminissa.issareader.playback

import com.benjaminissa.issareader.core.diagnostics.IssaLog
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import java.util.IdentityHashMap
import kotlin.math.ceil

/**
 * Plays a book's narration.
 *
 * Swift's `AudioPlayer` over `AVQueuePlayer`, here over a [MediaBackend] — on
 * Android, Media3's ExoPlayer. The engine handles HTTP range requests, exact
 * seeking and pitch-preserving rate changes; everything this class adds is
 * about *who owns what*: which call owns the item and which the playhead, what
 * a file that will not open does to both, and when the engine may start.
 *
 * Main-thread-only, as the Swift type is `@MainActor`. Owns the backend it is
 * given, and frees it in [release].
 */
class AudioPlayer(private val backend: MediaBackend) : Observed() {
    var isPlaying: Boolean by observed(false)
        private set

    /** Seconds into the currently loaded audio file. */
    var currentTime: Double by observed(0.0)
        private set

    var duration: Double by observed(0.0)
        private set

    var currentAudioHref: String? by observed(null)
        private set

    /**
     * 0…1, used by the sleep timer's fade-out.
     *
     * The fade owns this number outright — the listening layer hands the timer
     * a function that writes it every tick — so the per-book level cannot live
     * here as well. It goes through [gain] instead, and the two are combined in
     * [applyPlayerVolume].
     */
    var volume: Float = 1f
        set(value) {
            field = value
            changed()
            applyPlayerVolume()
        }

    /**
     * This book's level, as a multiplier of the recorded one.
     *
     * Separate from [volume] because it must be able to exceed 1, which the
     * engine's own volume cannot: a quietly mastered book needs *more* than the
     * file has, and that gain can only come from the samples themselves. The
     * value is pushed into the gain stage here so the audio thread never has to
     * ask this object for it. Clamped on the way in.
     */
    var gain: Float = 1f
        set(value) {
            val legal = VolumeTrim.clampedGain(value)
            field = legal
            changed()
            backend.gain = legal
            applyPlayerVolume()
        }

    /**
     * What the engine is actually set to, for tests. The interesting cases are
     * the ones where it is *not* [volume]: an item with no gain stage, where
     * the quieter half of the trim is carried here.
     */
    internal val underlyingVolume: Float get() = backend.volume

    /**
     * Whether the loaded item's audio genuinely runs through the gain stage.
     *
     * False for anything whose tracks could not be loaded, and the fallback in
     * [applyPlayerVolume] depends on it. **Null until something has been loaded
     * to ask about**, which is a different answer from "no": a player that has
     * not reached [load] yet is not a book that cannot be made louder, and a
     * screen that read the two as one would caption every book for the moment
     * before its first track resolves.
     *
     * Public because it is the only signal a reader has. Without the gain stage
     * [applyPlayerVolume] can only go *down*, so a book set louder plays at "as
     * recorded" with nothing on screen to say why. The volume-trim row reads it
     * and says so. (The name is Swift's, where the gain stage is an
     * `MTAudioProcessingTap`.)
     */
    var tapCarriesGain: Boolean? by observed(null)
        private set

    /**
     * The two levels, resolved into the one number the engine accepts.
     *
     * With the gain stage carrying the item the gain is already in the samples,
     * so the fade multiplies it rather than replacing it. Without it the
     * engine's own volume is all there is: `min(gain, 1)` still delivers
     * "quieter", and "louder" degrades to as-recorded rather than to a value
     * the engine would clip anyway. Nothing loaded yet takes the same branch,
     * because there is no gain stage either way.
     */
    private fun applyPlayerVolume() {
        backend.volume = if (tapCarriesGain == true) volume else volume * minOf(gain, 1f)
    }

    var rate: Float = 1f
        set(value) {
            field = value
            changed()
            // Stopping is always safe; starting waits while a load is still
            // placing its item — see `placementPending`, and the placement
            // restores whatever `rate` is by then.
            if (!isPlaying) {
                backend.rate = 0f
            } else if (!placementPending) {
                backend.rate = value
            }
            // The effective rate, not the requested one. Observers treat a
            // non-zero rate as "playing" — the widget publishes `isPlaying` from
            // exactly this number — so choosing 1.5× on a paused book must not
            // announce that it started.
            notifyRateObservers(if (isPlaying) value else 0f)
        }

    /**
     * The rate audio is genuinely playing at, as opposed to the one we asked
     * for. [isPlaying] is a hand-maintained flag and stays true through a
     * buffering stall, so publishing it as the now-playing rate told the system
     * to keep advancing a clock that had stopped.
     */
    val effectiveRate: Float get() = if (backend.isPlaying) backend.rate else 0f

    /**
     * Called on every observed time update, so a coordinator can advance the
     * read-along highlight without polling.
     */
    var onTimeUpdate: ((Double) -> Unit)? = null

    /**
     * Everything that wants to know the rate moved.
     *
     * A map, not one function. Two things genuinely need this — the lock
     * screen, so a play tap is not stale, and the widget, so a paused book stops
     * claiming to be playing — and a single slot meant whichever attached
     * second silently replaced the first.
     */
    private val rateObservers = IdentityHashMap<Any, (Float) -> Unit>()

    /**
     * Registers an observer against an owner.
     *
     * Keyed rather than appended: the listening layer attaches every time the
     * reader appears, and appending meant one play tap eventually performed a
     * dozen now-playing rebuilds, with every function retained for the life of
     * the player. Registering twice for the same owner replaces, which is what
     * the call sites have always assumed.
     */
    fun setRateObserver(owner: Any, observer: (Float) -> Unit) {
        rateObservers[owner] = observer
    }

    /** Drops every observer, for a coordinator being torn down. */
    fun removeRateObservers() {
        rateObservers.clear()
    }

    private fun notifyRateObservers(rate: Float) {
        for (observer in rateObservers.values.toList()) observer(rate)
    }

    var onFinishedFile: (() -> Unit)? = null

    /**
     * Called when the system interrupts playback and again when it is safe to
     * resume, so the app can decide rather than guess.
     */
    var onInterruption: ((Boolean) -> Unit)? = null

    /** Called when headphones are unplugged or a Bluetooth device disappears. */
    var onRouteLoss: (() -> Unit)? = null

    init {
        backend.configureSession()
        observeSession()
        observeTime(IDLE_OBSERVATION_INTERVAL)
    }

    /** Stops observing, and frees the engine. */
    fun release() {
        backend.setTimeObserver(IDLE_OBSERVATION_INTERVAL, null)
        backend.sessionListener = null
        backend.release()
    }

    /**
     * Stops, and gives the audio route back so whatever this interrupted can
     * carry on.
     *
     * For the ends of listening — the book running out, the sleep timer
     * expiring — and for nothing else. Taking the route stopped the listener's
     * music, and nothing ever gave it back, so the app that was interrupted was
     * never told it may resume. An ordinary pause keeps the route, as the
     * platform's own players do, and the hand-off from the car to the reader
     * must too — the book is still being listened to there.
     */
    fun endSession() {
        pause()
        sessionsEnded += 1
        backend.deactivateSession()
    }

    /** How many times [endSession] has run, for tests. */
    internal var sessionsEnded = 0
        private set

    /**
     * Called when a rate is *chosen* through [choose] — a bound speed control —
     * so it can be remembered as the listener's speed.
     */
    var onRateChosen: ((Float) -> Unit)? = null

    /**
     * Sets the rate as the listener's own choice.
     *
     * [rate] is also written by things that are not a choice — restoring the
     * saved speed when a book opens, the hand-off carrying it across — so
     * persisting from [rate]'s setter would write back what was just read. The
     * bound speed-up and speed-down actions used to set [rate] and nothing
     * else, so a speed picked from a steering-wheel or headphone button was lost
     * at the next book, the next launch, and the car-to-reader hand-off.
     */
    fun choose(rate: Float) {
        this.rate = rate
        onRateChosen?.invoke(this.rate)
    }

    /**
     * Handles the two things that stop audio without the app asking.
     *
     * A phone call interrupts; the system says when it is over and whether it
     * expects playback to resume. Unplugging headphones is a route change, and
     * the convention — which every audio app is judged against — is to pause
     * rather than start playing a book out loud in a quiet room.
     */
    private fun observeSession() {
        backend.sessionListener = object : MediaBackend.SessionListener {
            override fun onInterruptionBegan() {
                // Latched *after* the pause, not before: `pause()` clears it,
                // because an explicit pause during an interruption must not be
                // undone when the interruption ends. Setting it first would have
                // this pause wipe the very flag it is recording.
                val wasPlaying = isPlaying
                pause()
                wasPlayingBeforeInterruption = wasPlaying
                onInterruption?.invoke(false)
            }

            override fun onInterruptionEnded(shouldResume: Boolean) {
                val resume = shouldResume && wasPlayingBeforeInterruption
                // Spent, either way. Without clearing it a second end with no
                // intervening beginning — which the system does deliver —
                // resumed a book the listener had stopped.
                wasPlayingBeforeInterruption = false
                if (resume) {
                    backend.activateSession()
                    play()
                }
                onInterruption?.invoke(resume)
            }

            override fun onRouteLost() {
                pause()
                onRouteLoss?.invoke()
            }
        }
    }

    /**
     * Whether the interruption arrived mid-playback, so a resume is only offered
     * to someone who was actually listening.
     */
    private var wasPlayingBeforeInterruption = false

    /**
     * Switches observation cadence. Called when the reader appears and
     * disappears, so a screen-off listening session costs a fraction of the
     * wakeups an always-fine observer would.
     */
    fun setHighFrequencyUpdates(enabled: Boolean) {
        observeTime(if (enabled) ACTIVE_OBSERVATION_INTERVAL else IDLE_OBSERVATION_INTERVAL)
    }

    private fun observeTime(interval: Double) {
        backend.setTimeObserver(interval) { seconds ->
            // A time is not always a number. The observer is attached to the
            // engine, not the item, and it keeps firing across a track change —
            // at which point there is no current item and the engine's time is
            // NaN. Forwarding that poisoned the book clock: it survived every
            // downstream clamp, was published to the lock screen as a
            // non-finite elapsed, and made a skip seek to zero.
            if (!seconds.isFinite()) return@setTimeObserver
            currentTime = seconds
            onTimeUpdate?.invoke(seconds)
        }
    }

    /**
     * What became of a [load], which decides what its caller may write.
     *
     * A `Boolean` said only whether a later *load* had replaced this one. It
     * could not say that a later *seek* had taken the playhead — a scrub into
     * the file this load was still opening — so the load went on to run its own
     * trailing seek over the newer one, and [AudiobookCoordinator] then restated
     * its clock from the load's offset: the audio and the clock both ended up
     * where the listener had just left.
     */
    enum class LoadOutcome {
        /** The item is this call's, and the playhead is where it asked. */
        LOADED,

        /**
         * The item is this call's, but a seek made while it was opening owns the
         * playhead. The load ran no trailing seek and left the rate to that seek.
         * Nothing is wrong with the audio; a caller must simply not restate a
         * clock from this call's offset.
         */
        OVERTAKEN,

        /**
         * A later load replaced the item while this one was awaiting the
         * engine, and owns everything now.
         */
        SUPERSEDED,

        /**
         * The file would not open: its duration could not be loaded. The player
         * has paused, so nothing claims to be playing over silence.
         *
         * A missing file, a chunk deleted from disk under a paused book, a
         * streamed track whose request failed or whose token expired. Every one
         * of these used to come back as success, with [isPlaying] left true and
         * every surface drawing a pause glyph over silence while the sleep timer
         * counted down.
         */
        FAILED,
    }

    /**
     * Loads an audio file, local or streamed, and says what became of it.
     *
     * Readaloud audio lives inside the EPUB, so the caller extracts it first;
     * this never sees the archive. A streamed audiobook track instead needs
     * credentials, and [AudioLocation.Remote]'s headers are how they travel.
     *
     * The guards live here rather than only in [AudiobookCoordinator], where
     * one sat *after* the damage: everything past the suspension below writes
     * player state, so two overlapping loads — a scrub racing an end-of-track
     * advance, two remote commands in a burst — left [duration] describing one
     * file while the engine held another, and seeked the new item to the old
     * one's clip time. Two guards, because two things can overtake a load: a
     * later load takes the item (`itemGeneration`), and a later seek takes only
     * the playhead (`playheadGeneration`).
     */
    suspend fun load(location: AudioLocation, href: String, startAt: Double = 0.0): LoadOutcome {
        itemGeneration += 1
        playheadGeneration += 1
        val item = itemGeneration
        val playhead = playheadGeneration
        // Until this load or a seek that overtakes it has put the playhead
        // where it belongs, nothing may start the engine — see
        // `placementPending`.
        placementPending = true
        currentAudioHref = href
        // The clock belongs to the file being replaced. Left alone it kept
        // reporting the previous file's position until the periodic observer
        // next fired — up to a second with the screen off, which is exactly when
        // `previousChapter` reads it to decide between "restart this chapter"
        // and "go back one".
        currentTime = 0.0

        // Stopped explicitly before the item changes hands, rather than trusting
        // the engine to drop its rate when it empties: the new item must not
        // start until it has been placed — see `placementPending`.
        backend.rate = 0f
        // A seek still waiting on the outgoing item is released before the item
        // goes. A seek pending on an item that has failed is never called back,
        // and removing the item does not change that — the coordinator's
        // in-flight counter around it would never come down, and the clock would
        // be ignored for the rest of the session.
        backend.cancelPendingSeeks()
        val playerItem = backend.replaceItem(
            location,
            object : MediaBackend.ItemListener {
                override fun onPlayedToEnd() {
                    if (item == itemGeneration) onFinishedFile?.invoke()
                }

                // The two ways an item says it has stopped for good rather than
                // reached its end: it never became playable, or it stopped
                // part-way — a stream that lost its network, a file that went
                // from under it.
                override fun onFailed(reason: String) {
                    itemDidFail(item, reason)
                }
            },
        )
        // Both asked for at once: the tracks are wanted for the gain stage, and
        // asking for them one after the other would be a second round trip on
        // every streamed track — and a second window in which a later `load`
        // could overtake this one. Both requests are in flight before either is
        // awaited, so this stays one window, and the generations are checked
        // once both answers are in.
        //
        // Two of them rather than one combined load, though, because that form
        // is all-or-nothing: a track list that will not load nulled the
        // *duration* along with it, so the scrubber lost its length, "…m left"
        // disappeared, and the end-of-track arithmetic ran against zero for an
        // asset whose duration had resolved perfectly well. Caught one at a
        // time, a track failure costs the gain stage and nothing else.
        var failure: Throwable? = null
        var loadedDuration: Double? = null
        var loadedCarriesGain: Boolean? = null
        coroutineScope {
            val loadingDuration = async { runCatching { playerItem.loadDuration() } }
            val loadingTracks = async { runCatching { playerItem.loadCarriesGain() } }
            whileLoadingAsset?.let { hook ->
                whileLoadingAsset = null
                hook()
            }
            loadingDuration.await().fold({ loadedDuration = it }, { failure = it })
            loadedCarriesGain = loadingTracks.await().getOrNull()
        }
        if (item != itemGeneration) return LoadOutcome.SUPERSEDED
        // Item-scoped, so written even when a seek has since taken the playhead:
        // the item is still this load's, and these describe it.
        //
        // A stream with an indefinite duration reports NaN or infinity, which
        // is no length.
        val seconds = loadedDuration ?: 0.0
        duration = if (seconds.isFinite()) seconds else 0.0
        // Before the seek and the rate restore, so the first sample this item
        // plays is already at the book's level. Every read-along file and every
        // audiobook track passes through here, which is why a chapter change
        // needs no separate hook.
        tapCarriesGain = loadedCarriesGain == true
        applyPlayerVolume()
        // A file that will not open is not a place to be. Stopped here, before
        // anything is told it landed: `isPlaying` is what the transport, the
        // sleep timer and the widget all read.
        failure?.let {
            itemDidFail(item, it.toString())
            return LoadOutcome.FAILED
        }
        // Playhead-scoped from here on. A seek made while this load was opening
        // its file — a scrub, the next sentence tapped, a held remote button —
        // has already put the playhead where the listener asked, and restored
        // the rate; seeking back to this load's own offset now is the write that
        // lost it.
        // The item can also fail without its duration throwing: the failure
        // listener stands it down, and nothing past here can place it.
        if (failedItem == item) return LoadOutcome.FAILED
        if (playhead != playheadGeneration) return LoadOutcome.OVERTAKEN
        if (startAt > 0) {
            beforeTrailingSeek?.invoke()
            if (!seekPlayhead(startAt, playhead)) {
                if (item != itemGeneration) return LoadOutcome.SUPERSEDED
                return if (failedItem == item) LoadOutcome.FAILED else LoadOutcome.OVERTAKEN
            }
        } else {
            // Replacing the item drops the engine's rate to 0, and a seek is the
            // other path that restores it. An offset of exactly 0 — a scrub back
            // to the start of the book — has no seek, and skipping the restore
            // left the audio silent while `isPlaying` stayed true, so the
            // transport drew a pause glyph over a stopped player.
            placementPending = false
            if (isPlaying) backend.rate = rate
        }
        // Asked once more on the way out, because both ways an item says it
        // failed can arrive while it is being placed. A failure that lands while
        // the trailing seek is pending releases the seek without taking the
        // playhead from it, so the seek came back owning the playhead and this
        // said `LOADED` for a dead item — and its caller pressed play over it.
        if (playerItem.hasFailed) itemDidFail(item, playerItem.failureReason ?: "unknown")
        if (failedItem == item) return LoadOutcome.FAILED
        return LoadOutcome.LOADED
    }

    /**
     * Takes the loaded file out of the player, leaving it paused and empty.
     *
     * [load] with nothing to load: for a coordinator that is putting its
     * position back to the start, which has to stop the player describing a
     * file. The periodic clock fires on a pause and on a seek as well as on
     * playback, so while [currentAudioHref] names a file, every tick is a
     * question a coordinator can answer with a sentence in it. Cleared, the
     * clock has nothing to resolve against.
     *
     * Both generations are bumped, so a [load] still opening its file comes
     * back `SUPERSEDED` and a seek still landing returns without writing the
     * clock or the rate, exactly as if a newer load had replaced them. The
     * rate the listener chose, and the level, are untouched: they belong to
     * the player, not to the file.
     *
     * The next [load] is a new item and plays, as after any other.
     */
    fun unload() {
        pause()
        itemGeneration += 1
        playheadGeneration += 1
        placementPending = false
        // The item's listener goes with it, and an ending or a failure that
        // item had already queued goes with it too — see
        // `ReadalongCoordinator.advanceToNextFile`.
        backend.cancelPendingSeeks()
        backend.clearItem()
        currentAudioHref = null
        currentTime = 0.0
        duration = 0.0
    }

    /**
     * Bumped by every [load] and by [unload]. Guards what belongs to the
     * *item*: its duration, its gain stage, the volume fallback that depends
     * on it.
     */
    private var itemGeneration = 0

    /**
     * Bumped by every [load], every [seek] and [unload]. Guards what belongs
     * to the *playhead*: [currentTime], a load's trailing seek, and the rate
     * restore that follows a seek. Readable for tests.
     */
    internal var playheadGeneration = 0
        private set

    /**
     * Whether the newest load's item has yet to be put where it belongs.
     *
     * Between [load] inserting a new item and that item's seek landing, starting
     * the engine plays the new file from its first second — and for a streamed
     * track that window is a network round trip. [play] and [rate] both used to
     * set the engine's rate straight away, as did a superseded load's seek
     * completing late. They now record the intent and leave the engine alone;
     * whatever places the item — the load's own tail, or a seek that overtook
     * it — restores the rate when it lands.
     *
     * A flag for the newest item rather than a count of loads in flight: a load
     * a newer one superseded can stay suspended in the engine for a network
     * round trip after the newer one has finished, and counting it held a
     * listener's play button down that whole time.
     */
    private var placementPending = false

    /**
     * Called from inside [load] once its item is in the engine and the item has
     * been asked for its duration and tracks, before either answer is awaited.
     *
     * [AudiobookCoordinator.whileLoading]'s counterpart one layer down, and a
     * test seam for the same reason: a seek or a load made inside it lands in
     * the window a real overtaking command lands in, deterministically. Null on
     * every path a listener can reach, and spent when it fires.
     */
    internal var whileLoadingAsset: (suspend () -> Unit)? = null

    /**
     * Called from inside [load] just before its own trailing seek is issued:
     * the window in which an item that fails leaves that seek to land on a dead
     * item. A test seam, null on every path a listener can reach.
     */
    internal var beforeTrailingSeek: (() -> Unit)? = null

    /** The rate the engine is set to, for tests: the interesting cases are the ones where it is not [rate]. */
    internal val engineRate: Float get() = backend.rate

    /**
     * Where the engine's playhead is, for tests: [currentTime] is what this
     * class last *said*, and the two disagreeing is the bug class above.
     */
    internal val engineTime: Double get() = backend.currentTime

    fun play() {
        // Nothing is claimed over an item that would not play. Taking the
        // route stopped the listener's music — or the car's working stream —
        // and `isPlaying` drew a pause glyph over silence that nothing ever
        // stood down, because `itemDidFail` fires once per item. The
        // coordinators reopen the file instead; see their `resume()`. The next
        // `load` is a new item, and plays.
        if (itemHasFailed) {
            IssaLog.info("play refused: the loaded audio would not play")
            return
        }
        // Taken here, not when the player is made: taking the route interrupts
        // whatever else is playing the moment it happens, which is right when
        // the listener asks for narration and wrong when they only opened the
        // book.
        backend.activateSession()
        isPlaying = true
        // Intent only, while a load is still placing its item: see
        // `placementPending`.
        if (!placementPending) backend.rate = rate
        // The rate observers hear only from `rate`'s setter, and this does not
        // touch it — so without this the lock screen kept the old rate and
        // extrapolated a clock the audio was not following.
        notifyRateObservers(rate)
    }

    /**
     * Stops, and forgets that we were playing before an interruption.
     *
     * The latch is set when an interruption begins and read when it ends, and
     * nothing cleared it in between — so a listener who took a call and then
     * deliberately paused on the lock screen had the book start again by itself
     * when the call ended, against an explicit instruction.
     */
    fun pause() {
        wasPlayingBeforeInterruption = false
        isPlaying = false
        backend.rate = 0f
        notifyRateObservers(0f)
    }

    /**
     * An item that stopped for good: paused, its seeks released, and logged.
     *
     * Only for the item the player still holds — a failure reported for one a
     * later load replaced is about audio nobody is listening to.
     */
    internal fun itemDidFail(generation: Int, reason: String) {
        // Once per item: the duration load throwing and the item reporting a
        // failure are usually the same failure, reported twice.
        if (generation != itemGeneration || failedItem == generation) return
        failedItem = generation
        changed()
        placementPending = false
        backend.cancelPendingSeeks()
        if (isPlaying) pause()
        IssaLog.warning("audio would not play", mapOf("href" to (currentAudioHref ?: ""), "error" to reason))
        // The dead file is no longer the one loaded. Left named, every
        // coordinator's "is this file already in the player?" test said yes: a
        // tap on another sentence in the same file took the seek-only branch
        // over a dead item and played, `currentAnchor` named a file that never
        // opened, and the car's "nothing loaded" check passed. Cleared, the next
        // move into this file opens it again.
        currentAudioHref = null
    }

    /** The item [itemDidFail] last stood down, so it does so once. */
    private var failedItem: Int? = null

    /**
     * Whether the item the player holds is one that would not play: the newest
     * load failed, or its item stopped for good. [play] refuses while it is
     * true, and the next [load] clears it. Observed, so a surface can say why
     * nothing is playing.
     */
    val itemHasFailed: Boolean get() = failedItem != null && failedItem == itemGeneration

    /** The current item's generation, for tests that report a failure on it. */
    internal val itemGenerationForTests: Int get() = itemGeneration

    fun togglePlayPause() {
        if (isPlaying) pause() else play()
    }

    /**
     * Moves the playhead, and owns it until something newer does.
     *
     * A load still opening this file loses its trailing seek to this one — see
     * [LoadOutcome.OVERTAKEN].
     *
     * @return whether the playhead landed there and this seek still owns it.
     *   False when the item would not play — [itemHasFailed] then says so — or
     *   when something newer took the playhead. It used to answer nothing, so a
     *   seek on a dead item read as a move that had happened.
     */
    suspend fun seek(to: Double): Boolean {
        playheadGeneration += 1
        return seekPlayhead(to, playheadGeneration)
    }

    /**
     * The tail every seek shares, a load's own trailing seek included.
     *
     * The clock and the rate are written only if nothing has taken the
     * playhead since [generation] was issued. They were written regardless: a
     * load's seek interrupted by the next load completes — the engine calls an
     * interrupted seek back unfinished — and went on to set the clock to the
     * old file's offset and start the *new* item from its first second, before
     * that load's own seek had landed.
     *
     * @return whether this seek still owned the playhead when it landed.
     */
    internal suspend fun seekPlayhead(seconds: Double, generation: Int): Boolean {
        // Not asked of an item that has failed: the engine never calls such a
        // seek back, and whoever awaits it would wait for good. There is nowhere
        // in that item to go.
        val current = backend.currentItem
        if (current != null && current.hasFailed) {
            itemDidFail(itemGeneration, current.failureReason ?: "unknown")
            return false
        }
        val target = mediaTime(seconds)
        // Exact seeking: a read-along highlight lands on the wrong sentence if
        // the engine rounds to the nearest keyframe.
        backend.seek(target)
        if (generation != playheadGeneration) return false
        // The time asked for, unless it is not a time at all; then where the
        // engine was actually sent, so the clock never holds an infinity.
        currentTime = if (seconds.isFinite()) seconds else target.seconds
        // Placed: the engine may run, and this is what restores it.
        placementPending = false
        if (isPlaying) backend.rate = rate
        return true
    }

    suspend fun skip(by: Double) {
        seek(maxOf(0.0, currentTime + by))
    }

    companion object {
        /** Coarse cadence, used when nothing is watching the highlight closely. */
        const val IDLE_OBSERVATION_INTERVAL: Double = 1.0

        /**
         * Fine cadence, used only while a reader is on screen following
         * narration. Anything faster wakes the CPU for no visible benefit; the
         * view interpolates between these.
         */
        const val ACTIVE_OBSERVATION_INTERVAL: Double = 0.20

        /**
         * The engine's target for a time in seconds: the 1/600 s timescale,
         * rounded up, and saturating rather than trapping.
         *
         * Rounded *up* rather than to nearest. A sentence rarely begins on an
         * exact 1/600 of a second, so half of all targets used to quantise a
         * fraction of a millisecond *below* the sentence they name — and the
         * fragment lookup is half-open, so the next tick resolved to the
         * sentence before, dragged the highlight back, and across a document
         * turned the page back and told the sleep timer a chapter had ended. Up
         * to 1/600 s late is inaudible; early is visible.
         *
         * Saturating, because a seek target is whatever a book says. `SmilClock`
         * refuses only the non-finite and the negative, so a `clipBegin` of
         * `1e20s` reaches here, and so does a manifest track claiming `1e300`
         * seconds; the Swift conversion trapped past `Int64.max / 600` seconds —
         * about 1.5e16 — and on infinity, which crashed the app every time such
         * a book was opened at that place. Anything past the largest value the
         * timescale can hold is a seek to the end of the item, which is where
         * the engine puts a seek past it anyway. NaN is no place, and goes to
         * the start, as `max(0, .nan)` always sent it.
         */
        fun mediaTime(seconds: Double): MediaTime {
            if (seconds.isNaN()) return MediaTime.ZERO
            val ticks = ceil(maxOf(0.0, seconds) * MediaTime.TIMESCALE)
            // Long's exact range ends below 2^63; `toDouble()` of `Long.MAX_VALUE`
            // is 2^63 itself, the first value that does not fit.
            if (ticks >= Long.MAX_VALUE.toDouble()) return MediaTime(Long.MAX_VALUE)
            return MediaTime(ticks.toLong())
        }
    }
}
