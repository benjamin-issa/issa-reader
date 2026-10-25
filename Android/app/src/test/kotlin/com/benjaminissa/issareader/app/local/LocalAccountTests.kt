package com.benjaminissa.issareader.app.local

import com.benjaminissa.issareader.app.Answer
import com.benjaminissa.issareader.app.AppSuite
import com.benjaminissa.issareader.app.LocalFixtures
import com.benjaminissa.issareader.app.PlaybackSettingsForTests
import com.benjaminissa.issareader.app.SharedFixtures
import com.benjaminissa.issareader.app.StubServer
import com.benjaminissa.issareader.app.close
import com.benjaminissa.issareader.app.mainTest
import com.benjaminissa.issareader.app.testApp
import com.benjaminissa.issareader.app.testScope
import com.benjaminissa.issareader.app.model.NowPlayingController
import com.benjaminissa.issareader.app.model.SignOutCentre
import com.benjaminissa.issareader.app.reader.PageSize
import com.benjaminissa.issareader.app.reader.ReaderModel
import com.benjaminissa.issareader.core.model.LocalBookFiles
import com.benjaminissa.issareader.core.model.ReadiumLocator
import com.benjaminissa.issareader.core.store.LibraryStore
import com.benjaminissa.issareader.core.sync.PositionOrigin
import com.benjaminissa.issareader.render.ReaderStyleOverride
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.UUID

/**
 * Signing out leaves the device's own books alone. Ported from
 * `LocalAccountIsolationTests.swift`.
 *
 * The question index's half is the Ask port's: here the sign-out's kept set,
 * which is what the index store is told to keep, stands in for the index
 * files. And Android extracts no `Fonts/<uuid>/` for a sign-out to delete.
 */
class LocalAccountIsolationTest : AppSuite() {
    /** Sign-out and delete downloads keeps a narrating local book, and takes the account's. */
    @Test
    fun signOutKeepsLocalBooks() = mainTest {
        val scope = testScope()
        val local = LocalFixtures(scope)
        val server = StubServer { Answer(404) }
        try {
            local.importAndWait(local.pick("readalong"))
            val localBook = checkNotNull(local.library.books.firstOrNull())
            val serverBook = SharedFixtures.book("Dracula", uuid = UUID.randomUUID().toString().lowercase())

            // The app, and the objects that hear its sign-out, on one centre.
            val centre = SignOutCentre()
            val keptSets = ArrayList<Set<String>>()
            centre.observe { keptSets.add(it) }
            val app = testApp(scope, centre = centre)
            app.localBookUuids = { local.library.uuids }
            // The storage root is the folder `Local/` sits in, as in the app.
            val storage = local.base
            app.storageRoot = storage
            assertEquals(File(storage, "Local"), local.root)
            val nowPlaying = NowPlayingController(scope)
            app.nowPlayingController = nowPlaying
            val settings = PlaybackSettingsForTests.make(centre = centre)

            // Per-book state for both books.
            val style = ReaderStyleOverride(fontSize = 22.0)
            settings.setOverride(style, localBook.uuid)
            settings.setOverride(style, serverBook.uuid)
            settings.setVolumeTrim(-3, localBook.uuid)
            settings.setVolumeTrim(-3, serverBook.uuid)
            // The account's downloads, where the sign-out deletes from.
            for (folder in listOf("Books", "Audio")) {
                File(storage, folder).apply { mkdirs() }.resolve("file").writeText("x")
            }

            // A server book open, and the local book narrating.
            val session = server.session()
            val serverModel = app.reader(serverBook, session)
            val localModel = app.reader(localBook, local.library)
            localModel.open(PageSize(340.0, 560.0))
            assertEquals(ReaderModel.Phase.Ready, localModel.phase)
            val readalong = checkNotNull(localModel.readalong)
            readalong.player.play()
            assertSame("the local book has to be the one narrating", localModel, app.reader)
            assertEquals(localBook.uuid, nowPlaying.book?.uuid)

            app.signOut(keepDownloads = false, nowPlaying = nowPlaying)

            // Still the device's, and still going.
            assertSame("the local reader was released with the account", localModel, app.reader(localBook, local.library))
            assertSame("its narration was stopped", localModel, app.reader)
            assertEquals("its lock-screen controls were taken away", localBook.uuid, nowPlaying.book?.uuid)
            assertEquals(true, localModel.readalong?.player?.isPlaying)
            assertEquals(listOf(localBook.uuid), local.library.books.map { it.uuid })
            val files = local.library.files(localBook.uuid)
            assertTrue(files.epub.exists())
            assertTrue(files.narration.exists())
            assertTrue("Local/ went with the account", local.root.exists())
            assertTrue("the device store went with the account", local.storeDirectory.exists())
            assertNotNull("the local book's typography went", settings.override(localBook.uuid))
            assertEquals("and its level", -3, settings.volumeTrim(localBook.uuid))
            assertTrue("and its question index would go: it was not in the kept set", keptSets.single().contains(localBook.uuid))

            // The account's, gone.
            assertNotSame("the account's reader outlived it", serverModel, app.reader(serverBook, session))
            assertNull(settings.override(serverBook.uuid))
            assertEquals(0, settings.volumeTrim(serverBook.uuid))
            assertFalse("the account's question index would outlive it", serverBook.uuid in keptSets.single())
            for (folder in listOf("Books", "Audio")) {
                assertFalse("$folder outlived a sign-out that deletes downloads", File(storage, folder).exists())
            }

            // And a write the local reader makes afterwards still lands.
            localModel.saveProgress()
            assertNotNull(local.library.books.first().position)
            readalong.player.pause()
            app.stopNarration()
        } finally {
            server.close()
            local.tearDown()
            scope.close()
        }
    }

