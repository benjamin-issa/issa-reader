package com.benjaminissa.issareader.app.model

import com.benjaminissa.issareader.app.AppSuite
import com.benjaminissa.issareader.app.SharedFixtures
import com.benjaminissa.issareader.app.close
import com.benjaminissa.issareader.app.mainTest
import com.benjaminissa.issareader.app.testApp
import com.benjaminissa.issareader.app.testScope
import com.benjaminissa.issareader.core.CurrentBookSnapshotStore
import com.benjaminissa.issareader.core.model.Book
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The other books the widget lists: written when the library or the current
 * book changes, and the widget asked to redraw only when what it would draw
 * has moved.
 */
class WidgetOthersPublishingTest : AppSuite() {
    private fun book(id: String, progress: Double = 0.3, at: Double = 0.0): Book =
        SharedFixtures.book("Book $id", uuid = id, status = "Reading", progress = progress, positionTimestamp = at)

    private class Fixture {
        val scope = testScope()
        var reloads = 0
        val publisher = CurrentBookPublisher(scope, reload = { reloads += 1 }).also { it.resume() }

        fun publishCurrent(book: Book, progress: Double = 0.5) = publisher.publish(
            book, session = null, progress = progress, chapter = null, remaining = 600.0, isPlaying = false,
            candidate = CurrentBookPublisher.Owner.Reading(book.uuid),
        )

        val others get() = CurrentBookSnapshotStore.read()?.others.orEmpty()
    }

    /** The others are chosen once the library is known, without the current book, newest first. */
    @Test
    fun theLibraryFillsTheList() = mainTest {
        val f = Fixture()
        try {
            f.publishCurrent(book("cur", at = 100.0))
            f.publisher.libraryChanged(listOf(book("cur", at = 100.0), book("a", at = 1.0), book("b", at = 2.0)), null)
            assertEquals(listOf("b", "a"), f.others.map { it.bookId })
        } finally {
            f.scope.close()
        }
    }

    /** A move below the threshold neither writes nor redraws; one at it does both. */
    @Test
    fun onlyAMeaningfulProgressMoveRedraws() = mainTest {
        val f = Fixture()
        try {
            f.publishCurrent(book("cur"))
            f.publisher.libraryChanged(listOf(book("cur"), book("a", progress = 0.300, at = 1.0)), null)
            val drawn = f.reloads
            f.publisher.libraryChanged(listOf(book("cur"), book("a", progress = 0.3015, at = 1.0)), null)
            assertEquals("drift under the threshold is not drawn", drawn, f.reloads)
            assertEquals(0.300, f.others.single().progress, 0.0)
            f.publisher.libraryChanged(listOf(book("cur"), book("a", progress = 0.305, at = 1.0)), null)
            assertEquals(drawn + 1, f.reloads)
            assertEquals(0.305, f.others.single().progress, 0.0)
        } finally {
            f.scope.close()
        }
    }

    /** The same books in a different order are a redraw; the same books again are not. */
    @Test
    fun aReorderRedrawsAndARepeatDoesNot() = mainTest {
        val f = Fixture()
        try {
            f.publishCurrent(book("cur"))
            f.publisher.libraryChanged(listOf(book("cur"), book("a", at = 1.0), book("b", at = 2.0)), null)
            val drawn = f.reloads
            f.publisher.libraryChanged(listOf(book("cur"), book("a", at = 1.0), book("b", at = 2.0)), null)
            assertEquals(drawn, f.reloads)
            f.publisher.libraryChanged(listOf(book("cur"), book("a", at = 3.0), book("b", at = 2.0)), null)
            assertEquals(drawn + 1, f.reloads)
            assertEquals(listOf("a", "b"), f.others.map { it.bookId })
        } finally {
            f.scope.close()
        }
    }

    /** A book that leaves the list takes its cover file with it; one that stays keeps it. */
    @Test
    fun aBookThatLeavesLosesItsCover() = mainTest {
        val f = Fixture()
        try {
            f.publishCurrent(book("cur"))
            val library = listOf(book("cur"), book("a", at = 1.0), book("b", at = 2.0))
            f.publisher.libraryChanged(library, null)
            CurrentBookSnapshotStore.writeOtherCover("a", byteArrayOf(1))
            CurrentBookSnapshotStore.writeOtherCover("b", byteArrayOf(2))
            f.publisher.libraryChanged(listOf(book("cur"), book("b", at = 2.0)), null)
            assertEquals(setOf("b"), CurrentBookSnapshotStore.otherCoverIds())
            assertEquals(listOf("b"), f.others.map { it.bookId })
        } finally {
            f.scope.close()
        }
    }

