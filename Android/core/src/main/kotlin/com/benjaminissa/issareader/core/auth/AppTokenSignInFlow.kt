package com.benjaminissa.issareader.core.auth

import com.benjaminissa.issareader.core.diagnostics.IssaLog
import com.benjaminissa.issareader.core.networking.isWebLink
import okhttp3.OkHttpClient
import java.net.URI

/**
 * Why the browser route did not produce a token.
 *
 * A case rather than a sentence. The flow used to return a failure carrying
 * its own sentence — which is how it came to tell readers to "try a username
 * and password" for two builds after that route was deleted, and to name a
 * chooser row that had been renamed. The view knows what its own rows are
 * called; this type does not and should not.
 */
sealed interface AppTokenFailure {
    /** The server redirected back, but with no token in the callback. */
    data object NoToken : AppTokenFailure

    /** The browser could not be opened at all. */
    data class CouldNotOpen(val reason: String) : AppTokenFailure

    /** The address is not one a browser can open. */
    data object NotAWebAddress : AppTokenFailure

    /**
     * The callback's short-lived token could not be traded for a session one.
     *
     * A null status means the request never got an answer. See
     * [AppTokenGrant.exchange] for why there is a trade at all.
     */
    data class CouldNotExchange(val status: Int?) : AppTokenFailure
}

/**
 * Who closed the window, when nothing went wrong and nothing was granted.
 *
 * Carried rather than collapsed. The two are the same picture — a browser that
 * appears and vanishes — and completely different faults, and folding them into
 * one silent dismissal is why a build shipped in which the app cancelled its
 * own sign-in on every attempt and left nothing behind to say so.
 */
enum class AppTokenDismissal {
    /** The reader closed it — or declined to share the browser's sign-in, which cannot be told apart from it. */
    BY_READER,

    /** The app took it down, because something cancelled the flow. */
    BY_APP,
}

sealed interface AppTokenOutcome {
    data class Granted(val token: String) : AppTokenOutcome

    /** The window closed without the server redirecting anywhere. */
    data class Dismissed(val by: AppTokenDismissal) : AppTokenOutcome

    data class Failed(val failure: AppTokenFailure) : AppTokenOutcome
}

/**
 * Opens the server's app-token route in a browser and takes the token it
 * redirects back with.
 *
 * Almost nothing to it, which is the point: the server does the work, and the
 * only thing that can go wrong on this side is being handed a callback with no
 * token in it.
 *
 * @param exchangeClient the transport for the token exchange, so a test can
 *   answer without a server — the seam `Session` and `ApiClient` already have.
 *   null means one of its own.
 */
class AppTokenSignInFlow(
    private val serverUrl: URI,
    private val browser: ApprovalBrowsing,
    private val exchangeClient: OkHttpClient? = null,
) {
    suspend fun run(): AppTokenOutcome {
        val start = AppTokenGrant.startUrl(serverUrl)
        // The guard the deleted flow carried, and the only path that skipped
        // it. `ServerAddress.normalize` only requires a parseable host, so
        // `htp://library.example` survives it — and a browser opens http and
        // https only, so the reader was told the *browser* had failed and
        // steered to a pairing code that would fail identically, for a
        // one-character typo.
        if (!start.isWebLink) {
            IssaLog.error("app token route is not a web address", mapOf("scheme" to (start.scheme ?: "—")))
            return AppTokenOutcome.Failed(AppTokenFailure.NotAWebAddress)
        }

        return when (val dismissal = browser.present(start)) {
            is BrowserDismissal.Completed -> {
                val callback = dismissal.callback
                val token = AppTokenGrant.token(callback)
                if (token == null) {
                    // What the server actually sent, which is the only thing
                    // that makes this diagnosable. The old field logged the
                    // callback's scheme — provably `storyteller`, since the
                    // browser calls back on no other — so the one failure this
                    // flow can produce left a line carrying zero bits. Names
                    // only: a value here could be the token itself.
                    val names = AppTokenGrant.queryItems(callback).map { it.first }.sorted()
                        .joinToString(",").ifEmpty { "none" }
                    IssaLog.error("app token callback carried no token", mapOf("parameters" to names))
                    return AppTokenOutcome.Failed(AppTokenFailure.NoToken)
                }
                // The success line this flow did not have. Not the token, and
                // not the callback URL, which carries it — only that one
                // arrived. Its absence is what made "the browser flashed and
                // nothing happened" undiagnosable from an export: three
                // failures logged, two silences.
                //
                // "Callback", not "granted": that word was wrong, and being
                // wrong cost a build. What arrives here is a five-minute claim
                // ticket, not a session.
                IssaLog.info("app token callback carried a token")
                // The step the flow was missing entirely. Without it the app
                // used the claim ticket as a bearer token and every request
                // 401'd.
                when (val exchanged = exchange(token)) {
                    is AppTokenGrant.Exchange.Granted -> {
                        IssaLog.info("app token exchanged for a session")
                        AppTokenOutcome.Granted(exchanged.sessionToken)
                    }
                    is AppTokenGrant.Exchange.Refused -> AppTokenOutcome.Failed(exchanged.failure)
                }
            }
            BrowserDismissal.ByUser -> {
                IssaLog.info("app token window closed by the reader")
                AppTokenOutcome.Dismissed(AppTokenDismissal.BY_READER)
            }
            BrowserDismissal.ByApp -> {
                // Worth a warning, not an info. Nothing in the app should be
                // cancelling this while the reader is looking at it, so if this
                // line appears without the reader having navigated away, it is
                // a bug — and for two builds it was one.
                IssaLog.warning("app token window closed by the app")
                AppTokenOutcome.Dismissed(AppTokenDismissal.BY_APP)
            }
            is BrowserDismissal.CouldNotOpen -> {
                // Logged at all, which it was not: this leg was silent, where
                // the flow it replaced logged its start failure.
                IssaLog.error("could not open the app token route", mapOf("reason" to dismissal.reason))
                AppTokenOutcome.Failed(AppTokenFailure.CouldNotOpen(dismissal.reason))
            }
        }
    }

    private suspend fun exchange(callbackToken: String): AppTokenGrant.Exchange {
        val client = exchangeClient ?: return AppTokenGrant.exchange(callbackToken, serverUrl)
        return AppTokenGrant.exchange(callbackToken, serverUrl, client)
    }
}
