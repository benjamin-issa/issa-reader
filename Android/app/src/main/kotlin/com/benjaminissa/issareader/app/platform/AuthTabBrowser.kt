package com.benjaminissa.issareader.app.platform

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.activity.ComponentActivity
import androidx.activity.result.ActivityResultLauncher
import androidx.browser.auth.AuthTabIntent
import androidx.browser.customtabs.CustomTabsClient
import com.benjaminissa.issareader.core.auth.ApprovalBrowsing
import com.benjaminissa.issareader.core.auth.BrowserDismissal
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import java.net.URI

/**
 * The server's own sign-in page, in the browser, handed back to the app: what
 * `ASWebAuthenticationSession` does on the iPhone, done with Chrome's Auth Tab.
 *
 * Storyteller's `GET /api/v2/token/app` ends by redirecting to
 * `storyteller://settings?token=…`. The Auth Tab catches that redirect itself
 * and returns it to this app — no `storyteller://` intent filter, which the
 * official Storyteller app claims and would turn into a "which app?" prompt.
 * Not ephemeral, so a reader already signed in to their server in the browser
 * goes straight through, as on the iPhone.
 *
 * Where the phone's default browser has no Auth Tab, [present] answers
 * [BrowserDismissal.CouldNotOpen] with the reason, and the sign-in screen
 * offers the pairing code instead.
 *
 * The launcher must be registered while the activity is being created, so
 * `MainActivity` calls [attach] from `onCreate`.
 */
class AuthTabBrowser(private val context: Context) : ApprovalBrowsing {
    private var launcher: ActivityResultLauncher<Intent>? = null
    private var pending: CompletableDeferred<AuthTabIntent.AuthResult>? = null

    /** Registers the result launcher on the activity that will show the page. */
    fun attach(activity: ComponentActivity) {
        launcher = AuthTabIntent.registerActivityResultLauncher(activity) { result ->
            pending?.complete(result)
            pending = null
        }
    }

    /** Whether the default browser can hand a sign-in back at all. */
    val isSupported: Boolean
        get() = CustomTabsClient.getPackageName(context, null)
            ?.let { CustomTabsClient.isAuthTabSupported(context, it) } == true

    /**
     * Shows [url] and waits for the browser to come back. Main thread only.
     *
     * Cancellation answers [BrowserDismissal.ByApp] rather than throwing, as
     * the contract asks: the app brings itself forward, which closes the tab
     * sitting above it, and the flow reports that the app took the page down.
     */
    override suspend fun present(url: URI): BrowserDismissal {
        val launcher = launcher ?: return BrowserDismissal.CouldNotOpen("There is no screen to show the sign-in page on.")
        if (!isSupported) return BrowserDismissal.CouldNotOpen(UNSUPPORTED)
        pending?.cancel()
        val result = CompletableDeferred<AuthTabIntent.AuthResult>()
        pending = result
        return try {
            AuthTabIntent.Builder().setEphemeralBrowsingEnabled(false).build()
                .launch(launcher, Uri.parse(url.toString()), CALLBACK_SCHEME)
            result.await().let { dismissal(it.resultCode, it.resultUri?.toString()) }
        } catch (cancelled: CancellationException) {
            bringAppForward()
            BrowserDismissal.ByApp
        } catch (error: Exception) {
            BrowserDismissal.CouldNotOpen(error.message ?: "The browser couldn't be opened.")
        }
    }

    private fun bringAppForward() {
        val intent = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        context.startActivity(intent)
    }

    companion object {
        /** The scheme Storyteller's app-token route redirects to. */
        const val CALLBACK_SCHEME = "storyteller"

        const val UNSUPPORTED = "This phone's browser can't hand a sign-in back to the app. Use a device code instead."

        /** What an Auth Tab result means for the sign-in flow. */
        internal fun dismissal(resultCode: Int, resultUri: String?): BrowserDismissal = when (resultCode) {
            AuthTabIntent.RESULT_OK -> resultUri?.let { runCatching { BrowserDismissal.Completed(URI(it)) }.getOrNull() }
                ?: BrowserDismissal.CouldNotOpen("The server's sign-in page didn't hand back a token.")
            AuthTabIntent.RESULT_CANCELED -> BrowserDismissal.ByUser
            AuthTabIntent.RESULT_VERIFICATION_FAILED, AuthTabIntent.RESULT_VERIFICATION_TIMED_OUT ->
                BrowserDismissal.CouldNotOpen("The browser couldn't verify the app to hand the sign-in back.")
            else -> BrowserDismissal.CouldNotOpen("The browser couldn't finish the sign-in.")
        }
    }
}
