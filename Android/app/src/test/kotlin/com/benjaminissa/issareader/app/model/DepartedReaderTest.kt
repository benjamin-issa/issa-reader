package com.benjaminissa.issareader.app.model

import androidx.compose.runtime.snapshots.Snapshot
import com.benjaminissa.issareader.app.Answer
import com.benjaminissa.issareader.app.AppSuite
import com.benjaminissa.issareader.app.StubServer
import com.benjaminissa.issareader.app.close
import com.benjaminissa.issareader.app.mainTest
import com.benjaminissa.issareader.app.testApp
import com.benjaminissa.issareader.app.testScope
import com.benjaminissa.issareader.app.waitUntil
import com.benjaminissa.issareader.app.reader.HandoffFixture
import com.benjaminissa.issareader.app.reader.ReaderModel
import com.benjaminissa.issareader.core.model.Annotation
import com.benjaminissa.issareader.core.model.AudioAnchor
import com.benjaminissa.issareader.core.model.ReadiumLocator
import com.benjaminissa.issareader.playback.ListeningHandoff
import kotlinx.coroutines.async
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.time.Duration.Companion.seconds

/**
 * A reader opened under one account writes nothing into the next one's, and
 * makes no sound under it. Ported from `DepartedReaderTests.swift`.
 *
 * An account's exit unregisters its open readers, and nothing more: the
 * reader's screen holds its model, and a same-server switch keeps the library
 * — and so the screen — up. Through the hooks `AppModel.reader(book, session)`
 * installs, fired the way the model fires them, against [LifecycleServer]
 * with the launch hand-over of [StoredTokenHandOverTest].
 */
class DepartedReaderTest : AppSuite() {
    private val first = HandOverFixture.first

    /**
     * The finding's scenario. Token B under a device reader A last used; the
     * reader is up on A's cached copy of a book when the launch's identity
     * call answers B. It saves, anchors and highlights — none of which may
     * land in B's account.
     */
    @Test
    fun aReaderOpenAcrossAHandOverWritesNothing() = mainTest {
        val fixture = HandOverFixture.storing("token-B")
        val app = fixture.app
        app.currentBookPublisher = CurrentBookPublisher(fixture.scope)
        app.phase = AppModel.Phase.READY
        val session = checkNotNull(app.session)
        val cached = checkNotNull(app.bookByUuid[first]) { "A's cached copy is what the reader opens" }
        val model = app.reader(cached, session)
        val opened = HandoffFixture.opened(model)
        try {
            app.resumeStoredSession()
            assertEquals("reader-B", HandOverFixture.reader(app.session))
            assertEquals("First, for reader-B", app.bookByUuid[first]?.title)

            // The screen's debounced save, an anchor and a highlight, all from
            // the model the screen still holds.
            model.saveProgress()
            model.recordAudioAnchor?.invoke(AudioAnchor(audioHref = "audio/1.mp3", offset = 12.0, writtenAt = 100.0))
            model.onSaveAnnotation?.invoke(
                Annotation(
                    bookUuid = first, kind = Annotation.Kind.HIGHLIGHT,
                    locator = ReadiumLocator(
                        href = "OEBPS/ch01.xhtml", type = "application/xhtml+xml",
                        locations = ReadiumLocator.Locations(progression = 0.1, totalProgression = 0.1),
                    ),
                    excerpt = "A's highlight",
                ),
            )
            app.drainPendingWrites(waitingForInFlight = true)

            assertTrue("A's place in the book was posted as B's", fixture.server.writes("token-B").isEmpty())
            assertNull("A's place was recorded on B's copy", app.bookByUuid[first]?.position)
            assertNull("B's copy was filed by A's reading", app.bookByUuid[first]?.status)
            assertNull("A's narration anchor was stored as B's", fixture.store.audioAnchor(first))
            val highlighted = waitUntil(within = 1.seconds) { app.annotations(first).isNotEmpty() }
            assertFalse("A's highlight was saved into B's account", highlighted)
        } finally {
            model.readalong?.player?.pause()
            opened.directory.deleteRecursively()
            fixture.tearDown()
        }
    }

    /**
     * The same model's narration. Its play button is still on screen, and a
     * read-along started from it used to play the departed account's book
     * with nothing tracking it: no mini player, no lock screen, no sleep timer.
     */
    @Test
    fun aDepartedReaderMakesNoSound() = mainTest {
        val fixture = HandOverFixture.storing("token-B")
        val app = fixture.app
        app.currentBookPublisher = CurrentBookPublisher(fixture.scope)
        app.phase = AppModel.Phase.READY
        val session = checkNotNull(app.session)
        val cached = checkNotNull(app.bookByUuid[first])
        val model = app.reader(cached, session)
        val opened = HandoffFixture.opened(model)
        val readalong = checkNotNull(model.readalong)
        try {
            app.resumeStoredSession()
            assertEquals("reader-B", HandOverFixture.reader(app.session))

            readalong.player.play()
            waitUntil { !readalong.player.isPlaying }

            assertFalse("the departed account's book played under the arriving one", readalong.player.isPlaying)
            assertNull(app.reader)
        } finally {
            readalong.player.pause()
            opened.directory.deleteRecursively()
            fixture.tearDown()
        }
    }

