package com.benjaminissa.issareader.app.model

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.benjaminissa.issareader.core.IssaJson
import com.benjaminissa.issareader.core.KeyValueStore
import com.benjaminissa.issareader.playback.CommandMap
import com.benjaminissa.issareader.playback.ControlSurface
import com.benjaminissa.issareader.playback.PlaybackRate
import com.benjaminissa.issareader.playback.ProgressScope
import com.benjaminissa.issareader.playback.VolumeTrim
import com.benjaminissa.issareader.render.PageTurnStyle
import com.benjaminissa.issareader.render.ReaderStyle
import com.benjaminissa.issareader.render.ReaderStyleOverride
import kotlinx.serialization.KSerializer
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer

/**
 * Persisted playback and reading preferences.
 *
 * Swift keeps these in the App Group's defaults so the widget reads the same
 * values; Android's widget reads only the snapshot, so they live in the app's
 * own [KeyValueStore] — the same keys and the same JSON shapes, so a value
 * written by one client is read the same way by the other's code.
 *
 * Observable: every preference is Compose snapshot state, so a settings screen
 * redraws as it moves; a non-Compose consumer (the media session's command map)
 * uses `snapshotFlow`. Main-thread only, as the Swift class is `@MainActor`.
 *
 * @param centre where an account's exit is announced (see [SignOutCentre]):
 *   injectable so a test posting it reaches only its own instance.
 */
