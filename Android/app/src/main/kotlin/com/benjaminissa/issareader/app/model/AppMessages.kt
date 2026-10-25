package com.benjaminissa.issareader.app.model

import com.benjaminissa.issareader.core.networking.StorytellerError

/**
 * Swift's `LocalizedError`: an error that knows how to say itself.
 *
 * The app's own errors — a local import refused, a download that would not
 * start — implement this, as their Swift twins conform to `LocalizedError`;
 * core's [StorytellerError] already carries the same two sentences.
 */
interface LocalizedError {
    /** What the reader is told. Swift's `errorDescription`. */
    val errorDescription: String?

    /** The hint after it, or none. */
    val recoverySuggestion: String? get() = null
}

/**
 * One listener for an account leaving, which the objects keeping per-book state
 * of their own — reader styles, volume trims, question indexes — observe.
 *
 * Swift posts `PlaybackSettings.signOutNotification` on a `NotificationCenter`
 * because `AppModel` does not own those objects. Android has no notification
 * centre, so this is that centre, reduced to the one message it carries: the
 * books the exit keeps (`PlaybackSettings.keptBookUuidsKey`'s set — the
 * device's own books, which belong to no account).
 *
 * Injectable for the reason the Swift centre was: a test that signs out must
 * not reach into another suite's settings. [default] is the app's.
 *
 * Main-thread only, like everything that posts to it; observers are called in
 * the order they registered, synchronously.
 */
class SignOutCentre {
    fun interface Observer {
        fun accountLeft(keptBookUuids: Set<String>)
    }

    private val observers = mutableListOf<Observer>()

    /** Every kept set posted, for the tests that assert a post happened. */
    val posted: MutableList<Set<String>> = mutableListOf()

    /** Starts listening; close the handle to stop. */
    fun observe(observer: Observer): AutoCloseable {
        synchronized(observers) { observers.add(observer) }
        return AutoCloseable { synchronized(observers) { observers.remove(observer) } }
    }

    fun post(keptBookUuids: Set<String>) {
        posted.add(keptBookUuids)
        val current = synchronized(observers) { observers.toList() }
        for (observer in current) observer.accountLeft(keptBookUuids)
    }

    companion object {
        /** The app's. */
        val default: SignOutCentre = SignOutCentre()
    }
}

/** A sentence a person can act on, with the recovery hint appended: Swift's `AppModel.message(for:)`. */
internal fun describe(error: Throwable): String {
    val (described, hint) = when (error) {
        is StorytellerError -> error.message to error.recoverySuggestion
        is LocalizedError -> (error.errorDescription ?: return "Something went wrong.") to error.recoverySuggestion
        else -> return "Something went wrong."
    }
    return listOfNotNull(described, hint).joinToString(" ")
}