    /** With no local books, sign-out takes every per-book state as before. */
    @Test
    fun noLocalBooksNoExemptions() = mainTest {
        val scope = testScope()
        val centre = SignOutCentre()
        val app = testApp(scope, centre = centre)
        val settings = PlaybackSettingsForTests.make(centre = centre)
        settings.setVolumeTrim(-3, "11111111-1111-4111-8111-111111111111")

        app.signOut(keepDownloads = true)

        assertTrue(settings.bookVolumeTrims.isEmpty())
        scope.close()
    }
}

/**
 * A local book's place goes through a guard of the local library's own, with
 * the server writer's rules. Ported from `LocalPositionTests.swift`.
 */
class LocalPositionTest : AppSuite() {
    private fun locator(total: Double, href: String = "OEBPS/ch01.xhtml") = ReadiumLocator(
        href = href, type = "application/xhtml+xml",
        locations = ReadiumLocator.Locations(progression = total, totalProgression = total),
    )

    private suspend fun storedProgress(uuid: String, local: LocalFixtures): Double? =
        LibraryStore(LibraryStore.deviceBooksKey, local.storeDirectory).use { it.book(uuid)?.position?.locator?.totalProgression }

    /** A chosen move backwards is taken; a derived one far below the mark is refused. */
    @Test
    fun guardRules() = mainTest {
        val scope = testScope()
        val local = LocalFixtures(scope)
        try {
            local.importAndWait(local.pick("alice"))
            val book = checkNotNull(local.library.books.firstOrNull())
            val library = local.library

            assertTrue(library.writePosition(locator(0.8), 1.0, PositionOrigin.CHOSEN, book.uuid))
            // The reader turning back to the opening is their choice.
            assertTrue(library.writePosition(locator(0.3), 2.0, PositionOrigin.CHOSEN, book.uuid))
            assertTrue(library.writePosition(locator(0.9), 3.0, PositionOrigin.CHOSEN, book.uuid))
            // Narration or a relayout arriving at the front of the book is not.
            assertFalse(library.writePosition(locator(0.2), 4.0, PositionOrigin.DERIVED, book.uuid))

            assertEquals("the refused place reached the list", 0.9, library.books.first().progress)
            assertEquals("and the store", 0.9, storedProgress(book.uuid, local))
            // A derived move forward is ordinary reading.
            assertTrue(library.writePosition(locator(0.92), 5.0, PositionOrigin.DERIVED, book.uuid))
        } finally {
            local.tearDown()
            scope.close()
        }
    }

    /** After a relaunch the guard starts from the stored place. */
    @Test
    fun seededAfterRelaunch() = mainTest {
        val scope = testScope()
        val local = LocalFixtures(scope)
        try {
            local.importAndWait(local.pick("alice"))
            val book = checkNotNull(local.library.books.firstOrNull())
            assertTrue(local.library.writePosition(locator(0.9), 1.0, PositionOrigin.CHOSEN, book.uuid))

            val relaunched = local.relaunched()
            relaunched.load()
            assertEquals(0.9, relaunched.books.first().progress)

            assertFalse(relaunched.writePosition(locator(0.1), 2.0, PositionOrigin.DERIVED, book.uuid))
            assertEquals(0.9, storedProgress(book.uuid, local))
            assertEquals(0.9, relaunched.storedPosition(book.uuid)?.locator?.totalProgression)
        } finally {
            local.tearDown()
            scope.close()
        }
    }

    /** A place older than the one held is not adopted. */
    @Test
    fun olderWriteIsNotAdopted() = mainTest {
        val scope = testScope()
        val local = LocalFixtures(scope)
        try {
            local.importAndWait(local.pick("alice"))
            val book = checkNotNull(local.library.books.firstOrNull())
            assertTrue(local.library.writePosition(locator(0.5), 20.0, PositionOrigin.CHOSEN, book.uuid))
            local.library.writePosition(locator(0.6), 10.0, PositionOrigin.CHOSEN, book.uuid)
            assertEquals(20.0, local.library.books.first().position?.timestamp)
        } finally {
            local.tearDown()
            scope.close()
        }
    }
}