    /** Opening another book makes it current: it leaves the list and the old current joins. */
    @Test
    fun aNewCurrentBookTradesPlaces() = mainTest {
        val f = Fixture()
        try {
            val library = listOf(book("cur", at = 5.0), book("a", at = 1.0))
            f.publishCurrent(library[0])
            f.publisher.libraryChanged(library, null)
            assertEquals(listOf("a"), f.others.map { it.bookId })
            f.publishCurrent(library[1])
            assertEquals("a", CurrentBookSnapshotStore.read()?.bookId)
            assertEquals(listOf("cur"), f.others.map { it.bookId })
        } finally {
            f.scope.close()
        }
    }

    /** Publishing the current book again keeps the list it had. */
    @Test
    fun publishingTheCurrentBookKeepsTheList() = mainTest {
        val f = Fixture()
        try {
            f.publisher.libraryChanged(listOf(book("a", at = 1.0)), null)
            f.publishCurrent(book("cur"))
            f.publisher.libraryChanged(listOf(book("cur"), book("a", at = 1.0)), null)
            f.publishCurrent(book("cur"), progress = 0.6)
            assertEquals(listOf("a"), f.others.map { it.bookId })
        } finally {
            f.scope.close()
        }
    }

    /** Sign-out clears every cover, and the library handed over after it writes nothing. */
    @Test
    fun signOutClearsAndSilencesTheList() = mainTest {
        val f = Fixture()
        try {
            f.publishCurrent(book("cur"))
            f.publisher.libraryChanged(listOf(book("cur"), book("a", at = 1.0)), null)
            CurrentBookSnapshotStore.writeOtherCover("a", byteArrayOf(1))
            f.publisher.clear()
            assertTrue(CurrentBookSnapshotStore.otherCoverIds().isEmpty())
            f.publisher.libraryChanged(listOf(book("a", at = 1.0)), null)
            assertNull(CurrentBookSnapshotStore.read())
        } finally {
            f.scope.close()
        }
    }

    /** With no current book there is nothing to hang a list on. */
    @Test
    fun noCurrentBookWritesNothing() = mainTest {
        val f = Fixture()
        try {
            f.publisher.libraryChanged(listOf(book("a", at = 1.0)), null)
            assertNull(CurrentBookSnapshotStore.read())
            assertFalse(f.reloads > 0)
        } finally {
            f.scope.close()
        }
    }

    /** A model that has not loaded a catalogue leaves the stored others and their covers alone; a loaded empty one clears them. */
    @Test
    fun launchBeforeTheCatalogueKeepsTheList() = mainTest {
        val f = Fixture()
        val app = testApp(f.scope)
        try {
            app.currentBookPublisher = f.publisher
            f.publishCurrent(book("cur"))
            f.publisher.libraryChanged(listOf(book("cur"), book("a", at = 1.0)), null)
            CurrentBookSnapshotStore.writeOtherCover("a", byteArrayOf(1))

            // What init does, and what a failed first refresh leaves.
            app.rebuildDerived()
            assertEquals(listOf("a"), f.others.map { it.bookId })
            assertEquals(setOf("a"), CurrentBookSnapshotStore.otherCoverIds())

            app.catalogueApplied = true
            app.rebuildDerived()
            assertTrue(f.others.isEmpty())
            assertTrue(CurrentBookSnapshotStore.otherCoverIds().isEmpty())
        } finally {
            f.scope.close()
        }
    }

