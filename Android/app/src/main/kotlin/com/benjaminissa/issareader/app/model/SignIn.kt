package com.benjaminissa.issareader.app.model

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.benjaminissa.issareader.core.auth.AppTokenDismissal
import com.benjaminissa.issareader.core.auth.AppTokenFailure
import com.benjaminissa.issareader.core.auth.AppTokenOutcome
import com.benjaminissa.issareader.core.auth.AppTokenSignInFlow
import com.benjaminissa.issareader.core.auth.ApprovalBrowsing
import com.benjaminissa.issareader.core.auth.DeviceAuthorization
import com.benjaminissa.issareader.core.auth.DeviceGrantFlow
import com.benjaminissa.issareader.core.auth.DeviceGrantOutcome
import com.benjaminissa.issareader.core.auth.DeviceGrantTransport
import com.benjaminissa.issareader.core.auth.HttpDeviceGrantTransport
import com.benjaminissa.issareader.core.diagnostics.IssaLog
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import java.net.URI
import java.time.Instant

/**
 * Sign-in through the server's own login page, in the browser: the state a
 * sign-in screen draws.
 *
 * On Android the browser is Chrome's Auth Tab ([ApprovalBrowsing], the app's
 * `AuthTabBrowser`), which catches Storyteller's `storyteller://` redirect
 * itself. Where the phone's browser has no Auth Tab, the route answers with
 * the pairing-code outcome — [Stage.UseDeviceCode] — rather than opening
 * anything: the user's decision was Auth Tab, with the device code as the
 * fallback, and no `storyteller://` intent filter.
 *
 * Main-thread only.
 *
 * @param flow one browser sign-in, start to finish: a parameter so a test can
 *   stand in for the browser and the server.
 */
class BrowserSignInModel(
    private val serverUrl: URI,
    private val scope: CoroutineScope,
    private val isSupported: () -> Boolean = { true },
    private val flow: suspend (URI) -> AppTokenOutcome,
) {
    /** The production flow over a browser. */
    constructor(serverUrl: URI, scope: CoroutineScope, browser: ApprovalBrowsing, isSupported: () -> Boolean) :
        this(serverUrl, scope, isSupported, { url -> AppTokenSignInFlow(url, browser).run() })

    sealed interface Stage {
        data object Starting : Stage
        data class Granted(val token: String) : Stage

        /**
         * The window closed with nothing. Its own case, not a return to
         * [Starting], which renders as "Opening your server…": folding the two
         * left the screen spinning on a sign-in the reader had walked away from.
         */
        data class Dismissed(val by: AppTokenDismissal) : Stage
        data class Failed(val reason: String) : Stage

        /**
         * This phone's browser cannot hand a sign-in back to the app: the
         * screen goes straight to the pairing code, which needs no browser here.
         */
        data object UseDeviceCode : Stage
    }

    var stage: Stage by mutableStateOf(Stage.Starting)
        private set

    private var task: Job? = null

    /** Bumped by every attempt, so a superseded one cannot write. */
    private var generation = 0

    /** Whether [begin] has been and gone. */
    private var started = false

    /**
     * Starts the sign-in, once. A second call while one is running, or after
     * it has finished, does nothing: the screen appears again when the browser
     * hands back, and starting over there cancelled the token exchange still
     * in flight. Starting again is [restart], which only the reader asks for.
     */
    fun begin() {
        if (started) return
        start()
    }

    /** Abandons whatever attempt there is and starts a new one: "Try again". */
    fun restart() {
        task?.cancel()
        start()
    }

    private fun start() {
        started = true
        generation += 1
        val attempt = generation
        if (!isSupported()) {
            IssaLog.info("browser sign-in unavailable; offering a device code")
            stage = Stage.UseDeviceCode
            return
        }
        stage = Stage.Starting
        val url = serverUrl
        task = scope.launch {
            val outcome = flow(url)
            finish(outcome, attempt)
        }
    }

    private fun finish(outcome: AppTokenOutcome, attempt: Int) {
        // A cancelled attempt must not write over the fresh one.
        if (attempt != generation) return
        stage = when (outcome) {
            is AppTokenOutcome.Granted -> Stage.Granted(outcome.token)
            // Not a failure: the reader closed the window.
            is AppTokenOutcome.Dismissed -> Stage.Dismissed(outcome.by)
            is AppTokenOutcome.Failed -> Stage.Failed(sentence(outcome.failure))
        }
    }

    fun cancel() {
        task?.cancel()
        task = null
    }

    companion object {
        /**
         * What the chooser should say when the reader lands back on it, if
         * anything: only for [AppTokenDismissal.BY_READER], because closing
         * the tab and declining to share the browser's sign-in cannot be told
         * apart, and the second may not have felt like a decision.
         */
        fun note(dismissal: AppTokenDismissal): String? = when (dismissal) {
            AppTokenDismissal.BY_READER ->
                "The browser closed before your server signed you in. If you were asked whether Issa Reader may use " +
                    "your library's website to sign in, that has to be allowed — or use a device code instead."
            AppTokenDismissal.BY_APP -> null
        }

        /** The words for a failure, written here because the screen knows what its own rows are called. */
        fun sentence(failure: AppTokenFailure): String = when (failure) {
            AppTokenFailure.NoToken -> "Your server sent this app back without a sign-in token. Try a device code instead."
            AppTokenFailure.NotAWebAddress -> "That server address isn't one this app can open. Check it and try again."
            is AppTokenFailure.CouldNotOpen -> failure.reason
            // A different fault from no token: the server did sign the reader
            // in, and the second half of the handshake failed.
            is AppTokenFailure.CouldNotExchange -> failure.status?.let {
                "Your server signed you in but wouldn't finish ($it). Try again, or use a device code."
            } ?: "Your server signed you in but didn't answer in time. Try again, or use a device code."
        }
    }
}

