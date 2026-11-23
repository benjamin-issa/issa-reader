package com.benjaminissa.issareader.app.model

import com.benjaminissa.issareader.app.AppSuite
import com.benjaminissa.issareader.app.SharedFixtures
import com.benjaminissa.issareader.app.TestTokens
import com.benjaminissa.issareader.app.mainTest
import com.benjaminissa.issareader.app.testApp
import com.benjaminissa.issareader.app.testScope
import com.benjaminissa.issareader.app.close
import com.benjaminissa.issareader.app.LifecycleServer
import com.benjaminissa.issareader.core.Session
import com.benjaminissa.issareader.core.networking.ApiClient
import com.benjaminissa.issareader.core.networking.ServerAddress
import com.benjaminissa.issareader.core.store.LibraryStore
import kotlinx.coroutines.runBlocking
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.URI

/** The probe that picks which of the addresses someone typed has a Storyteller behind it. */
class ServerProbeTest : AppSuite() {
    /**
     * The probe goes through the app's own client, so the connection that
     * answered is still open for the sign-in that follows it. A client of the
     * probe's own started threads for the one request and closed that
     * connection as it finished.
     */
    @Test
    fun `the probe finds the address that answers, and keeps its connection for the sign-in`() = runBlocking {
        MockWebServer().use { server ->
            server.enqueue(MockResponse.Builder().code(200).body("{}").build())
            server.start()
            val pool = ApiClient.sharedHttpClient.connectionPool
            pool.evictAll()
            // Nothing listens on port 1: refused at once.
            val nothing = URI("http://127.0.0.1:1")
            val storyteller = URI(server.url("/").toString())

            assertEquals(storyteller, AppModel.firstReachable(listOf(nothing, storyteller), timeoutSeconds = 2))
            assertEquals("/api/v2/server/public", server.takeRequest().url.encodedPath)
            assertTrue("the connection that answered was closed", pool.idleConnectionCount() >= 1)
        }
    }

    /**
     * A bare host that connected over plain http is stored as typed, its token
     * and library filed under the http address. A launch where no probe
     * answers must not replace that with the https candidate: the offline
     * shelf shows, and the stored address stays as it was.
     */
    @Test
    fun `a launch where no probe answers keeps the stored address, session and shelf`() = mainTest {
        val scope = testScope()
        // Nothing listens on port 1: both candidates are refused at once.
        val typed = "127.0.0.1:1"
        val http = URI("http://127.0.0.1:1")
        val tokens = TestTokens()
        tokens.write("stored-token", http.toString())
        val defaults = SharedFixtures.scratchDefaults()
        defaults.putString(AppModel.LAST_SERVER_KEY, typed)
        val store = LibraryStore(http.toString())
        store.replaceCatalogue(listOf(SharedFixtures.book("Dracula", uuid = "88888888-8888-4888-8888-888888888888")))
        store.close()
        try {
            val app = testApp(scope, keychain = tokens, defaults = defaults)
            assertEquals(typed, app.serverAddress)

            app.restoreIfPossible()

            assertEquals("the typed address was replaced", typed, app.serverAddress)
            assertEquals(typed, defaults.getString(AppModel.LAST_SERVER_KEY))
            assertEquals("the session left the address the token is filed under", http, app.session?.serverUrl)
            assertEquals("the offline shelf was not shown", listOf("Dracula"), app.books.map { it.title })
            assertEquals(AppModel.Phase.READY, app.phase)
        } finally {
            scope.close()
        }
    }

    /** With no sign-in held for any candidate, an unreachable address stores nothing. */
    @Test
    fun `an unreachable address with no sign-in behind it stores nothing`() = mainTest {
        val scope = testScope()
        val defaults = SharedFixtures.scratchDefaults()
        val app = testApp(scope, defaults = defaults)

        app.connect("127.0.0.1:1")

        assertEquals("", app.serverAddress)
        assertEquals(null, defaults.getString(AppModel.LAST_SERVER_KEY))
        assertEquals(null, app.session)
        assertEquals(
            "Couldn't reach a Storyteller server at https://127.0.0.1:1 or http://127.0.0.1:1. Check the address, and that you're on the same network as the server.",
            app.loadError,
        )
        scope.close()
    }