    /** A cover write that lands after a sign-out does not leave the departed account's file behind. */
    @Test
    fun aCoverWriteOvertakenBySignOutLeavesNoFile() = mainTest {
        val scope = testScope()
        val dir = java.nio.file.Files.createTempDirectory("covers").toFile()
        val covers = CoverCache(directory = dir)
        val gate = kotlinx.coroutines.CompletableDeferred<Unit>()
        val started = kotlinx.coroutines.CompletableDeferred<Unit>()
        val publisher = CurrentBookPublisher(
            scope, covers = { covers },
            writeOtherCover = { id, data ->
                started.complete(Unit)
                gate.await()
                CurrentBookSnapshotStore.writeOtherCover(id, data)
            },
        ).also { it.resume() }
        try {
            val a = book("a", at = 1.0)
            // The art is already in the cache's directory, so the fetch needs no network.
            java.io.File(dir, CoverCache.widgetFileName(a, com.benjaminissa.issareader.core.sync.LibraryService.CoverShape.PORTRAIT))
                .writeBytes(byteArrayOf(1, 2, 3))
            publisher.publish(
                book("cur"), session = null, progress = 0.5, chapter = null, remaining = 600.0, isPlaying = false,
                candidate = CurrentBookPublisher.Owner.Reading("cur"),
            )
            val session = com.benjaminissa.issareader.core.Session(
                java.net.URI("https://covers.example"), com.benjaminissa.issareader.app.TestTokens(),
            )
            publisher.libraryChanged(listOf(book("cur"), a), session)
            started.await()

            publisher.clear()
            gate.complete(Unit)
            kotlinx.coroutines.yield()
            kotlinx.coroutines.delay(200)

            assertTrue(CurrentBookSnapshotStore.otherCoverIds().isEmpty())
        } finally {
            scope.close()
        }
    }

    /** A current-book cover write that a sign-out overtakes leaves no file for the next account's widget. */
    @Test
    fun aCurrentCoverWriteOvertakenBySignOutLeavesNoFile() = mainTest {
        val scope = testScope()
        val dir = java.nio.file.Files.createTempDirectory("covers").toFile()
        val covers = CoverCache(directory = dir)
        val gate = kotlinx.coroutines.CompletableDeferred<Unit>()
        val started = kotlinx.coroutines.CompletableDeferred<Unit>()
        val publisher = CurrentBookPublisher(
            scope, covers = { covers },
            writeCover = { data ->
                started.complete(Unit)
                gate.await()
                CurrentBookSnapshotStore.writeCover(data)
            },
        ).also { it.resume() }
        try {
            val cur = book("cur")
            java.io.File(dir, CoverCache.widgetFileName(cur, com.benjaminissa.issareader.core.sync.LibraryService.CoverShape.PORTRAIT))
                .writeBytes(byteArrayOf(1, 2, 3))
            val session = com.benjaminissa.issareader.core.Session(
                java.net.URI("https://covers.example"), com.benjaminissa.issareader.app.TestTokens(),
            )
            publisher.publish(
                cur, session = session, progress = 0.5, chapter = null, remaining = 600.0, isPlaying = false,
                candidate = CurrentBookPublisher.Owner.Reading("cur"),
            )
            started.await()

            publisher.clear()
            gate.complete(Unit)
            kotlinx.coroutines.yield()
            kotlinx.coroutines.delay(200)

            assertFalse(CurrentBookSnapshotStore.coverFile!!.exists())
        } finally {
            scope.close()
        }
    }

    /**
     * Signing out tells the publisher the library emptied, before it is cleared: the list is
     * reconciled against nothing, so a publish in that window lists no others.
     */
    @Test
    fun signingOutEmptiesTheOthersBeforeTheClear() = mainTest {
        val scope = testScope()
        val seen = mutableListOf<List<String>?>()
        val publisher = CurrentBookPublisher(scope, reload = { seen += CurrentBookSnapshotStore.read()?.others?.map { it.bookId } }).also { it.resume() }
        val app = testApp(scope)
        app.currentBookPublisher = publisher
        try {
            val library = listOf(book("cur", at = 9.0), book("a", at = 1.0), book("b", at = 2.0))
            app.books = library
            app.catalogueApplied = true
            publisher.publish(
                library[0], session = null, progress = 0.5, chapter = null, remaining = 600.0, isPlaying = false,
                candidate = CurrentBookPublisher.Owner.Reading("cur"),
            )
            publisher.libraryChanged(library, null)
            assertEquals(listOf("b", "a"), CurrentBookSnapshotStore.read()?.others?.map { it.bookId })
            seen.clear()

            app.signOut(keepDownloads = true)

            assertEquals("the first redraw is of a snapshot with no others, before the clear", emptyList<String>(), seen.first())
            assertNull(CurrentBookSnapshotStore.read())
        } finally {
            scope.close()
        }
    }

