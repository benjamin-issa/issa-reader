package com.benjaminissa.issareader.app.model

import com.benjaminissa.issareader.app.AppSuite
import com.benjaminissa.issareader.app.LifecycleServer
import com.benjaminissa.issareader.app.SharedFixtures
import com.benjaminissa.issareader.app.TestTokens
import com.benjaminissa.issareader.app.close
import com.benjaminissa.issareader.app.mainTest
import com.benjaminissa.issareader.app.temporaryDirectory
import com.benjaminissa.issareader.app.testApp
import com.benjaminissa.issareader.app.testScope
import com.benjaminissa.issareader.app.waitUntil
import com.benjaminissa.issareader.core.IssaJson
import com.benjaminissa.issareader.core.KeyValueStore
import com.benjaminissa.issareader.core.Session
import com.benjaminissa.issareader.core.model.ReadiumLocator
import com.benjaminissa.issareader.core.model.ServerGeneration
import com.benjaminissa.issareader.core.model.Status
import com.benjaminissa.issareader.core.networking.Endpoint
import com.benjaminissa.issareader.core.store.LibraryStore
import com.benjaminissa.issareader.core.sync.MutationDrain
import com.benjaminissa.issareader.core.sync.MutationQueue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.async
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File
import kotlin.time.Duration.Companion.seconds

/** A device reader A used on a server, as `connect` leaves it just before the restore. */
class HandOverFixture(
    val app: AppModel,
    val server: LifecycleServer,
    val store: LibraryStore,
    val directory: File,
    val defaults: KeyValueStore,
    val scope: CoroutineScope,
) {
    val accountKey: String get() = AppModel.accountKey(server.url)

    suspend fun queued(): List<MutationQueue.Pending> = MutationQueue(store).use { it.pending() }

    fun tearDown() {
        server.close()
        directory.deleteRecursively()
        scope.close()
    }

    companion object {
        val first = LifecycleServer.first
        val second = LifecycleServer.second

        fun reader(session: Session?): String? = (session?.state?.value as? Session.State.SignedIn)?.user?.id

        fun locator(progress: Double) = ReadiumLocator(
            href = "OEBPS/ch09.xhtml", type = "application/xhtml+xml",
            locations = ReadiumLocator.Locations(progression = progress, totalProgression = progress),
        )

        /**
         * A device reader A used on this server, with [token] in the keychain.
         * A's things are seeded everywhere they live — a cached shelf with A's
         * place and status, a rating, and one queued write of each kind — so
         * every assertion that they went is about their going.
         */
        suspend fun storing(token: String): HandOverFixture {
            val scope = testScope()
            val server = LifecycleServer()
            val defaults = SharedFixtures.scratchDefaults()
            defaults.putString(AppModel.accountKey(server.url), "reader-A")
            val directory = temporaryDirectory("stored-token")
            val store = LibraryStore(server.url.toString(), directory)
            store.setAccount("reader-A")
            store.replaceCatalogue(
                listOf(
                    SharedFixtures.book("First (A's copy)", uuid = first, status = Status.readingName, progress = 0.6, positionTimestamp = 50.0),
                    SharedFixtures.book("Second (A's copy)", uuid = second, progress = 0.3, positionTimestamp = 50.0),
                ),
            )
            store.replaceRatings(mapOf(first to 4.0))
            MutationQueue(store).use { queue ->
                queue.enqueue(
                    MutationQueue.Kind.POSITION, first,
                    IssaJson.encodeToString(MutationDrain.PositionPayload.serializer(), MutationDrain.PositionPayload(locator(0.6), 50.0)).encodeToByteArray(),
                    supersedes = 50.0,
                )
                queue.enqueue(
                    MutationQueue.Kind.STATUS, second,
                    IssaJson.encodeToString(MutationDrain.StatusPayload.serializer(), MutationDrain.StatusPayload("status-read")).encodeToByteArray(),
                )
                queue.enqueue(
                    MutationQueue.Kind.RATING, first,
                    IssaJson.encodeToString(MutationDrain.RatingPayload.serializer(), MutationDrain.RatingPayload(4.0)).encodeToByteArray(),
                )
            }
            val app = testApp(scope, defaults = defaults)
            app.useStore(store)
            app.session = server.session(storing = token, keychain = TestTokens())
            // What `connect` shows before it asks: the cached shelf, and the ratings read back with it.
            app.books = store.allBooks()
            app.ratings = store.ratings()
            app.rebuildDerived()
            return HandOverFixture(app, server, store, directory, defaults, scope)
        }

        /** What an offline launch leaves: the token restored and its identity call failed, the cached shelf on screen. */
        suspend fun failedLaunch(token: String): HandOverFixture {
            val fixture = storing(token)
            fixture.server.answerIdentity(listOf(404))
            val session = checkNotNull(fixture.app.session)
            session.restore()
            if (session.state.value !is Session.State.Failed) {
                fail("the launch's identity call has to have failed, not ${session.state.value}")
            }
            fixture.app.phase = AppModel.Phase.READY
            return fixture
        }
    }
}