/**
 * Runs the device authorization grant: the pairing code, for when the
 * browser cannot hand a sign-in back. The state a device-code screen draws;
 * the screen itself — the code, the QR, the countdown — is the UI port's.
 *
 * Main-thread only.
 *
 * @param transport the grant's requests: the server's, over HTTP, in the app.
 */
class DeviceSignInModel(
    private val serverUrl: URI,
    private val scope: CoroutineScope,
    private val transport: () -> DeviceGrantTransport = { HttpDeviceGrantTransport(serverUrl) },
) {
    sealed interface Stage {
        data object Starting : Stage
        data class AwaitingApproval(val authorization: DeviceAuthorization) : Stage
        data class Granted(val token: String) : Stage
        data class Failed(val reason: String) : Stage
    }

    var stage: Stage by mutableStateOf(Stage.Starting)
        private set

    /** When the code on screen was issued, so the screen can count down to the moment it lapses. */
    var issuedAt: Instant? by mutableStateOf(null)
        private set

    /** True while a lapsed code is being replaced, which the screen says out loud. */
    var isRenewing: Boolean by mutableStateOf(false)
        private set

    private var pollTask: Job? = null

    /** The renewal in flight, if any. */
    private var renewalTask: Job? = null
    private var renewals = 0

    /** The moment the code on screen stops being accepted. */
    val expiresAt: Instant?
        get() {
            val stage = stage as? Stage.AwaitingApproval ?: return null
            return issuedAt?.plusSeconds(stage.authorization.expiresIn.toLong())
        }

    suspend fun begin() {
        // A renewal replaces an in-flight poll.
        pollTask?.cancel()
        pollTask = null
        val flow = DeviceGrantFlow(transport())
        try {
            val authorization = flow.begin()
            stage = Stage.AwaitingApproval(authorization)
            issuedAt = Instant.now()
            isRenewing = false
            pollTask = scope.launch {
                val outcome = flow.awaitApproval(authorization)
                finish(outcome)
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            IssaLog.failure("device sign-in", e, mapOf("server" to serverUrl.toString()))
            isRenewing = false
            stage = Stage.Failed(AppModel.message(e))
        }
    }

    /**
     * What the poll's answer means for the screen. An expired code is replaced
     * where it stands, so a lapsed code becomes a number changing on screen
     * rather than a failure.
     */
    private fun finish(outcome: DeviceGrantOutcome) {
        when (outcome) {
            is DeviceGrantOutcome.Granted -> stage = Stage.Granted(outcome.token)
            DeviceGrantOutcome.Denied -> stage = Stage.Failed("Sign-in was denied.")
            DeviceGrantOutcome.Cancelled -> Unit
            DeviceGrantOutcome.Expired -> {
                if (renewals >= MAX_RENEWALS) {
                    stage = Stage.Failed("The code expired. Try again.")
                    return
                }
                renewals += 1
                isRenewing = true
                IssaLog.info("device code renewed", mapOf("attempt" to renewals.toString()))
                // Disowned before renewing, and renewed from a new task:
                // `begin` cancels the poll task, which this runs inside.
                pollTask = null
                renewalTask?.cancel()
                renewalTask = scope.launch { begin() }
            }
            is DeviceGrantOutcome.Failed -> stage = Stage.Failed(outcome.reason)
        }
    }

    fun cancel() {
        pollTask?.cancel()
        pollTask = null
        renewalTask?.cancel()
        renewalTask = null
    }

    companion object {
        /** A code lives 15 minutes on a default server: about two hours of an abandoned screen. */
        const val MAX_RENEWALS = 8
    }
}