    /** A server with a portrait and a square cover behind the uuid route, either of which can be missing. */
    private fun artServer(portrait: Boolean = true, square: Boolean = true) = com.benjaminissa.issareader.app.StubServer { request ->
        when {
            request.path.endsWith("/cover") && request.query.contains("audio") ->
                if (square) com.benjaminissa.issareader.app.Answer(200, "square art") else com.benjaminissa.issareader.app.Answer(404)
            request.path.endsWith("/cover") ->
                if (portrait) com.benjaminissa.issareader.app.Answer(200, "portrait art") else com.benjaminissa.issareader.app.Answer(404)
            else -> com.benjaminissa.issareader.app.Answer(404)
        }
    }

    private suspend fun sessionOn(server: com.benjaminissa.issareader.app.StubServer) =
        com.benjaminissa.issareader.core.Session(server.url, com.benjaminissa.issareader.app.TestTokens(), server.http)
            .also { it.adopt("a-token") }

    private fun coverRequests(server: com.benjaminissa.issareader.app.StubServer) = server.requests().filter { it.path.endsWith("/cover") }

    private fun storedCover(id: String): String? = CurrentBookSnapshotStore.otherCoverFile(id)?.takeIf { it.exists() }?.readText()

    /** A book with both editions takes the ebook's portrait cover, since others are only drawn in portrait slots. */
    @Test
    fun aBookWithBothEditionsGetsItsPortraitCover() = mainTest {
        artServer().use { server ->
            val scope = testScope()
            val covers = CoverCache(directory = com.benjaminissa.issareader.app.temporaryDirectory("covers"))
            val publisher = CurrentBookPublisher(scope, covers = { covers }).also { it.resume() }
            try {
                val both = SharedFixtures.book("Both", uuid = "a", status = "Reading", progress = 0.3, positionTimestamp = 1.0, audiobook = true)
                publisher.publish(
                    book("cur"), session = null, progress = 0.5, chapter = null, remaining = 600.0, isPlaying = false,
                    candidate = CurrentBookPublisher.Owner.Reading("cur"),
                )
                publisher.libraryChanged(listOf(book("cur"), both), sessionOn(server))
                assertTrue(com.benjaminissa.issareader.app.waitUntil { CurrentBookSnapshotStore.read()?.others?.singleOrNull()?.coverTriedPortrait == true })
                assertEquals("portrait art", storedCover("a"))
                assertFalse(CurrentBookSnapshotStore.read()!!.others.single().coverIsSquare)
                assertTrue("the square route was not asked", coverRequests(server).none { it.query.contains("audio") })
            } finally {
                scope.close()
            }
        }
    }

    /** An audiobook-only book has no portrait art: the square falls in, and is recorded as square. */
    @Test
    fun anAudiobookOnlyBookFallsBackToSquare() = mainTest {
        artServer(portrait = false).use { server ->
            val scope = testScope()
            val covers = CoverCache(directory = com.benjaminissa.issareader.app.temporaryDirectory("covers"))
            val publisher = CurrentBookPublisher(scope, covers = { covers }).also { it.resume() }
            try {
                val audio = SharedFixtures.book("Audio", uuid = "a", status = "Reading", progress = 0.3, positionTimestamp = 1.0, audiobook = true, ebook = false)
                publisher.publish(
                    book("cur"), session = null, progress = 0.5, chapter = null, remaining = 600.0, isPlaying = false,
                    candidate = CurrentBookPublisher.Owner.Reading("cur"),
                )
                publisher.libraryChanged(listOf(book("cur"), audio), sessionOn(server))
                assertTrue(com.benjaminissa.issareader.app.waitUntil { CurrentBookSnapshotStore.read()?.others?.singleOrNull()?.coverTriedPortrait == true })
                assertEquals("square art", storedCover("a"))
                assertTrue(CurrentBookSnapshotStore.read()!!.others.single().coverIsSquare)
            } finally {
                scope.close()
            }
        }
    }

    /** Sets up a stored square cover for the book with both editions, as an earlier version left it. */
    private fun leaveSquareCover(scope: kotlinx.coroutines.CoroutineScope, both: Book) {
        val seeding = CurrentBookPublisher(scope).also { it.resume() }
        seeding.publish(
            book("cur"), session = null, progress = 0.5, chapter = null, remaining = 600.0, isPlaying = false,
            candidate = CurrentBookPublisher.Owner.Reading("cur"),
        )
        seeding.libraryChanged(listOf(book("cur"), both), null)
        CurrentBookSnapshotStore.writeOtherCover(both.uuid, "old square".toByteArray())
        val snapshot = CurrentBookSnapshotStore.read()!!
        CurrentBookSnapshotStore.write(snapshot.copy(others = snapshot.others.map { it.copy(coverIsSquare = true, coverTriedPortrait = false) }))
    }

