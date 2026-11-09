package com.benjaminissa.issareader.app.model

import com.benjaminissa.issareader.app.Answer
import com.benjaminissa.issareader.app.AppSuite
import com.benjaminissa.issareader.app.SharedFixtures
import com.benjaminissa.issareader.app.StubServer
import com.benjaminissa.issareader.app.TestTokens
import com.benjaminissa.issareader.app.close
import com.benjaminissa.issareader.app.mainTest
import com.benjaminissa.issareader.app.testApp
import com.benjaminissa.issareader.app.testScope
import com.benjaminissa.issareader.core.KeyValueStore
import com.benjaminissa.issareader.core.model.Status
import com.benjaminissa.issareader.core.networking.Endpoint
import kotlinx.coroutines.CoroutineScope
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What happens when the token that comes back belongs to somebody else.
 * Ported from `AccountSwitchTests.swift`.
 *
 * A mismatch is not refused — a second reader on a shared tablet is
 * legitimate — but it is acted on: everything in memory belongs to the
 * previous account.
 */
class AccountSwitchTest : AppSuite() {
    /**
     * Answers `/api/v2/user` with the reader this server stands for, and 404
     * to everything else — so the library refresh that follows fails and
     * leaves the state this suite asserts on exactly as the switch left it.
     * (Swift carried the reader in the port; each server here is its own.)
     */
    private fun identifying(reader: Int) = StubServer { request ->
        if (request.path == Endpoint.user) Answer(200, """{"id":"reader-$reader"}""") else Answer(404)
    }

    private fun account(reader: Int) = "reader-$reader"

    /** A model already holding one account's things, with [server] recorded as last signed in by [previous]. */
    private fun model(scope: CoroutineScope, server: StubServer, previous: String, defaults: KeyValueStore = SharedFixtures.scratchDefaults()): AppModel {
        defaults.putString(AppModel.accountKey(server.url), previous)
        val app = testApp(scope, defaults = defaults)
        app.session = server.session(keychain = TestTokens())
        // Seeded, so the assertions that these are cleared are about the clearing.
        app.books = listOf(SharedFixtures.book("Dracula", uuid = "11111111-1111-4111-8111-111111111111"))
        app.statuses = listOf(Status(uuid = "reading", name = "Reading"))
        app.ratings = app.ratings + ("11111111-1111-4111-8111-111111111111" to 4.0)
        app.requestBook("11111111-1111-4111-8111-111111111111", AppModel.PendingBook.Destination.READ)
        return app
    }

    /** The whole finding: reader B adopts a token on a device reader A used. */
    @Test
    fun differentIdentityClearsTheAccountsThings() = mainTest {
        val scope = testScope()
        identifying(2).use { server ->
            val app = model(scope, server, account(1))
            assertNotNull("the link has to be armed for this to mean anything", app.pendingBook)
            val generation = app.catalogueGeneration

            app.adopt("a-token-belonging-to-reader-2")

            assertEquals("a refresh in flight would write reader 1's catalogue back", generation + 1, app.catalogueGeneration)
            assertNull("reader 1's widget tap opened in reader 2's library", app.pendingBook)
            assertTrue("reader 1's ratings were shown as reader 2's", app.ratings.isEmpty())
            assertTrue(app.books.isEmpty())
            assertTrue(app.statuses.isEmpty())
        }
        scope.close()
    }

    /** The same reader signing in again must not have their own library thrown away. */
    @Test
    fun sameIdentityKeepsEverything() = mainTest {
        val scope = testScope()
        identifying(1).use { server ->
            val app = model(scope, server, account(1))
            val generation = app.catalogueGeneration

            app.adopt("a-token-belonging-to-reader-1")

            assertEquals("the same reader is not a hand-over", generation, app.catalogueGeneration)
            assertNotNull("the reader's own pending link was discarded", app.pendingBook)
            assertFalse("the reader's own shelf was discarded", app.books.isEmpty())
            assertFalse(app.statuses.isEmpty())
            assertFalse("the reader's own ratings were discarded", app.ratings.isEmpty())
        }
        scope.close()
    }

    /** A first sign-in on this server has no previous account to differ from. */
    @Test
    fun noStoredAccountIsNotASwitch() = mainTest {
        val scope = testScope()
        identifying(3).use { server ->
            val app = testApp(scope)
            app.session = server.session()
            app.requestBook("11111111-1111-4111-8111-111111111111", AppModel.PendingBook.Destination.READ)

            app.adopt("a-first-token")

            assertNotNull("there was no previous account to hand over from", app.pendingBook)
        }
        scope.close()
    }
}
