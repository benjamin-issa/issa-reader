package com.benjaminissa.issareader.app.model

import com.benjaminissa.issareader.app.AppSuite
import com.benjaminissa.issareader.app.ScriptedServer
import com.benjaminissa.issareader.app.SharedFixtures
import com.benjaminissa.issareader.app.TestTokens
import com.benjaminissa.issareader.app.close
import com.benjaminissa.issareader.app.mainTest
import com.benjaminissa.issareader.app.temporaryDirectory
import com.benjaminissa.issareader.app.testApp
import com.benjaminissa.issareader.app.testDownloads
import com.benjaminissa.issareader.app.testScope
import com.benjaminissa.issareader.app.waitUntil
import com.benjaminissa.issareader.core.download.BookContentService
import com.benjaminissa.issareader.core.download.DownloadManager
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.networking.StorytellerError
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

/**
 * A download the Wi-Fi-only preference holds back is said so, against the
 * edition that was asked for. Ported from `DownloadRefusalTests.swift`.
 *
 * With a real `DownloadManager` on a backend of the test's own that never
 * starts a transfer — every download here is refused before it would — and
 * the connection made metered through the model's seam.
 */
class DownloadRefusalTest : AppSuite() {
    class Fixture(
        val app: AppModel,
        val server: ScriptedServer,
        val manager: DownloadManager,
        val scope: CoroutineScope,
        val directory: File,
    ) {
        fun tearDown() {
            manager.stop()
            server.close()
            directory.deleteRecursively()
            scope.close()
        }
    }

    companion object {
        const val uuid = "44444444-4444-4444-8444-444444444444"
        val job = DownloadManager.Job(uuid, BookContentService.Format.READALOUD)
        const val expectedReason = "Waiting for Wi-Fi to download this."

        /** Wi-Fi only, on a metered connection, with a book whose read-along reports no size — which the rule takes for a large one. */
        fun fixture(scope: CoroutineScope): Fixture {
            val server = ScriptedServer()
            val tokens = TestTokens()
            val app = testApp(scope, keychain = tokens)
            val session = server.session(storing = "token-A", keychain = tokens)
            app.session = session
            val scratch = temporaryDirectory("download-refusal")
            val manager = testDownloads(server.url, session.tokenProvider, scope, scratch)
            manager.wifiOnly = true
            app.useDownloads(manager)
            app.meteredNetworkOverride = true
            app.books = listOf(SharedFixtures.book("Dracula", uuid = uuid, readaloud = true))
            app.rebuildDerived()
            return Fixture(app, server, manager, scope, scratch)
        }

        /**
         * The fixture's book, reporting a size no device has room for: a retry
         * that reaches the manager's start fails at its free-space check rather
         * than sending anything to a network.
         */
        fun unfittable(app: AppModel): Book {
            val book = checkNotNull(app.bookByUuid[uuid])
            val huge = book.copy(readaloud = book.readaloud?.copy(fileSize = 1L shl 60))
            app.books = listOf(huge)
            app.rebuildDerived()
            return huge
        }
    }

    /** A refused download is listed against its edition, and the library error is left alone. */
    @Test
    fun aRefusalIsTheJobsNotTheLibrarys() = mainTest {
        val fixture = fixture(testScope())
        try {
            val app = fixture.app
            val book = checkNotNull(app.bookByUuid[uuid])

            val started = app.download(book, BookContentService.Format.READALOUD)

            assertFalse(started)
            assertNull("the refusal went to the library error, hiding half the Downloads screen", app.loadError)
            assertEquals(expectedReason, app.downloadRefusals[job])
            val row = app.downloadsPending.firstOrNull { it.first == job }
            assertEquals("the Downloads screen had nothing to show for the tap", DownloadManager.State.Failed(expectedReason), row?.second)
            assertNull("and nothing was started", fixture.manager.state(job))
        } finally {
            fixture.tearDown()
        }
    }