    /**
     * Tokens for two servers, the stored address the first: typing the second
     * while it is down must not open its session over the first's address, where
     * stream URLs would carry the one server's token to the other.
     */
    @Test
    fun `a typed address that is not the stored one does not open offline on its stored sign-in`() = mainTest {
        val scope = testScope()
        val stored = "http://127.0.0.1:2"
        val typed = URI("http://127.0.0.1:1")
        val tokens = TestTokens()
        tokens.write("token-S", stored)
        tokens.write("token-T", typed.toString())
        val defaults = SharedFixtures.scratchDefaults()
        defaults.putString(AppModel.LAST_SERVER_KEY, stored)
        try {
            val app = testApp(scope, keychain = tokens, defaults = defaults)

            app.connect("127.0.0.1:1")

            assertEquals("the stored address moved", stored, app.serverAddress)
            assertEquals(stored, defaults.getString(AppModel.LAST_SERVER_KEY))
            assertEquals("a session opened for the server that did not answer", null, app.session)
            assertEquals(
                "Couldn't reach a Storyteller server at https://127.0.0.1:1 or http://127.0.0.1:1. Check the address, and that you're on the same network as the server.",
                app.loadError,
            )
        } finally {
            scope.close()
        }
    }

    /** A lone explicit address that differs from the stored one is adopted only once something answers there. */
    @Test
    fun `a lone explicit address that does not answer is not adopted`() = mainTest {
        val scope = testScope()
        val stored = "http://127.0.0.1:2"
        val defaults = SharedFixtures.scratchDefaults()
        defaults.putString(AppModel.LAST_SERVER_KEY, stored)
        try {
            val app = testApp(scope, defaults = defaults)

            app.connect("http://127.0.0.1:1")

            assertEquals(stored, app.serverAddress)
            assertEquals(stored, defaults.getString(AppModel.LAST_SERVER_KEY))
            assertEquals(null, app.session)
            assertEquals("Couldn't reach a Storyteller server at http://127.0.0.1:1. Check the address, and that you're on the same network as the server.", app.loadError)
        } finally {
            scope.close()
        }
    }

    // A device the address overwrite left behind

    /** A server on a socket of the test's own, and the same host and port spoken to as HTTPS, where it cannot answer. */
    private class Stranded(token: String) {
        val server = LifecycleServer()
        val http: URI = server.url
        val https = URI("https://${http.host}:${http.port}")
        val tokens = TestTokens().apply { write(token, http.toString()) }
        val defaults = SharedFixtures.scratchDefaults().apply { putString(AppModel.LAST_SERVER_KEY, https.toString()) }

        fun app(scope: kotlinx.coroutines.CoroutineScope): AppModel =
            testApp(scope, keychain = tokens, defaults = defaults, makeSession = { server.sessionFor(it, tokens) })
    }

    /**
     * Stored `https://host:P`, which speaks no TLS, and a sign-in saved under
     * `http://host:P`: the sign-in screen offers it, and until it is taken
     * nothing changes and no token goes anywhere.
     */
    @Test
    fun `a stored https address with no answer offers the http sign-in and sends nothing until it is taken`() = mainTest {
        val scope = testScope()
        val stranded = Stranded("token-A")
        try {
            val app = stranded.app(scope)

            app.restoreIfPossible()

            assertEquals(ServerAddress.CleartextOffer(tried = stranded.https, offered = stranded.http), app.cleartextOffer)
            assertEquals(AppModel.Phase.CHOOSE_SERVER, app.phase)
            assertNull("a session was opened before the reader chose one", app.session)
            assertEquals("the stored address moved", stranded.https.toString(), app.serverAddress)
            assertEquals(stranded.https.toString(), stranded.defaults.getString(AppModel.LAST_SERVER_KEY))
            assertEquals("token-A", stranded.tokens.read(stranded.http.toString()))
            assertNull(stranded.tokens.read(stranded.https.toString()))
            val sent = stranded.server.requests()
            assertTrue("the http address was not probed", sent.any { it.path == "/api/v2/server/public" })
            assertTrue("a token went to the http address before the reader chose it: $sent", sent.none { it.bearer != null })
            assertEquals(
                "Couldn't reach ${stranded.https}. This phone has a saved sign-in for ${stranded.http}, which is not encrypted.",
                SignInForm.offerText(app.cleartextOffer!!, noun = "phone"),
            )
            assertEquals("Use ${stranded.http} (not encrypted)", SignInForm.offerButton(app.cleartextOffer!!))
        } finally {
            stranded.server.close()
            scope.close()
        }
    }