/**
 * A token read back from the token store is handed over like one just
 * adopted. Ported from `StoredTokenHandOverTests.swift`.
 */
class StoredTokenHandOverTest : AppSuite() {
    private val first = HandOverFixture.first

    /** A stored token that is another account's is handed over before the library opens. */
    @Test
    fun aStoredTokenForAnotherAccountIsHandedOver() = mainTest {
        val fixture = HandOverFixture.storing("token-B")
        try {
            val generation = fixture.app.catalogueGeneration

            fixture.app.resumeStoredSession()
            fixture.app.drainPendingWrites(waitingForInFlight = true)

            assertEquals("reader-B", HandOverFixture.reader(fixture.app.session))
            assertEquals(AppModel.Phase.READY, fixture.app.phase)
            assertTrue("A's queued writes went out with B's token", fixture.server.writes("token-B").isEmpty())
            assertTrue("A's queue outlived the hand-over", fixture.queued().isEmpty())
            assertEquals("a refresh of A's in flight would write A's catalogue back", generation + 1, fixture.app.catalogueGeneration)
            assertTrue("A's rating was shown as B's", fixture.app.ratings.isEmpty())
            val arrived = checkNotNull(fixture.app.bookByUuid[first]) { "B's catalogue has to have landed" }
            assertEquals("First, for reader-B", arrived.title)
            assertNull("A's place in the book was kept on B's copy", arrived.position)
            assertEquals("reader-B", fixture.defaults.getString(fixture.accountKey))
            val storeCleared = waitUntil(5.seconds) { runCatching { fixture.store.ratings() }.getOrDefault(emptyMap()).isEmpty() }
            assertTrue("A's rating was persisted as B's", storeCleared)
        } finally {
            fixture.tearDown()
        }
    }

    /** A drain asked for while the stored token is identified sends nothing. */
    @Test
    fun aDrainDuringTheRestoreWaitsForTheIdentity() = mainTest {
        val fixture = HandOverFixture.storing("token-B")
        try {
            fixture.server.hold(Endpoint.user)

            val resuming = fixture.scope.async { fixture.app.resumeStoredSession() }
            assertTrue("the identity call has to be in flight", waitUntil { fixture.server.held(Endpoint.user) == 1 })

            fixture.app.drainPendingWrites()
            assertTrue("A's rows went out before anyone knew whose token it was", fixture.server.writes("token-B").isEmpty())

            fixture.server.release(Endpoint.user)
            resuming.await()
            fixture.app.drainPendingWrites(waitingForInFlight = true)

            assertEquals("reader-B", HandOverFixture.reader(fixture.app.session))
            assertTrue("A's queued writes went out with B's token", fixture.server.writes("token-B").isEmpty())
            assertTrue(fixture.queued().isEmpty())
        } finally {
            fixture.tearDown()
        }
    }

    /** The same account's stored token keeps its library and sends its own writes. */
    @Test
    fun theSameAccountKeepsItsLibrary() = mainTest {
        val fixture = HandOverFixture.storing("token-A")
        try {
            val generation = fixture.app.catalogueGeneration

            fixture.app.resumeStoredSession()
            fixture.app.drainPendingWrites(waitingForInFlight = true)

            assertEquals("reader-A", HandOverFixture.reader(fixture.app.session))
            assertEquals("the same reader is not a hand-over", generation, fixture.app.catalogueGeneration)
            assertEquals("the reader's own queued writes are theirs to send", 3, fixture.server.writes("token-A").size)
            assertEquals("the reader's own rating was discarded", 4.0, fixture.app.ratings[first])
            val kept = checkNotNull(fixture.app.bookByUuid[first])
            assertEquals("the reader's own place was discarded", 0.6, kept.position?.locator?.totalProgression)
        } finally {
            fixture.tearDown()
        }
    }
}

/**
 * A session whose identity call got no answer is asked again by the next
 * refresh. Ported from `ReidentifyTests.swift`.
 */
