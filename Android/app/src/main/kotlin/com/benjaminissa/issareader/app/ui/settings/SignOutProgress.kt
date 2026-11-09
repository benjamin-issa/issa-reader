package com.benjaminissa.issareader.app.ui.settings

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * Whether a sign-out is under way, for the whole app.
 *
 * Signing out tells the server first and waits up to the logout's own limit,
 * and in those seconds the Sign out button has to stay held off. As state of
 * the screen that asked, a Settings screen built again while one was running —
 * the tab left and come back to, the activity recreated — would have
 * forgotten it, and offered a second sign-out behind the first.
 *
 * Main-thread only, as the Swift class is `@MainActor`.
 */
class SignOutProgress {
    var isRunning: Boolean by mutableStateOf(false)
        private set

    /**
     * Runs [work] unless a sign-out is already running.
     *
     * @return whether it ran.
     */
    suspend fun run(work: suspend () -> Unit): Boolean {
        if (isRunning) return false
        isRunning = true
        // Usually moot — a finished sign-out leaves the screen — but one that
        // ends with the app still there must not leave the button dead.
        try {
            work()
        } finally {
            isRunning = false
        }
        return true
    }

    companion object {
        val shared: SignOutProgress = SignOutProgress()
    }
}
