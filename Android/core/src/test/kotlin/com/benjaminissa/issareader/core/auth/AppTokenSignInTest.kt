package com.benjaminissa.issareader.core.auth

import com.benjaminissa.issareader.core.IssaJson
import com.benjaminissa.issareader.core.Stub
import com.benjaminissa.issareader.core.bodyText
import com.benjaminissa.issareader.core.stubHttp
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.URI
import java.util.Collections
import kotlin.coroutines.resume

private class ScriptedBrowser(private val result: BrowserDismissal) : ApprovalBrowsing {
    val presented: MutableList<URI> = Collections.synchronizedList(mutableListOf())

    override suspend fun present(url: URI): BrowserDismissal {
        presented.add(url)
        return result
    }
}

/**
 * A browser that stays open, the way a real one does.
 *
 * [ScriptedBrowser] answers at once, so a flow driven by it is never *in
 * progress* — and every fault worth catching here happens while the window is
 * up. Built to the shape the app's controller has to have: a continuation held
 * until something resumes it, and cancellation that closes the window and
 * reports [BrowserDismissal.ByApp] rather than abandoning the call.
 */
private class SuspendingBrowser : ApprovalBrowsing {
    private val lock = Any()
    private var pending: CancellableContinuation<BrowserDismissal>? = null
    private val presentedSignal = CompletableDeferred<Unit>()

    override suspend fun present(url: URI): BrowserDismissal = try {
        suspendCancellableCoroutine { continuation ->
            synchronized(lock) { pending = continuation }
            presentedSignal.complete(Unit)
        }
    } catch (e: CancellationException) {
        // The window comes down, and the flow is told who took it down.
        synchronized(lock) { pending = null }
        BrowserDismissal.ByApp
    }

    /** Returns once the window is actually up, so a test cancels a live flow rather than racing its start. */
    suspend fun waitUntilPresented() = presentedSignal.await()

    /** The server redirecting back, or the reader closing the window. */
    fun finish(dismissal: BrowserDismissal) {
        val taken = synchronized(lock) { pending.also { pending = null } }
        taken?.resume(dismissal)
    }
}

/**
 * Answers the exchange `POST` the way the real server does.
 *
 * The status travels in the URL's **port**, so cases share nothing: 200
 * answers with a session token, anything else refuses. Every body posted is
 * kept, so a test can assert the wire format rather than trusting it; each
 * case posts a token only it uses, which makes `contains` exact.
 */
private object ExchangeStub {
    val bodies: MutableList<String> = Collections.synchronizedList(mutableListOf())

    val http = stubHttp { request ->
        request.bodyText()?.let { bodies.add(it) }
        val status = request.url.port
        val payload = """{"access_token":"session-token","token_type":"bearer"}"""
        Stub.Answer(status, if (status == 200) payload else "", mapOf("Content-Type" to "application/json"))
    }
}

/**
 * Taking a token from the server's own sign-in page. Ported from
 * `AppTokenSignInTests.swift`.
 */
class AppTokenSignInTest {
    /** Port 200, so the exchange stub answers with a session token. */
    private val server = URI("http://library.example:200")

    /** The browser is pointed at the app-token route. */
    @Test
    fun opensTheAppTokenRoute() = runBlocking {
        val browser = ScriptedBrowser(BrowserDismissal.Completed(URI("storyteller://settings?token=abc")))
        AppTokenSignInFlow(serverUrl = server, browser = browser, exchangeClient = ExchangeStub.http).run()
        assertEquals(listOf(URI("http://library.example:200/api/v2/token/app")), browser.presented.toList())
    }

    /**
     * The callback token is traded for a session token, and the session one
     * is returned. The shape the server sends: `302 Location:
     * storyteller://settings?token=<JWT>`. The callback carries a five-minute
     * claim ticket; the session token comes back from posting it.
     */
    @Test
    fun takesTheToken() = runBlocking {
        val browser = ScriptedBrowser(BrowserDismissal.Completed(URI("storyteller://settings?token=header.payload.signature")))
        val outcome = AppTokenSignInFlow(serverUrl = server, browser = browser, exchangeClient = ExchangeStub.http).run()
        assertEquals(AppTokenOutcome.Granted("session-token"), outcome)
        assertNotEquals(
            "the claim ticket is not a bearer token and every request with it 401s",
            AppTokenOutcome.Granted("header.payload.signature"), outcome,
        )

        val posted = ExchangeStub.bodies.toList().mapNotNull {
            runCatching { IssaJson.decodeFromString(MapSerializer(String.serializer(), String.serializer()), it) }.getOrNull()
        }
        assertTrue(
            "the claim ticket goes back in the body, which is where the server reads it",
            posted.contains(mapOf("token" to "header.payload.signature")),
        )
    }

    /** A refused exchange says so rather than signing nobody in. */
    @Test
    fun refusedExchange() = runBlocking {
        val browser = ScriptedBrowser(BrowserDismissal.Completed(URI("storyteller://settings?token=abc")))
        val outcome = AppTokenSignInFlow(
            serverUrl = URI("http://library.example:401"), browser = browser, exchangeClient = ExchangeStub.http,
        ).run()
        assertEquals(AppTokenOutcome.Failed(AppTokenFailure.CouldNotExchange(status = 401)), outcome)
    }

    /**
     * Closing the window is not an error, and says who closed it. They look
     * identical to a reader, and one of them is a bug in this app.
     */
    @Test
    fun dismissal() = runBlocking {
        for ((from, expected) in listOf(
            BrowserDismissal.ByUser to AppTokenDismissal.BY_READER,
            BrowserDismissal.ByApp to AppTokenDismissal.BY_APP,
        )) {
            val outcome = AppTokenSignInFlow(serverUrl = server, browser = ScriptedBrowser(from), exchangeClient = ExchangeStub.http).run()
            assertEquals(AppTokenOutcome.Dismissed(expected), outcome)
        }
    }

