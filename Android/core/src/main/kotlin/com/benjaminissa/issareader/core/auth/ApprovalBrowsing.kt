package com.benjaminissa.issareader.core.auth

import java.net.URI

/**
 * Somewhere to show the server's own sign-in page.
 *
 * Behind an interface so the flow that uses it is testable without a browser:
 * what the app needs to know is only ever "the browser came back to the
 * callback scheme with this URL", or "it closed". The Android app implements
 * it over a Custom Tab with a redirect activity for `storyteller://`.
 *
 * Cancellation is part of the contract: a caller that is cancelled while the
 * page is up has walked away, and the implementation closes the page and
 * answers [BrowserDismissal.ByApp] rather than throwing — the outcome the
 * flow then reports, so a sign-in the app took down says so.
 */
interface ApprovalBrowsing {
    suspend fun present(url: URI): BrowserDismissal
}

sealed interface BrowserDismissal {
    /**
     * The browser was redirected to the callback scheme, carrying whatever the
     * server put in it.
     */
    data class Completed(val callback: URI) : BrowserDismissal

    /**
     * The reader closed it, or declined to share the browser's sign-in. Those
     * cannot be told apart.
     */
    data object ByUser : BrowserDismissal

    /** The app closed it, because something else had already finished. */
    data object ByApp : BrowserDismissal

    data class CouldNotOpen(val reason: String) : BrowserDismissal
}
