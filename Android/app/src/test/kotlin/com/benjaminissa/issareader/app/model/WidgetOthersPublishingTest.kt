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
}