    /**
     * A flow cancelled while the browser is up reports that the app closed
     * it. This browser suspends the way a real one does, so the window is open
     * when the cancel lands. A cancelled coroutine's own result is the
     * cancellation, so the outcome is read from what the flow returned.
     */
    @Test
    fun cancelledWhileOpen() = runBlocking {
        val browser = SuspendingBrowser()
        val flow = AppTokenSignInFlow(serverUrl = server, browser = browser, exchangeClient = ExchangeStub.http)
        var outcome: AppTokenOutcome? = null
        val job = launch(Dispatchers.Default) { outcome = flow.run() }
        browser.waitUntilPresented()
        job.cancel()
        job.join()
        assertEquals(AppTokenOutcome.Dismissed(AppTokenDismissal.BY_APP), outcome)
    }

    /**
     * A flow left alone completes even though the browser takes its time.
     * Without this the fix above could be "never cancel".
     */
    @Test
    fun survivesTheBrowserBeingOpen() = runBlocking {
        val browser = SuspendingBrowser()
        val flow = AppTokenSignInFlow(serverUrl = server, browser = browser, exchangeClient = ExchangeStub.http)
        val result = CompletableDeferred<AppTokenOutcome>()
        launch(Dispatchers.Default) { result.complete(flow.run()) }
        browser.waitUntilPresented()
        browser.finish(BrowserDismissal.Completed(URI("storyteller://settings?token=late")))
        assertEquals(AppTokenOutcome.Granted("session-token"), result.await())
    }

    /** A callback with no token says so rather than signing nobody in. */
    @Test
    fun callbackWithoutAToken() = runBlocking {
        val browser = ScriptedBrowser(BrowserDismissal.Completed(URI("storyteller://settings")))
        val outcome = AppTokenSignInFlow(serverUrl = server, browser = browser, exchangeClient = ExchangeStub.http).run()
        val failed = outcome as? AppTokenOutcome.Failed ?: throw AssertionError("expected a failure, got $outcome")
        assertEquals(AppTokenFailure.NoToken, failed.failure)
    }

    /** A browser that will not open carries its reason through. */
    @Test
    fun couldNotOpen() = runBlocking {
        val browser = ScriptedBrowser(BrowserDismissal.CouldNotOpen("Couldn't open your server's sign-in page."))
        val outcome = AppTokenSignInFlow(serverUrl = server, browser = browser, exchangeClient = ExchangeStub.http).run()
        val failed = outcome as? AppTokenOutcome.Failed ?: throw AssertionError("expected a failure, got $outcome")
        assertEquals(AppTokenFailure.CouldNotOpen(reason = "Couldn't open your server's sign-in page."), failed.failure)
    }

    /**
     * An address a browser cannot open is refused before the browser is
     * asked: a one-character typo in the scheme survives normalisation, and a
     * browser opens http and https only.
     */
    @Test
    fun refusesNonWebAddress() = runBlocking {
        val browser = ScriptedBrowser(BrowserDismissal.ByUser)
        val outcome = AppTokenSignInFlow(serverUrl = URI("htp://library.example"), browser = browser).run()
        val failed = outcome as? AppTokenOutcome.Failed ?: throw AssertionError("expected a failure, got $outcome")
        assertEquals(AppTokenFailure.NotAWebAddress, failed.failure)
        assertTrue("and the browser is never opened at all", browser.presented.isEmpty())
    }

    /** The flow reports what went wrong, not what to do about it: the failure is a case, not a sentence. */
    @Test
    fun failureCarriesNoUserCopy() = runBlocking {
        val browser = ScriptedBrowser(BrowserDismissal.Completed(URI("storyteller://settings")))
        val outcome = AppTokenSignInFlow(serverUrl = server, browser = browser, exchangeClient = ExchangeStub.http).run()
        assertEquals(AppTokenOutcome.Failed(AppTokenFailure.NoToken), outcome)
    }
}

/** Reading the callback. Ported from `AppTokenCallbackTests` in `AppTokenSignInTests.swift`. */
class AppTokenCallbackTest {
    /** The scheme is checked, because this is the credential. */
    @Test
    fun wrongSchemeIsRefused() {
        assertEquals(null, AppTokenGrant.token(URI("https://evil.example/?token=abc")))
        assertEquals(null, AppTokenGrant.token(URI("issareader://x?token=abc")))
        assertEquals("abc", AppTokenGrant.token(URI("STORYTELLER://settings?token=abc")))
    }

    /** The path is not: it names a screen in the server's own app. */
    @Test
    fun anyPathIsAccepted() {
        assertEquals("a", AppTokenGrant.token(URI("storyteller://settings?token=a")))
        assertEquals("a", AppTokenGrant.token(URI("storyteller://whatever?token=a")))
    }

    /** An empty or absent token is no token. */
    @Test
    fun emptyToken() {
        assertEquals(null, AppTokenGrant.token(URI("storyteller://settings?token=")))
        assertEquals(null, AppTokenGrant.token(URI("storyteller://settings")))
        assertEquals(null, AppTokenGrant.token(URI("storyteller://settings?other=a")))
    }

    /** A percent-encoded token is decoded once, not twice. */
    @Test
    fun encoding() {
        assertEquals("a+b/c=", AppTokenGrant.token(URI("storyteller://settings?token=a%2Bb%2Fc%3D")))
    }
}