class ReidentifyTest : AppSuite() {
    /** A refresh asks again, and a session that answers is signed in and probed. */
    @Test
    fun aRefreshIdentifiesTheSession() = mainTest {
        val fixture = HandOverFixture.failedLaunch("token-A")
        try {
            val session = checkNotNull(fixture.app.session)
            assertNull("the launch cannot have probed anything", session.capabilities.value.generation)

            fixture.app.refreshLibrary()

            assertEquals("the session stayed unidentified however well its refresh went", "reader-A", HandOverFixture.reader(fixture.app.session))
            assertTrue(
                "Settings would go on saying nothing about the server",
                waitUntil { fixture.app.session?.capabilities?.value?.generation == ServerGeneration.V3 },
            )
            assertEquals("the refresh itself has to go on", "First, for reader-A", fixture.app.bookByUuid[HandOverFixture.first]?.title)
        } finally {
            fixture.tearDown()
        }
    }

    /** A refresh the server refuses the token for shows the expired notice. */
    @Test
    fun aRefusedTokenShowsTheExpiredNotice() = mainTest {
        val fixture = HandOverFixture.failedLaunch("token-A")
        try {
            fixture.server.answerIdentity(listOf(401))

            fixture.app.refreshLibrary()

            assertEquals(Session.State.Expired, fixture.app.session?.state?.value)
            assertEquals("a dead session went on presenting a signed-in library", AppModel.Phase.EXPIRED, fixture.app.phase)
            assertFalse(
                "the catalogue was asked for with a token the server had just refused",
                fixture.server.requests().any { it.path == Endpoint.books },
            )
        } finally {
            fixture.tearDown()
        }
    }

    /** A refresh that finds the token is another account's hands over before anything is sent. */
    @Test
    fun aRefreshThatFindsAnotherAccountHandsOver() = mainTest {
        val fixture = HandOverFixture.failedLaunch("token-B")
        try {
            fixture.app.refreshLibrary()
            fixture.app.drainPendingWrites(waitingForInFlight = true)

            assertEquals("reader-B", HandOverFixture.reader(fixture.app.session))
            assertTrue("A's queued writes went out with B's token", fixture.server.writes("token-B").isEmpty())
            assertTrue("A's queue outlived the hand-over", fixture.queued().isEmpty())
            assertTrue("A's rating was shown as B's", fixture.app.ratings.isEmpty())
            assertNull("A's place in the book was kept on B's copy", fixture.app.bookByUuid[HandOverFixture.first]?.position)
            assertEquals("the next identity would be compared with the departed account", "reader-B", fixture.defaults.getString(fixture.accountKey))
        } finally {
            fixture.tearDown()
        }
    }

    /** A session still without an answer refreshes as it always has. */
    @Test
    fun aStillUnansweredSessionRefreshesAsBefore() = mainTest {
        val fixture = HandOverFixture.failedLaunch("token-A")
        try {
            fixture.server.answerIdentity(listOf(404))

            fixture.app.refreshLibrary()

            val state = fixture.app.session?.state?.value
            assertTrue("the session should still be failed, not $state", state is Session.State.Failed)
            assertEquals(AppModel.Phase.READY, fixture.app.phase)
            assertTrue(fixture.server.requests().any { it.path == Endpoint.books })
        } finally {
            fixture.tearDown()
        }
    }
}

/**
 * What an account's exit leaves the device holding for the next one: the
 * widget's writer working again, and no request of the departed reader's
 * waiting to be delivered. Ported from `HandOverDeviceStateTests.swift`.
 */
class HandOverDeviceStateTest : AppSuite() {
    /** A model with a publisher of its own, resumed as `connect` resumes it. */
    private fun ownPublisher(fixture: HandOverFixture): CurrentBookPublisher {
        val publisher = CurrentBookPublisher(fixture.scope)
        publisher.resume()
        fixture.app.currentBookPublisher = publisher
        return publisher
    }

    /** R-12: the launch's hand-over leaves the widget writable for the arriving account. */
    @Test
    fun theLaunchHandOverResumesThePublisher() = mainTest {
        val fixture = HandOverFixture.storing("token-B")
        try {
            val publisher = ownPublisher(fixture)
            fixture.app.resumeStoredSession()
            assertEquals("reader-B", HandOverFixture.reader(fixture.app.session))
            assertFalse("B's widget stays empty for the rest of the process", publisher.isSuspended)
        } finally {
            fixture.tearDown()
        }
    }

    /** A sign-in's hand-over leaves the widget writable for the arriving account. */
    @Test
    fun theAdoptHandOverResumesThePublisher() = mainTest {
        val fixture = HandOverFixture.storing("token-A")
        try {
            val publisher = ownPublisher(fixture)
            fixture.app.adopt("token-B")
            assertEquals("reader-B", HandOverFixture.reader(fixture.app.session))
            assertFalse("B's widget stays empty for the rest of the process", publisher.isSuspended)
        } finally {
            fixture.tearDown()
        }
    }

