package com.benjaminissa.issareader.app.model

import com.benjaminissa.issareader.app.AppSuite
import com.benjaminissa.issareader.app.SharedFixtures
import com.benjaminissa.issareader.app.TestTokens
import com.benjaminissa.issareader.app.mainTest
import com.benjaminissa.issareader.app.testApp
import com.benjaminissa.issareader.app.testScope
import com.benjaminissa.issareader.app.close
import com.benjaminissa.issareader.core.networking.ApiClient
import com.benjaminissa.issareader.core.store.LibraryStore
import kotlinx.coroutines.runBlocking
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import org.junit.Assert.assertEquals
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
        assertEquals("Couldn't reach a Storyteller server at that address.", app.loadError)
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
            assertEquals("Couldn't reach a Storyteller server at that address.", app.loadError)
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
            assertEquals("Couldn't reach a Storyteller server at that address.", app.loadError)
        } finally {
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
