package com.benjaminissa.issareader.app.model

import com.benjaminissa.issareader.app.Answer
import com.benjaminissa.issareader.app.AppSuite
import com.benjaminissa.issareader.app.LifecycleServer
import com.benjaminissa.issareader.app.PlaybackSettingsForTests
import com.benjaminissa.issareader.app.SharedFixtures
import com.benjaminissa.issareader.app.StubServer
import com.benjaminissa.issareader.app.TestTokens
import com.benjaminissa.issareader.app.close
import com.benjaminissa.issareader.app.mainTest
import com.benjaminissa.issareader.app.testApp
import com.benjaminissa.issareader.app.testScope
import com.benjaminissa.issareader.app.waitUntil
import com.benjaminissa.issareader.core.Session
import com.benjaminissa.issareader.core.download.BookContentService
import com.benjaminissa.issareader.core.model.Book
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.async
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.UUID

/**
 * What an account switch carries out, stands down and keeps on the way out.
 * Ported from `AccountExitTests.swift`: through `adopt` against
 * [LifecycleServer], a device signed in as reader A adopting reader B's token.
 */
class AccountExitTest : AppSuite() {
    class Fixture(val app: AppModel, val server: LifecycleServer, val scope: CoroutineScope) {
        val reader: String? get() = (app.session?.state?.value as? Session.State.SignedIn)?.user?.id

        fun tearDown() {
            server.close()
            scope.close()
        }
    }

    companion object {
        /** Reader A, signed in on a server of the test's own, which the device last signed in as A. */
        suspend fun signedInAsA(scope: CoroutineScope = com.benjaminissa.issareader.app.testScope()): Fixture {
            val server = LifecycleServer()
            val defaults = SharedFixtures.scratchDefaults()
            defaults.putString(AppModel.accountKey(server.url), "reader-A")
            val tokens = TestTokens()
            val app = testApp(scope, keychain = tokens, defaults = defaults, makeSession = { server.sessionFor(it, tokens) })
            val session = server.session(storing = "token-A", keychain = tokens)
            session.restore()
            app.session = session
            // What `connect` writes, and what `startListening` derives its URLs from.
            app.serverAddress = server.url.toString()
            val fixture = Fixture(app, server, scope)
            assertEquals("reader-A", fixture.reader)
            return fixture
        }

        /** A file in the app's download directory, under a uuid of its own. */
        fun plant(uuid: String, format: BookContentService.Format): File {
            val directory = BookContentService.defaultDirectory()
            directory.mkdirs()
            val file = BookContentService.localUrl(directory, uuid, format)
            file.writeBytes(ByteArray(32))
            return file
        }
    }

    /** The downloads on the device are still listed for the arriving account. */
    @Test
    fun downloadsAreStillListedAfterTheSwitch() = mainTest {
        val fixture = signedInAsA(testScope())
        try {
            val uuid = UUID.randomUUID().toString()
            plant(uuid, BookContentService.Format.EBOOK)
            fixture.app.refreshDownloadedSet()
            assertTrue(uuid in fixture.app.downloadedUuids)

            fixture.app.adopt("token-B")
            assertEquals("reader-B", fixture.reader)

            assertTrue("the arriving account was told a book on the device was not downloaded", uuid in fixture.app.downloadedUuids)
        } finally {
            fixture.tearDown()
        }
    }

    /** A removal inside its undo window is carried out before the next account arrives. */
    @Test
    fun aPendingRemovalIsCarriedOutOnTheSwitch() = mainTest {
        val fixture = signedInAsA(testScope())
        try {
            val uuid = UUID.randomUUID().toString()
            val file = plant(uuid, BookContentService.Format.EBOOK)
            fixture.app.refreshDownloadedSet()
            fixture.app.removeDownload(uuid, BookContentService.Format.EBOOK, "Dracula", undoWindowMillis = 600_000)
            assertEquals(uuid, fixture.app.pendingRemoval?.bookUuid)

            fixture.app.adopt("token-B")
            assertEquals("reader-B", fixture.reader)

            assertNull("the departed reader's toast, and their Undo, stood over the arriving reader's library", fixture.app.pendingRemoval)
            assertFalse("the removal was left to a timer firing in the arriving account's session", file.exists())
        } finally {
            fixture.tearDown()
        }
    }