class PlaybackSettings(
    private val defaults: KeyValueStore,
    centre: SignOutCentre = SignOutCentre.default,
) {
    private var commandMapState by mutableStateOf(load(CommandMap.serializer(), COMMAND_MAP_KEY) ?: CommandMap())
    var commandMap: CommandMap
        get() = commandMapState
        set(value) {
            commandMapState = value
            persist(CommandMap.serializer(), value, COMMAND_MAP_KEY)
            playbackChanged()
        }

    private var readerStyleState by mutableStateOf(load(ReaderStyle.serializer(), READER_STYLE_KEY) ?: ReaderStyle())
    var readerStyle: ReaderStyle
        get() = readerStyleState
        set(value) {
            readerStyleState = value
            persist(ReaderStyle.serializer(), value, READER_STYLE_KEY)
        }

    /**
     * Clamped on the way in and on the way out.
     *
     * It accepted anything: the bound speed controls walked to 5.0×, a value no
     * menu offers and the transport renders as "5×", and `storedRate > 0` let
     * it back in on the next launch — so a rate reached by holding a button
     * was persisted with no control able to show or undo it. Clamp, then
     * persist the clamped value, in one pass.
     */
    private var playbackRateState by mutableStateOf(
        defaults.getString(RATE_KEY)?.toDoubleOrNull()?.takeIf { it > 0 }?.let(PlaybackRate::clamped) ?: 1.0,
    )
    var playbackRate: Double
        get() = playbackRateState
        set(value) {
            val legal = PlaybackRate.clamped(value)
            playbackRateState = legal
            defaults.putString(RATE_KEY, legal.toString())
        }

    /**
     * Whether a progress bar stands for the whole book or the current chapter.
     *
     * Stored as a raw string beside [playbackRate] rather than folded into
     * [readerStyle] or [commandMap]: the first re-paginates the open book on
     * any change, and the second re-registers every remote command. This is a
     * display choice and should cost nothing.
     *
     * Absent until the picker is first moved, so the fallback moves everyone
     * who never chose and leaves alone everyone who did.
     */
    private var progressScopeState by mutableStateOf(
        defaults.getString(PROGRESS_SCOPE_KEY)?.let { raw -> ProgressScope.entries.firstOrNull { it.rawValue == raw } }
            ?: ProgressScope.CHAPTER,
    )
    var progressScope: ProgressScope
        get() = progressScopeState
        set(value) {
            progressScopeState = value
            defaults.putString(PROGRESS_SCOPE_KEY, value.rawValue)
            playbackChanged()
        }

    /**
     * Whether the reader offers to answer questions about the book.
     *
     * Off until asked for (an absent key reads false), and beside
     * [progressScope] rather than in [readerStyle]: turning a toolbar button
     * on or off should not cost the reader their place.
     */
    private var askEnabledState by mutableStateOf(defaults.getBoolean(ASK_ENABLED_KEY))
    var askEnabled: Boolean
        get() = askEnabledState
        set(value) {
            askEnabledState = value
            defaults.putBoolean(ASK_ENABLED_KEY, value)
        }

    /**
     * How a turned page moves: Slide, Cover, or None. Slide unless the reader
     * chose otherwise — including a value this build cannot read, which a
     * later build might one day write.
     */
    private var pageTurnState by mutableStateOf(
        defaults.getString(PAGE_TURN_KEY)?.let(PageTurnStyle::fromRawValue) ?: PageTurnStyle.SLIDE,
    )
    var pageTurn: PageTurnStyle
        get() = pageTurnState
        set(value) {
            pageTurnState = value
            defaults.putString(PAGE_TURN_KEY, value.rawValue)
        }

    /**
     * Whether the reader prints the book's title in small type under the
     * footer's controls, where the navigation bar leaves a band to hold it.
     *
     * Beside [pageTurn] and out of [readerStyle] for the same reason: the title
     * is drawn in the band the system's navigation bar holds, which the page's
     * size already counts, so showing or hiding it cannot move a line, and it
     * should cost the reader nothing, least of all their place.
     *
     * On unless the reader turned it off: an absent key is the default, not a
     * choice, so [KeyValueStore.getBoolean] (which reads absent as off) is not
     * what reads it, and nothing is stored until the switch is first moved.
     */
    private var showsBookTitleState by mutableStateOf(defaults.getBooleanOrNull(SHOWS_BOOK_TITLE_KEY) ?: true)
    var showsBookTitle: Boolean
        get() = showsBookTitleState
        set(value) {
            showsBookTitleState = value
            defaults.putBoolean(SHOWS_BOOK_TITLE_KEY, value)
        }

    /**
     * Per-book departures from [readerStyle], keyed by book uuid. Device-local
     * and deliberately not synced: a size that suits a phone is wrong on a
     * television.
     */
    var bookStyles: Map<String, ReaderStyleOverride> by mutableStateOf(
        load(bookStylesSerializer, BOOK_STYLES_KEY) ?: emptyMap(),
    )
        private set

    private fun replaceBookStyles(value: Map<String, ReaderStyleOverride>) {
        bookStyles = value
        persist(bookStylesSerializer, value, BOOK_STYLES_KEY)
    }

    /**
     * How far each book departs from the level it was recorded at, in
     * decibels, keyed by book uuid. Only departures are stored, so a book
     * returned to "as recorded" leaves nothing behind.
     */
    var bookVolumeTrims: Map<String, Int> by mutableStateOf(emptyMap())
        private set

    private fun replaceBookVolumeTrims(value: Map<String, Int>) {
        bookVolumeTrims = value
        persist(trimsSerializer, value, BOOK_VOLUME_DECIBELS_KEY)
    }

    private val signOutObservation: AutoCloseable

    private val playbackObservers = mutableListOf<() -> Unit>()

    /**
     * Calls [listener] after every change to [commandMap] or [progressScope]:
     * what the system's transport is built from, and what its numbers mean.
     * Swift's `NowPlayingController` observed the two through `@Observable`;
     * a plain listener keeps the media session in step whether or not any
     * screen is composed.
     */
    fun observePlayback(listener: () -> Unit): AutoCloseable {
        playbackObservers.add(listener)
        return AutoCloseable { playbackObservers.remove(listener) }
    }

    private fun playbackChanged() {
        for (observer in playbackObservers.toList()) observer()
    }

    init {
        val volumes = volumeTrims()
        bookVolumeTrims = volumes.first
        moveOffTheOldDefaultFace()
        // Assignments in a constructor are not persisted by the setters above,
        // so the levels this build just converted are written back by hand —
        // once, and only when they came from the old key.
        if (volumes.second) persist(trimsSerializer, bookVolumeTrims, BOOK_VOLUME_DECIBELS_KEY)
        signOutObservation = centre.observe { kept ->
            // Everything but the device's own books, which are not the
            // account's to take.
            replaceBookStyles(bookStyles.filterKeys { it in kept })
            replaceBookVolumeTrims(bookVolumeTrims.filterKeys { it in kept })
            // The old key as well: per-book state keyed by a book uuid, and
            // leaving the previous account's levels in a key a shipped build
            // still reads is the same leak one downgrade away.
            defaults.remove(BOOK_VOLUMES_KEY)
        }
    }

    /** Stops listening for sign-outs. The app's instance lives for the process; a test's is closed. */
    fun close() = signOutObservation.close()

    /**
     * This build's levels, and whether they had to be converted to get here.
     *
     * Decibels from their own key; where that is absent, the percentages a
     * build up to 1.1.0 (32) wrote are converted through the multiplier they
     * always stood for. Sanitised on the way out — a level nothing on screen
     * can show or undo is the defect [playbackRate] carries a clamp for — and
     * entries that sanitise to zero are dropped.
     */
    private fun volumeTrims(): Pair<Map<String, Int>, Boolean> {
        load(trimsSerializer, BOOK_VOLUME_DECIBELS_KEY)?.let { stored ->
            return stored.mapNotNull { (key, value) -> legalTrim(value)?.let { key to it } }.toMap() to false
        }
        val legacy = load(trimsSerializer, BOOK_VOLUMES_KEY) ?: return emptyMap<String, Int>() to false
        return legacy.mapNotNull { (key, value) ->
            legalTrim(VolumeTrim.decibels(forLegacyPercent = value))?.let { key to it }
        }.toMap() to true
    }

    /**
     * Moves anyone still on the previous default reading face onto the new
     * one, once. The flag makes this a move and not a policy — pick Newsreader
     * afterwards and it stays picked.
     */
    private fun moveOffTheOldDefaultFace() {
        if (defaults.getBoolean(FACE_MIGRATION_KEY)) return
        defaults.putBoolean(FACE_MIGRATION_KEY, true)
        val movedStyle = readerStyle.replacingLegacyDefaultFace()
        val movedBooks = bookStyles.mapValues { it.value.replacingLegacyDefaultFace() }
        if (movedStyle == readerStyle && movedBooks == bookStyles) return
        readerStyle = movedStyle
        replaceBookStyles(movedBooks)
    }

    /** The style to set this book in: the global settings, with the book's own choices laid over them. */
    fun style(bookUuid: String): ReaderStyle = readerStyle.applying(bookStyles[bookUuid])

    fun override(bookUuid: String): ReaderStyleOverride? = bookStyles[bookUuid]

    /**
     * Records what this book departs from the defaults in. An override with
     * nothing left in it is removed, so a book returned to the defaults
     * follows them from then on.
     */
    fun setOverride(override: ReaderStyleOverride?, bookUuid: String) {
        replaceBookStyles(
            if (override != null && !override.isEmpty) bookStyles + (bookUuid to override) else bookStyles - bookUuid,
        )
    }

    /** Forgets one book's style and level, for a book the reader removed from this device. */
    fun forgetBook(bookUuid: String) {
        if (bookStyles.containsKey(bookUuid)) replaceBookStyles(bookStyles - bookUuid)
        if (bookVolumeTrims.containsKey(bookUuid)) replaceBookVolumeTrims(bookVolumeTrims - bookUuid)
    }

    /** How far this book departs from the recorded level, in decibels; zero for nearly all. */
    fun volumeTrim(bookUuid: String): Int = bookVolumeTrims[bookUuid] ?: 0

    /** Records this book's level; zero removes the entry, on [setOverride]'s rule. */
    fun setVolumeTrim(decibels: Int, bookUuid: String) {
        val legal = legalTrim(decibels)
        replaceBookVolumeTrims(if (legal != null) bookVolumeTrims + (bookUuid to legal) else bookVolumeTrims - bookUuid)
    }

    /** Restores the shipped bindings for one surface: the escape hatch after experimenting into a corner. */
    fun resetBindings(surface: ControlSurface) {
        val defaults = CommandMap.defaultBindings[surface] ?: return
        commandMap = commandMap.copy(bindings = commandMap.bindings + (surface to defaults))
    }

    private fun <T> persist(serializer: KSerializer<T>, value: T, key: String) {
        val text = runCatching { IssaJson.encodeToString(serializer, value) }.getOrNull() ?: return
        defaults.putString(key, text)
    }

    private fun <T> load(serializer: KSerializer<T>, key: String): T? {
        val text = defaults.getString(key) ?: return null
        return runCatching { IssaJson.decodeFromString(serializer, text) }.getOrNull()
    }

    companion object {
        const val COMMAND_MAP_KEY = "issa.commandMap"
        const val READER_STYLE_KEY = "issa.readerStyle"
        const val BOOK_STYLES_KEY = "issa.bookStyles"

        /**
         * Percentages, written by builds up to 1.1.0 (32) and read once by
         * this one. Never written again, and deliberately left where it is.
         */
        const val BOOK_VOLUMES_KEY = "issa.bookVolumes"

        /** Decibels: a key of its own so the two builds cannot read each other's numbers as their own units. */
        const val BOOK_VOLUME_DECIBELS_KEY = "issa.bookVolumeDecibels"
        const val RATE_KEY = "issa.playbackRate"
        const val PROGRESS_SCOPE_KEY = "issa.progressScope"
        const val ASK_ENABLED_KEY = "issa.askAboutBook"
        const val PAGE_TURN_KEY = "issa.pageTurn"
        const val SHOWS_BOOK_TITLE_KEY = "issa.showBookTitle"
        const val FACE_MIGRATION_KEY = "issa.migratedDefaultFaceToLiterata"

        private val bookStylesSerializer = MapSerializer(String.serializer(), ReaderStyleOverride.serializer())
        private val trimsSerializer = MapSerializer(String.serializer(), Int.serializer())

        /** A stored level snapped onto the ladder, or null for a book at the recorded level after all. */
        internal fun legalTrim(stored: Int): Int? = VolumeTrim.clamped(stored).takeIf { it != 0 }
    }
}

/**
 * Telling a reader their book cannot be made louder: the half of the volume
 * slider that cannot be delivered, said rather than silently lost. Three states,
 * not two — null is "nothing loaded yet", and captioning that would put the
 * warning under every book for the moment before its tracks resolve.
 */
object VolumeTrimReach {
    /** Whether the louder half of the slider can actually be heard: only a player that has answered no says no. */
    fun canBeLouder(carriesGain: Boolean?): Boolean = carriesGain != false

    /** The line under the slider, or null when there is nothing to explain. */
    fun caption(carriesGain: Boolean?): String? {
        if (canBeLouder(carriesGain)) return null
        return "This book can only be made quieter. It is being streamed, and only a downloaded file can be played louder than it was recorded."
    }

    /**
     * What TalkBack reads as the slider's value: the caption folded in, and
     * only where the level asks for more than can be delivered.
     */
    fun spoken(decibels: Int, carriesGain: Boolean?): String {
        val level = VolumeTrim.spoken(decibels)
        if (canBeLouder(carriesGain) || VolumeTrim.clamped(decibels) <= 0) return level
        return "$level, but this book can only be made quieter"
    }
}