    /** A refresh's hand-over leaves the widget writable for the arriving account. */
    @Test
    fun theRefreshHandOverResumesThePublisher() = mainTest {
        val fixture = HandOverFixture.failedLaunch("token-B")
        try {
            val publisher = ownPublisher(fixture)
            fixture.app.refreshLibrary()
            assertEquals("reader-B", HandOverFixture.reader(fixture.app.session))
            assertFalse("B's widget stays empty for the rest of the process", publisher.isSuspended)
        } finally {
            fixture.tearDown()
        }
    }

    /** The control: a sign-out leaves the widget suspended. */
    @Test
    fun aSignOutKeepsThePublisherSuspended() = mainTest {
        val fixture = HandOverFixture.storing("token-A")
        try {
            val publisher = ownPublisher(fixture)
            fixture.app.resumeStoredSession()
            fixture.app.signOut(keepDownloads = true)
            assertTrue(publisher.isSuspended)
        } finally {
            fixture.tearDown()
        }
    }

    /** R-17: a "continue reading" left for the departed account is not delivered to the arriving one. */
    @Test
    fun anIntentRequestGoesWithTheAccount() = mainTest {
        val fixture = HandOverFixture.storing("token-B")
        try {
            fixture.app.currentBookPublisher = CurrentBookPublisher(fixture.scope)
            val inbox = AppIntentInbox()
            fixture.app.intentInbox = inbox
            inbox.bookId = HandOverFixture.first

            fixture.app.resumeStoredSession()

            assertEquals("reader-B", HandOverFixture.reader(fixture.app.session))
            assertNull("B's library would open into the book A asked for", inbox.bookId)
        } finally {
            fixture.tearDown()
        }
    }

    /** The control: the same reader's own request survives their own launch. */
    @Test
    fun theSameAccountKeepsItsRequest() = mainTest {
        val fixture = HandOverFixture.storing("token-A")
        try {
            fixture.app.currentBookPublisher = CurrentBookPublisher(fixture.scope)
            val inbox = AppIntentInbox()
            fixture.app.intentInbox = inbox
            inbox.bookId = HandOverFixture.first

            fixture.app.resumeStoredSession()

            assertEquals(HandOverFixture.first, inbox.bookId)
        } finally {
            fixture.tearDown()
        }
    }
}

/**
 * Nothing goes out with a token until the server has said whose it is, and an
 * answer about a session that has since been replaced changes nothing.
 * Ported from `IdentityGateTests.swift`.
 */
class IdentityGateTest : AppSuite() {
    /** R-03: a launch whose identity call failed sends nothing queued. */
    @Test
    fun aFailedLaunchSendsNothingQueued() = mainTest {
        val fixture = HandOverFixture.storing("token-B")
        try {
            fixture.app.phase = AppModel.Phase.READY
            fixture.server.answerIdentity(listOf(404))

            fixture.app.resumeStoredSession()
            val state = fixture.app.session?.state?.value
            assertTrue("the launch's identity call has to have failed, not $state", state is Session.State.Failed)
            fixture.app.drainPendingWrites(waitingForInFlight = true)

            assertTrue("A's queued writes went out with a token nobody had identified", fixture.server.writes("token-B").isEmpty())
            assertEquals("A's rows are A's, kept until someone knows", 3, fixture.queued().size)
        } finally {
            fixture.tearDown()
        }
    }

    /** The network coming back asks whose token it is before sending anything. */
    @Test
    fun comingBackOnlineIdentifiesFirst() = mainTest {
        val fixture = HandOverFixture.storing("token-B")
        try {
            fixture.app.phase = AppModel.Phase.READY
            fixture.server.answerIdentity(listOf(404))
            fixture.app.resumeStoredSession()
            assertEquals("the cached shelf stays up through a failed launch", AppModel.Phase.READY, fixture.app.phase)

            val online = checkNotNull(fixture.app.reachability.onBecameOnline)
            online()
            val handedOver = waitUntil {
                HandOverFixture.reader(fixture.app.session) == "reader-B" &&
                    fixture.app.bookByUuid[HandOverFixture.first]?.title == "First, for reader-B"
            }
            fixture.app.drainPendingWrites(waitingForInFlight = true)

            assertTrue("A's queued writes went out with B's token when the network came back", fixture.server.writes("token-B").isEmpty())
            assertTrue("nothing asked whose token it was once the server could answer", handedOver)
            assertTrue("A's queue outlived the hand-over", fixture.queued().isEmpty())
        } finally {
            fixture.tearDown()
        }
    }

