package com.benjaminissa.issareader.app.platform

import androidx.browser.auth.AuthTabIntent
import com.benjaminissa.issareader.core.auth.BrowserDismissal
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.URI

/** What each Auth Tab result means to the sign-in flow. */
class AuthTabBrowserTest {
    @Test
    fun `the redirect carrying the token completes the sign-in`() {
        assertEquals(
            BrowserDismissal.Completed(URI("storyteller://settings?token=abc")),
            AuthTabBrowser.dismissal(AuthTabIntent.RESULT_OK, "storyteller://settings?token=abc"),
        )
    }

    @Test
    fun `closing the tab is the reader's doing`() {
        assertEquals(BrowserDismissal.ByUser, AuthTabBrowser.dismissal(AuthTabIntent.RESULT_CANCELED, null))
    }

    @Test
    fun `anything else could not finish, and says why`() {
        for (code in listOf(AuthTabIntent.RESULT_VERIFICATION_FAILED, AuthTabIntent.RESULT_VERIFICATION_TIMED_OUT, AuthTabIntent.RESULT_UNKNOWN_CODE)) {
            assertTrue(AuthTabBrowser.dismissal(code, null) is BrowserDismissal.CouldNotOpen)
        }
        assertTrue(AuthTabBrowser.dismissal(AuthTabIntent.RESULT_OK, null) is BrowserDismissal.CouldNotOpen)
    }
}