    /** The reader's own open, which waits for the file, says why it will not come. */
    @Test
    fun waitingForARefusedDownloadThrowsTheRefusal() = mainTest {
        val fixture = fixture(testScope())
        try {
            val app = fixture.app
            val book = checkNotNull(app.bookByUuid[uuid])
            try {
                app.downloadAndWait(book, BookContentService.Format.READALOUD) { _, _ -> }
                fail("a refused download cannot have arrived")
            } catch (error: StorytellerError.Download) {
                assertEquals(expectedReason, error.reason)
            }
            assertNull(app.loadError)
        } finally {
            fixture.tearDown()
        }
    }

    /** The row's X, which is `cancelDownload`, takes a refusal off the list as it takes a transfer. */
    @Test
    fun cancellingARefusalClearsIt() = mainTest {
        val fixture = fixture(testScope())
        try {
            val app = fixture.app
            val book = checkNotNull(app.bookByUuid[uuid])
            app.download(book, BookContentService.Format.READALOUD)
            assertNotNull(app.downloadRefusals[job])

            app.cancelDownload(job)

            assertTrue(app.downloadRefusals.isEmpty())
            assertFalse(app.downloadsPending.any { it.first == job })
        } finally {
            fixture.tearDown()
        }
    }

    /** A job is a book uuid and an edition, which the next account shares; the refusal was said to the reader who asked. */
    @Test
    fun aRefusalGoesWithTheAccount() = mainTest {
        val fixture = fixture(testScope())
        try {
            val app = fixture.app
            val book = checkNotNull(app.bookByUuid[uuid])
            app.download(book, BookContentService.Format.READALOUD)
            assertNotNull(app.downloadRefusals[job])

            app.signOut(keepDownloads = true)

            assertTrue(app.downloadRefusals.isEmpty())
            assertTrue(app.downloadsPending.isEmpty())
        } finally {
            fixture.tearDown()
        }
    }

    /** "Waiting for Wi-Fi to download this." Joining Wi-Fi has to start it. */
    @Test
    fun aRefusalIsRetriedOnAnUnmeteredConnection() = mainTest {
        val fixture = fixture(testScope())
        try {
            val app = fixture.app
            val book = unfittable(app)
            app.download(book, BookContentService.Format.READALOUD)
            assertNotNull(app.downloadRefusals[job])

            app.meteredNetworkOverride = false
            val retried = waitUntil(5.seconds) { fixture.manager.state(job) != null }

            assertTrue("the download the note said was waiting for Wi-Fi never started on Wi-Fi", retried)
            assertNull("the note still says it is waiting", app.downloadRefusals[job])
        } finally {
            fixture.tearDown()
        }
    }

    /** Switching Wi-Fi only off in Downloads is the reader lifting the rule. */
    @Test
    fun aRefusalIsRetriedWhenTheRuleIsLifted() = mainTest {
        val fixture = fixture(testScope())
        try {
            val app = fixture.app
            val book = unfittable(app)
            app.download(book, BookContentService.Format.READALOUD)
            assertNotNull(app.downloadRefusals[job])

            app.wifiOnlyDownloads = false
            val retried = waitUntil(5.seconds) { fixture.manager.state(job) != null }

            assertTrue("turning the rule off left its refusal waiting", retried)
            assertNull(app.downloadRefusals[job])
        } finally {
            fixture.tearDown()
        }
    }

    /** The control: still metered, still Wi-Fi only — nothing moves. */
    @Test
    fun aRefusalStaysWhileTheRuleApplies() = mainTest {
        val fixture = fixture(testScope())
        try {
            val app = fixture.app
            val book = unfittable(app)
            app.download(book, BookContentService.Format.READALOUD)

            app.meteredNetworkOverride = true
            app.wifiOnlyDownloads = true
            delay(300.milliseconds)

            assertNull(fixture.manager.state(job))
            assertEquals(expectedReason, app.downloadRefusals[job])
        } finally {
            fixture.tearDown()
        }
    }
}
