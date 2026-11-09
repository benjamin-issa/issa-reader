package com.benjaminissa.issareader.core.networking

/**
 * What can go wrong talking to a Storyteller server, as the reader is told it.
 *
 * Swift's `StorytellerError` enum, as a sealed exception hierarchy. The
 * exception's [message] is Swift's `errorDescription` — what the reader is
 * told — and [recoverySuggestion] is the hint that goes with it. Never a raw
 * dump: `toString()` on a transport failure produces a class name and a
 * stack, which tells someone holding a phone nothing at all.
 *
 * Equal by kind and payload, as the Swift enum is `Equatable`, so a caller can
 * compare against a fresh instance (`error == StorytellerError.NotFound()`).
 */
sealed class StorytellerError(message: String) : Exception(message) {
    /** 401. The bearer token is missing, expired or revoked. */
    class NotAuthenticated : StorytellerError("Your session has ended.") {
        override val recoverySuggestion: String get() = "Sign in again to carry on."
        override fun equals(other: Any?): Boolean = other is NotAuthenticated
        override fun hashCode(): Int = 1
        override fun toString(): String = "StorytellerError.NotAuthenticated"
    }

    /** 403. Authenticated, but the user lacks the permission this route gates on. */
    class Forbidden : StorytellerError("Your account doesn't have permission for that.") {
        override val recoverySuggestion: String get() = "Ask whoever runs the server to grant it."
        override fun equals(other: Any?): Boolean = other is Forbidden
        override fun hashCode(): Int = 2
        override fun toString(): String = "StorytellerError.Forbidden"
    }

    class NotFound : StorytellerError("That isn't on the server any more.") {
        override val recoverySuggestion: String get() = "Pull down to refresh your library."
        override fun equals(other: Any?): Boolean = other is NotFound
        override fun hashCode(): Int = 3
        override fun toString(): String = "StorytellerError.NotFound"
    }

    /**
     * 409 from `POST /books/{id}/positions`: the stored position is newer than
     * the one we tried to write, or is the same age with a different locator.
     * The caller must re-read the server position and reconcile.
     */
    class PositionConflict : StorytellerError("Your reading position is further along on another device.") {
        override val recoverySuggestion: String get() = "Open the book to pick up from the newer position."
        override fun equals(other: Any?): Boolean = other is PositionConflict
        override fun hashCode(): Int = 4
        override fun toString(): String = "StorytellerError.PositionConflict"
    }

    /** Any other status, with the server's own `message` when it sent one. */
    class Server(val status: Int, val serverMessage: String?) :
        StorytellerError(serverMessage ?: "The server had a problem ($status).") {
        override val recoverySuggestion: String get() = "It may be restarting. Try again shortly."
        override fun equals(other: Any?): Boolean =
            other is Server && other.status == status && other.serverMessage == serverMessage
        override fun hashCode(): Int = status * 31 + (serverMessage?.hashCode() ?: 0)
        override fun toString(): String = "StorytellerError.Server(status=$status, message=$serverMessage)"
    }

    /**
     * The request never got an answer. The reason travels with the case;
     * discarding it was how a download that never finished got reported as a
     * network outage.
     */
    class Transport(val reason: String) :
        StorytellerError(reason.ifEmpty { "Couldn't reach your server." }) {
        override val recoverySuggestion: String get() = "Check that you're on the same network as your server."
        override fun equals(other: Any?): Boolean = other is Transport && other.reason == reason
        override fun hashCode(): Int = reason.hashCode()
        override fun toString(): String = "StorytellerError.Transport($reason)"
    }

    /**
     * A download that did not finish, carrying the reason the download
     * manager gave — a filesystem refusal, a bad status, an interrupted
     * transfer, no room on the device.
     *
     * Its own case because these were being thrown as [Transport], which
     * appends "Check that you're on the same network as your server" to
     * everything. An Apple TV that could not create its downloads folder was
     * therefore told, at length, to check its Wi-Fi.
     */
    class Download(val reason: String) :
        StorytellerError(reason.ifEmpty { "The download didn't finish." }) {
        // No hint. The reasons here are already sentences, and none of them
        // is a network outage.
        override val recoverySuggestion: String? get() = null
        override fun equals(other: Any?): Boolean = other is Download && other.reason == reason
        override fun hashCode(): Int = reason.hashCode()
        override fun toString(): String = "StorytellerError.Download($reason)"
    }

    class Decoding(val detail: String) : StorytellerError("The server sent something this app didn't understand.") {
        override val recoverySuggestion: String
            get() = "This can happen if the server is a newer version than the app expects."
        override fun equals(other: Any?): Boolean = other is Decoding && other.detail == detail
        override fun hashCode(): Int = detail.hashCode()
        override fun toString(): String = "StorytellerError.Decoding($detail)"
    }

    /** What the reader is told. Swift's `errorDescription`. */
    override val message: String get() = super.message ?: ""

    /** The hint after [message], or none. Swift's `recoverySuggestion`. */
    abstract val recoverySuggestion: String?

    val isRetryable: Boolean
        get() = when (this) {
            is Transport -> true
            is Server -> status >= 500 || status == 429
            else -> false
        }
}

/**
 * Turns any error into a sentence worth showing someone.
 *
 * `toString()` on a transport failure produces a class name with a message
 * that tells a person holding a phone nothing. The app has its own copy of
 * this for view code; this one exists so core can record a readable reason
 * without reaching up into the app.
 */
object AppFacingError {
    fun text(error: Throwable): String {
        if (error !is StorytellerError) return "Something went wrong."
        return listOfNotNull(error.message, error.recoverySuggestion).joinToString(" ")
    }
}