    /** A square stored before the preference changed is replaced by the portrait art once, and then left alone. */
    @Test
    fun aStoredSquareIsReplacedByPortraitOnce() = mainTest {
        artServer().use { server ->
            val scope = testScope()
            val dir = com.benjaminissa.issareader.app.temporaryDirectory("covers")
            try {
                val both = SharedFixtures.book("Both", uuid = "a", status = "Reading", progress = 0.3, positionTimestamp = 1.0, audiobook = true)
                leaveSquareCover(scope, both)
                val publisher = CurrentBookPublisher(scope, covers = { CoverCache(directory = dir) }).also { it.resume() }
                publisher.libraryChanged(listOf(book("cur"), both), sessionOn(server))
                assertTrue(com.benjaminissa.issareader.app.waitUntil { storedCover("a") == "portrait art" })
                assertTrue(com.benjaminissa.issareader.app.waitUntil { !CurrentBookSnapshotStore.read()!!.others.single().coverIsSquare })
                val asked = coverRequests(server).size
                // A new process: nothing remembered in memory.
                val next = CurrentBookPublisher(scope, covers = { CoverCache(directory = dir) }).also { it.resume() }
                next.libraryChanged(listOf(book("cur"), both), sessionOn(server))
                kotlinx.coroutines.delay(200)
                assertEquals(asked, coverRequests(server).size)
            } finally {
                scope.close()
            }
        }
    }

    /** A square stored for a book that has no portrait art stays, and the question is not asked again. */
    @Test
    fun aStoredSquareWithNoPortraitArtStaysAndIsNotAskedAgain() = mainTest {
        artServer(portrait = false).use { server ->
            val scope = testScope()
            val dir = com.benjaminissa.issareader.app.temporaryDirectory("covers")
            try {
                val both = SharedFixtures.book("Both", uuid = "a", status = "Reading", progress = 0.3, positionTimestamp = 1.0, audiobook = true)
                leaveSquareCover(scope, both)
                val publisher = CurrentBookPublisher(scope, covers = { CoverCache(directory = dir) }).also { it.resume() }
                publisher.libraryChanged(listOf(book("cur"), both), sessionOn(server))
                assertTrue(com.benjaminissa.issareader.app.waitUntil { CurrentBookSnapshotStore.read()!!.others.single().coverTriedPortrait })
                assertEquals("old square", storedCover("a"))
                assertTrue(CurrentBookSnapshotStore.read()!!.others.single().coverIsSquare)
                val asked = coverRequests(server).size
                val next = CurrentBookPublisher(scope, covers = { CoverCache(directory = dir) }).also { it.resume() }
                next.libraryChanged(listOf(book("cur"), both), sessionOn(server))
                kotlinx.coroutines.delay(200)
                assertEquals(asked, coverRequests(server).size)
                assertEquals("old square", storedCover("a"))
            } finally {
                scope.close()
            }
        }
    }

    /** The current book still prefers its audiobook's square cover. */
    @Test
    fun theCurrentBookStillPrefersSquare() = mainTest {
        artServer().use { server ->
            val scope = testScope()
            val covers = CoverCache(directory = com.benjaminissa.issareader.app.temporaryDirectory("covers"))
            val publisher = CurrentBookPublisher(scope, covers = { covers }).also { it.resume() }
            try {
                val both = SharedFixtures.book("Both", uuid = "cur", audiobook = true)
                publisher.publish(
                    both, session = sessionOn(server), progress = 0.5, chapter = null, remaining = 600.0, isPlaying = false,
                    candidate = CurrentBookPublisher.Owner.Reading("cur"),
                )
                assertTrue(com.benjaminissa.issareader.app.waitUntil { CurrentBookSnapshotStore.coverFile?.exists() == true })
                assertEquals("square art", CurrentBookSnapshotStore.coverFile!!.readText())
                assertTrue(CurrentBookSnapshotStore.read()!!.coverIsSquare)
            } finally {
                scope.close()
            }
        }
    }
}