    /**
     * The hand-off's claim. A drive's book being handed to the reader when
     * the account leaves: the exit dropped the listening start's claim and
     * not this one, so the hand-off left the departed account's read-along
     * playing.
     */
    @Test
    fun anExitDuringAHandOffStandsItDown() = mainTest {
        val scope = testScope()
        val server = StubServer { Answer(404) }
        val app = testApp(scope)
        app.currentBookPublisher = CurrentBookPublisher(scope)
        val armed = HandoffFixture.armed(app, server.session(), scope)
        try {
            armed.coordinator.player.play()
            app.installListening(armed.coordinator, armed.book)

            val handOff = scope.async { app.handOffListeningToReader(ListeningHandoff.Trigger.CAR_DISCONNECTED) }
            yield()
            assertTrue("the hand-off has to be in flight", app.isHandingOffToReader(armed.book.uuid))

            app.signOut(keepDownloads = true)
            val decision = handOff.await()

            assertEquals(
                "the hand-off finished for an account that had left",
                ListeningHandoff.Decision.Skipped(ListeningHandoff.Skip.SLOT_CHANGED_HANDS), decision,
            )
            assertFalse(app.isHandingOffToReader(armed.book.uuid))
            assertEquals("the departed account's read-along was left playing", false, armed.model.readalong?.player?.isPlaying)
            assertNull(app.reader)
        } finally {
            armed.model.readalong?.player?.pause()
            armed.directory.deleteRecursively()
            server.close()
            scope.close()
        }
    }

    /**
     * The widget. The exit clears it and suspends its publisher, and the
     * arriving account's arrival lifts that — after which a re-open of the
     * departed reader put the departed account's book back on the home
     * screen, deep link and all, as the arriving account's.
     */
    @Test
    fun aDepartedReaderPublishesNothing() = mainTest {
        val fixture = HandOverFixture.storing("token-B")
        val app = fixture.app
        val publisher = CurrentBookPublisher(fixture.scope)
        app.currentBookPublisher = publisher
        app.phase = AppModel.Phase.READY
        val session = checkNotNull(app.session)
        val cached = checkNotNull(app.bookByUuid[first])
        val model = app.reader(cached, session)
        val opened = HandoffFixture.opened(model)
        try {
            // The control: while its account is signed in, the reader's
            // publish reaches the app's publisher.
            model.publishSnapshot(progress = 0.1)
            assertEquals("the reader has to publish through the app", CurrentBookPublisher.Owner.Reading(first), publisher.owner)

            app.resumeStoredSession()
            assertEquals("reader-B", HandOverFixture.reader(app.session))
            assertFalse("the arriving account's arrival lifts the suspension", publisher.isSuspended)
            assertNull("the exit forgets the snapshot", publisher.owner)

            model.publishSnapshot(progress = 0.4)

            assertNull("the departed account's book was published as the arriving one's", publisher.owner)
        } finally {
            opened.directory.deleteRecursively()
            fixture.tearDown()
        }
    }

    /** The listening engine's twin: an engine the exit took out of the slot publishes nothing afterwards. */
    @Test
    fun aDepartedAudiobookPublishesNothing() = mainTest {
        val scope = testScope()
        val server = StubServer { Answer(404) }
        val app = testApp(scope)
        val publisher = CurrentBookPublisher(scope)
        app.currentBookPublisher = publisher
        val armed = HandoffFixture.armed(app, server.session(), scope)
        try {
            app.installListening(armed.coordinator, armed.book)

            app.signOut(keepDownloads = true)
            publisher.resume()
            app.publishListeningSnapshot(armed.book, armed.coordinator)

            assertNull("an engine the account left published its book", publisher.owner)
        } finally {
            armed.directory.deleteRecursively()
            server.close()
            scope.close()
        }
    }

    /**
     * The reader's screen closes on `AppModel.hasLeft`, observed: this is
     * that decision, and that the hand-over is what moves it.
     */
    @Test
    fun theHandOverClosesTheDepartedReader() = mainTest {
        val fixture = HandOverFixture.storing("token-B")
        val app = fixture.app
        app.currentBookPublisher = CurrentBookPublisher(fixture.scope)
        app.phase = AppModel.Phase.READY
        val session = checkNotNull(app.session)
        val cached = checkNotNull(app.bookByUuid[first])
        val model = app.reader(cached, session)
        assertFalse("a reader open under the signed-in account stays", app.hasLeft(model))

        // What the screen observes, as a composition would.
        val read = HashSet<Any>()
        Snapshot.observe(readObserver = { read.add(it) }) { app.hasLeft(model) }
        var observed = false
        val handle = Snapshot.registerApplyObserver { changed, _ -> if (changed.any { it in read }) observed = true }
        try {
            app.resumeStoredSession()
            Snapshot.sendApplyNotifications()
            assertEquals("reader-B", HandOverFixture.reader(app.session))

            assertTrue("the departed account's reader stayed on screen", app.hasLeft(model))
            assertTrue("the screen was never told to look again", observed)
            // The arriving account opening the same book gets a reader of its
            // own, which stays.
            val arriving = checkNotNull(app.bookByUuid[first])
            val fresh = app.reader(arriving, checkNotNull(app.session))
            assertNotSame(model, fresh)
            assertFalse(app.hasLeft(fresh))
            // And a model no account opened — a book from the reader's own
            // files has no fence — is never one an account left.
            assertFalse(app.hasLeft(ReaderModel(cached, session, checkNotNull(app.readerServices))))
        } finally {
            handle.dispose()
            fixture.tearDown()
        }
    }
}
