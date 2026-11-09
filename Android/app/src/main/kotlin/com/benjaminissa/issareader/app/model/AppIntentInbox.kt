package com.benjaminissa.issareader.app.model

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.benjaminissa.issareader.core.CurrentBookSnapshotStore

/**
 * Where "Continue reading" leaves its request for the app to collect.
 *
 * The iPhone's Siri shortcut, on Android: the launcher shortcut and the widget
 * open `issareader://continue`, which names no book — it means the book the
 * widget shows. The request can arrive before the library exists, or before
 * anyone is signed in, so it is left here and the library collects it the way
 * it collects a widget tap.
 *
 * Observable, so the library collects a request the moment it is written
 * rather than at the next foreground: a cold launch reaches the foreground
 * before the library exists, and a request collected only there sat here
 * until the reader next left the app and came back, when the book opened
 * unasked.
 */
class AppIntentInbox {
    var bookId: String? by mutableStateOf(null)

    /**
     * "Continue reading": the book the widget's snapshot names. Swift's
     * `ContinueReadingIntent.perform()`.
     *
     * @return the sentence to show when there is no book in progress, or null
     *   when the request was left here.
     */
    fun continueReading(): String? {
        val snapshot = CurrentBookSnapshotStore.read() ?: return NOTHING_IN_PROGRESS
        bookId = snapshot.bookId
        return null
    }

    /**
     * Hands the waiting request to the app, once, and empties the inbox.
     * Through `requestBook`, which waits for the catalogue: a request made
     * before the library has loaded opens the book when it arrives.
     */
    fun deliver(app: AppModel) {
        val id = bookId ?: return
        bookId = null
        // "Continue reading" means exactly that.
        app.requestBook(id, AppModel.PendingBook.Destination.READ)
    }

    companion object {
        const val NOTHING_IN_PROGRESS = "You haven't started a book yet."

        /** The app's. */
        val shared: AppIntentInbox by lazy { AppIntentInbox() }
    }
}

/**
 * What one window shows for the app's phase, decided in one place a test can
 * ask.
 *
 * The three signed-out phases are one screen: "Sign in again" on the
 * session-ended notice moves the phase from expired through signing in to
 * choosing a server while its own work is still running, and a screen per
 * phase was rebuilt underneath it. The books from Files are that screen's
 * alternative in every one of those phases.
 */
enum class RootScreen {
    LAUNCHING,
    SIGN_IN,
    LOCAL_BOOKS,
    LIBRARY,
    ;

    companion object {
        fun forPhase(phase: AppModel.Phase, showsListSignedOut: Boolean): RootScreen = when (phase) {
            AppModel.Phase.LAUNCHING -> LAUNCHING
            AppModel.Phase.CHOOSE_SERVER, AppModel.Phase.SIGNING_IN, AppModel.Phase.EXPIRED ->
                if (showsListSignedOut) LOCAL_BOOKS else SIGN_IN
            AppModel.Phase.READY -> LIBRARY
        }
    }
}
