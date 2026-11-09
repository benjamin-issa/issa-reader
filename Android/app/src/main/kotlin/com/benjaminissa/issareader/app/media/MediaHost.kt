package com.benjaminissa.issareader.app.media

import com.benjaminissa.issareader.app.model.NowPlayingSink
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.sync.CarCatalogue
import com.benjaminissa.issareader.playback.CommandRouter
import com.benjaminissa.issareader.playback.android.CarPresence

/**
 * The seam between the media service and the app's state: Swift's
 * `CarPlayBridge`.
 *
 * Android Auto binds the service in a process whose activity may never have
 * existed, so the service reaches for nothing but this — and the app builds
 * it in `Application.onCreate`, before any service can be bound, so what it
 * reaches for is there. Kept this small so the service never touches a
 * screen's state, and so a test can stand in for the whole app.
 *
 * Main-thread only.
 */
interface MediaHost {
    /** Whether the account can be browsed and played from. */
    enum class Access {
        /** Still restoring the session; the library may be about to arrive. */
        LOADING,
        READY,

        /** No account, or its token expired: the car says to sign in on the phone. */
        SIGNED_OUT,
    }

    /** What is playing now, as Now Playing knows it. */
    data class Playing(
        val book: Book,
        /** The listener's intent: true through a buffering stall. */
        val isPlaying: Boolean,
        /** The chosen speed. */
        val rate: Float,
    )

    /** The one funnel every command goes through: `NowPlayingController.remote`. */
    val router: CommandRouter

    /** Where Now Playing is drawn: the service while it runs, nothing otherwise. */
    fun attachSink(sink: NowPlayingSink?)

    val access: Access

    /** What a car may be offered: the server's books, never the reader's own files. */
    val catalogue: CarCatalogue

    /** Calls [onChange] whenever the books, the downloads or [access] change, until closed. */
    fun observeLibrary(onChange: () -> Unit): AutoCloseable

    /** Returns once [access] has left [Access.LOADING], or after a bounded wait. */
    suspend fun awaitLibrary()

    /**
     * Starts a book, answering with the sentence to show if it could not
     * start: `CarPlayBridge.onPlay`. Reported back rather than logged — a row
     * that silently does nothing at 70mph is indistinguishable from a crash.
     */
    suspend fun startListening(bookUuid: String): String?

    /** The rate button: through the rates a driver wants, wrapping round. */
    fun cycleRate()

    /** The listener's chosen speed, playing or not. */
    val playbackRate: Double

    val playing: Playing?

    /** The chapters of whatever is playing, for the queue. */
    fun chapters(): List<String>

    /** Which of [chapters] is playing. */
    fun currentChapter(): Int?

    /** Plays a chapter picked from the queue. */
    suspend fun playChapter(index: Int)

    /** The library store's own full-text search, for a spoken query the ranking could not place. */
    suspend fun searchLibrary(query: String): List<Book>

    /** Whether a car is connected; the service reports Android Auto's controllers to it. */
    val carPresence: CarPresence
}