    /** Taken, with a sign-in the server accepts: signed in over http, and the bare host stored so the next launch tries https first. */
    @Test
    fun `taking the offer signs in and stores the bare host`() = mainTest {
        val scope = testScope()
        val stranded = Stranded("token-A")
        try {
            val app = stranded.app(scope)
            app.restoreIfPossible()

            app.acceptCleartextOffer()

            assertEquals("reader-A", (app.session?.state?.value as? Session.State.SignedIn)?.user?.id)
            assertEquals(stranded.http, app.session?.serverUrl)
            assertEquals(AppModel.Phase.READY, app.phase)
            val bare = "${stranded.http.host}:${stranded.http.port}"
            assertEquals(bare, app.serverAddress)
            assertEquals(bare, stranded.defaults.getString(AppModel.LAST_SERVER_KEY))
            assertEquals("the bare host leads with https next time", stranded.https, ServerAddress.candidates(bare).first())
            assertNull(app.cleartextOffer)
            assertNull(app.loadError)
        } finally {
            stranded.server.close()
            scope.close()
        }
    }

    /** Taken, with a sign-in the server refuses: the stored address stays, and the error names the http address. */
    @Test
    fun `taking the offer with a refused sign-in leaves the stored address alone`() = mainTest {
        val scope = testScope()
        val stranded = Stranded("token-refused")
        try {
            val app = stranded.app(scope)
            app.restoreIfPossible()
            assertTrue(app.cleartextOffer != null)

            app.acceptCleartextOffer()

            assertEquals(stranded.https.toString(), app.serverAddress)
            assertEquals(stranded.https.toString(), stranded.defaults.getString(AppModel.LAST_SERVER_KEY))
            assertEquals(AppModel.Phase.CHOOSE_SERVER, app.phase)
            assertEquals(
                "Couldn't sign in to ${stranded.http}. Your server didn't accept the saved sign-in.",
                app.loadError,
            )
        } finally {
            stranded.server.close()
            scope.close()
        }
    }

    /**
     * A sign-in adopted over https deletes the one the same host's http
     * address held, and leaves another host's alone. Deleted, never revoked:
     * a revoke would send it in the clear.
     */
    @Test
    fun `adopting on https deletes the same host's http sign-in and no other`() = mainTest {
        val scope = testScope()
        val server = LifecycleServer()
        val http = server.url
        val https = URI("https://${http.host}:${http.port}")
        val elsewhere = "http://elsewhere.test:8001"
        val tokens = TestTokens()
        tokens.write("old-token", http.toString())
        tokens.write("other-token", elsewhere)
        // The https session's requests reach the stub over plain http: what is
        // under test is what the keychain keeps, not the TLS.
        val overPlainHttp = server.http.newBuilder().addInterceptor { chain ->
            val request = chain.request()
            chain.proceed(request.newBuilder().url(request.url.newBuilder().scheme("http").build()).build())
        }.build()
        try {
            val app = testApp(scope, keychain = tokens, makeSession = { Session(it, tokens, overPlainHttp) })
            app.session = Session(https, tokens, overPlainHttp)
            app.serverAddress = https.toString()

            app.adopt("token-A")

            assertEquals("reader-A", (app.session?.state?.value as? Session.State.SignedIn)?.user?.id)
            assertEquals("token-A", tokens.read(https.toString()))
            assertNull("the cleartext-era sign-in was left behind", tokens.read(http.toString()))
            assertEquals("another host's sign-in was deleted", "other-token", tokens.read(elsewhere))
            assertTrue("the old token was sent somewhere", server.requests().none { it.bearer == "old-token" })
        } finally {
            server.close()
            scope.close()
        }
    }

    /** The stored address itself, a lone explicit one, still opens its kept shelf with no server up. */
    @Test
    fun `the stored address opens offline from its stored sign-in`() = mainTest {
        val scope = testScope()
        val stored = "http://127.0.0.1:1"
        val tokens = TestTokens()
        tokens.write("token-S", stored)
        val defaults = SharedFixtures.scratchDefaults()
        defaults.putString(AppModel.LAST_SERVER_KEY, stored)
        try {
            val app = testApp(scope, keychain = tokens, defaults = defaults)

            app.restoreIfPossible()

            assertEquals(stored, app.serverAddress)
            assertEquals(URI(stored), app.session?.serverUrl)
        } finally {
            scope.close()
        }
    }
}