    /** The same account's writes go once the network comes back. */
    @Test
    fun theSameAccountsWritesGoWhenOnline() = mainTest {
        val fixture = HandOverFixture.storing("token-A")
        try {
            fixture.app.phase = AppModel.Phase.READY
            fixture.server.answerIdentity(listOf(404))
            fixture.app.resumeStoredSession()

            val online = checkNotNull(fixture.app.reachability.onBecameOnline)
            online()
            val sent = waitUntil { fixture.server.writes("token-A").size == 3 }

            assertTrue("the reader's own writes never left once the server could be asked", sent)
            assertEquals("reader-A", HandOverFixture.reader(fixture.app.session))
        } finally {
            fixture.tearDown()
        }
    }

    /** R-35: a restore's identity answering after a sign-out leaves the reader signed out. */
    @Test
    fun aRestoreAnsweringAfterSignOutChangesNothing() = mainTest {
        val fixture = HandOverFixture.storing("token-A")
        try {
            fixture.app.phase = AppModel.Phase.READY
            fixture.server.hold(Endpoint.user)

            val resuming = fixture.scope.async { fixture.app.resumeStoredSession() }
            assertTrue("the identity call has to be in flight", waitUntil { fixture.server.held(Endpoint.user) == 1 })

            fixture.app.signOut(keepDownloads = true)
            assertEquals(AppModel.Phase.CHOOSE_SERVER, fixture.app.phase)
            fixture.server.release(Endpoint.user)
            resuming.await()

            assertEquals("a sign-out was undone by an identity call it had outlived", AppModel.Phase.CHOOSE_SERVER, fixture.app.phase)
            assertNull(fixture.app.session)
            assertFalse("a library was fetched for a reader who had signed out", fixture.server.requests().any { it.path == Endpoint.books })
        } finally {
            fixture.tearDown()
        }
    }

    /** An adopt's identity answering after a sign-out leaves the reader signed out. */
    @Test
    fun anAdoptAnsweringAfterSignOutChangesNothing() = mainTest {
        val fixture = HandOverFixture.storing("token-A")
        try {
            fixture.app.phase = AppModel.Phase.SIGNING_IN
            fixture.server.hold(Endpoint.user)

            val adopting = fixture.scope.async { fixture.app.adopt("token-A") }
            assertTrue("the identity call has to be in flight", waitUntil { fixture.server.held(Endpoint.user) == 1 })

            fixture.app.signOut(keepDownloads = true)
            fixture.server.release(Endpoint.user)
            adopting.await()

            assertEquals("a sign-out was undone by an identity call it had outlived", AppModel.Phase.CHOOSE_SERVER, fixture.app.phase)
            assertNull("the form was given a reason that belongs to nothing", fixture.app.loadError)
            assertFalse(fixture.server.requests().any { it.path == Endpoint.books })
        } finally {
            fixture.tearDown()
        }
    }

    /** R-39: a refresh does not wait on another session's identity call, and asks its own. */
    @Test
    fun aRefreshAsksItsOwnSession() = mainTest {
        val fixture = HandOverFixture.failedLaunch("token-A")
        val other = LifecycleServer()
        val otherDirectory = temporaryDirectory("reidentify-other")
        try {
            fixture.server.hold(Endpoint.user)
            val stuck = fixture.scope.async { fixture.app.refreshLibrary() }
            assertTrue("the first session's re-identify has to be in flight", waitUntil { fixture.server.held(Endpoint.user) == 1 })

            // Signed out, and into another server whose launch failed the same way.
            fixture.app.signOut(keepDownloads = true)
            fixture.app.useStore(LibraryStore(other.url.toString(), otherDirectory))
            val session = other.session(storing = "token-B", keychain = TestTokens())
            fixture.app.session = session
            other.answerIdentity(listOf(404))
            session.restore()
            fixture.app.phase = AppModel.Phase.READY

            var finished = false
            val refreshing = fixture.scope.async {
                fixture.app.refreshLibrary()
                finished = true
            }
            val done = waitUntil(5.seconds) { finished }

            assertTrue("the arriving session's refresh waited on the departed session's identity call", done)
            // Let the departed session's call go, so nothing is left hanging.
            fixture.server.release(Endpoint.user)
            stuck.await()
            refreshing.await()
            assertEquals("the arriving session was let through without being asked whose token it held", "reader-B", HandOverFixture.reader(session))
        } finally {
            other.close()
            otherDirectory.deleteRecursively()
            fixture.tearDown()
        }
    }
}