    /** A start that has claimed a book is stood down by the switch. */
    @Test
    fun aClaimedStartIsDroppedOnTheSwitch() = mainTest {
        val fixture = signedInAsA(testScope())
        try {
            fixture.app.claimListeningStart(
                SharedFixtures.book("First", uuid = LifecycleServer.first, readaloud = true),
                BookContentService.Format.READALOUD,
            )

            fixture.app.adopt("token-B")
            assertEquals("reader-B", fixture.reader)

            assertNull("the departed account's start still held its book in the arriving account's session", fixture.app.startingListeningBook)
        } finally {
            fixture.tearDown()
        }
    }

    /** A start waiting on the server when the account changes attaches nothing and says nothing. */
    @Test
    fun aStartInFlightStandsDownAfterTheSwitch() = mainTest {
        val fixture = signedInAsA(testScope())
        try {
            val (listeningBook, listeningError) = startAcrossTheSwitch(fixture) {}
            assertNull(listeningBook)
            assertNull("the departed account's start reported into the arriving account's session", listeningError)
        } finally {
            fixture.tearDown()
        }
    }

    /** A claim on the same book after the switch does not let the departed start through. */
    @Test
    fun theAccountItBeganUnderStandsAStartDown() = mainTest {
        val fixture = signedInAsA(testScope())
        try {
            val (listeningBook, listeningError) = startAcrossTheSwitch(fixture) {
                fixture.app.claimListeningStart(SharedFixtures.book("First", uuid = LifecycleServer.first), null)
            }
            assertNull(listeningBook)
            assertNull("the departed account's start passed a claim the arriving account had made", listeningError)
        } finally {
            fixture.tearDown()
        }
    }

    /**
     * Starts reader A listening to the first book with its manifest held,
     * switches to reader B, runs [afterSwitch], then lets the manifest through
     * and waits for the start to finish.
     */
    private suspend fun startAcrossTheSwitch(fixture: Fixture, afterSwitch: () -> Unit): Pair<Book?, String?> {
        val app = fixture.app
        val manifest = LifecycleServer.manifestPath(LifecycleServer.first)
        fixture.server.hold(manifest)
        val settings = PlaybackSettingsForTests.make()
        val nowPlaying = NowPlayingController(fixture.scope)
        val book = SharedFixtures.book("First", uuid = LifecycleServer.first, audiobook = true)

        val starting = fixture.scope.async { app.startListening(book, nowPlaying, settings) }
        assertTrue("A's start has to be waiting on the manifest", waitUntil { fixture.server.held(manifest) == 1 })
        assertEquals(book.uuid, app.startingListeningBook)

        app.adopt("token-B")
        assertEquals("reader-B", fixture.reader)
        afterSwitch()

        fixture.server.release(manifest)
        starting.await()
        return app.listeningBook to app.listeningError
    }
}

/**
 * A token the server will not accept has to say so. Ported from
 * `AdoptRefusedTests.swift`.
 */
class AdoptRefusedTest : AppSuite() {
    private fun model(scope: CoroutineScope, status: Int): Pair<AppModel, StubServer> {
        val server = StubServer { Answer(status, "{}") }
        val app = testApp(scope)
        app.session = server.session()
        return app to server
    }

    /** A refused token leaves a reason on the chooser, not a blank one. */
    @Test
    fun refusedTokenExplainsItself() = mainTest {
        val scope = testScope()
        val (app, server) = model(scope, 401)
        try {
            app.adopt("stale")

            assertEquals("the token really was refused", Session.State.SignedOut, app.session?.state?.value)
            assertEquals(AppModel.Phase.CHOOSE_SERVER, app.phase)
            val reason = assertNotNullAndGet("and the chooser says why, rather than reappearing in silence", app.loadError)
            assertFalse(reason.isEmpty())
        } finally {
            server.close()
            scope.close()
        }
    }

    /** An identity call that fails outright also carries its reason. */
    @Test
    fun failedIdentityExplainsItself() = mainTest {
        val scope = testScope()
        val (app, server) = model(scope, 500)
        try {
            app.adopt("whatever")

            assertEquals(AppModel.Phase.CHOOSE_SERVER, app.phase)
            assertFalse(assertNotNullAndGet("the failure has a reason", app.loadError).isEmpty())
        } finally {
            server.close()
            scope.close()
        }
    }

    /** A token adopted with no session says so. */
    @Test
    fun noSession() = mainTest {
        val scope = testScope()
        val app = testApp(scope)
        app.session = null
        app.adopt("orphan")

        assertEquals(AppModel.Phase.CHOOSE_SERVER, app.phase)
        assertFalse(assertNotNullAndGet("an orphaned token went nowhere silently", app.loadError).isEmpty())
        scope.close()
    }

    private fun <T : Any> assertNotNullAndGet(message: String, value: T?): T {
        assertNotNull(message, value)
        return value!!
    }
}
