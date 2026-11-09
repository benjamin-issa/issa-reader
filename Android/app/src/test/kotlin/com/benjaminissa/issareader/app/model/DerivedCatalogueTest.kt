package com.benjaminissa.issareader.app.model

import com.benjaminissa.issareader.app.AppSuite
import com.benjaminissa.issareader.app.SharedFixtures
import com.benjaminissa.issareader.app.close
import com.benjaminissa.issareader.app.mainTest
import com.benjaminissa.issareader.app.testApp
import com.benjaminissa.issareader.app.testScope
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.ReadiumLocator
import com.benjaminissa.issareader.core.sync.LibraryArrangement
import com.benjaminissa.issareader.core.sync.LibraryDerivation
import kotlinx.coroutines.CoroutineScope
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/**
 * The memoised catalogue indexes stay as live as the scans they replaced.
 * Ported from `DerivedCatalogueTests.swift`: each case is one path on which
 * the dictionary could go stale.
 */
class DerivedCatalogueTest : AppSuite() {
    companion object {
        fun model(scope: CoroutineScope, books: List<Book>): AppModel {
            val app = testApp(scope)
            app.books = books
            app.rebuildDerived()
            return app
        }
    }

    /** A download set that did not change does not rebuild the catalogue. */
    @Test
    fun anUnchangedDownloadSetDoesNotRebuild() = mainTest {
        val scope = testScope()
        val app = model(scope, listOf(SharedFixtures.book("Dracula", uuid = "d")))
        app.refreshDownloadedSet()
        val rebuilds = app.derivedRebuilds

        app.refreshDownloadedSet()
        app.refreshDownloadedSet()

        assertEquals("the same answer from the disk is not news", rebuilds, app.derivedRebuilds)
        scope.close()
    }

    /** The index holds every book the catalogue does. */
    @Test
    fun indexesTheCatalogue() = mainTest {
        val scope = testScope()
        val app = model(scope, listOf(SharedFixtures.book("Dracula", uuid = "d"), SharedFixtures.book("Bleak House", uuid = "b")))
        assertEquals("Dracula", app.bookByUuid["d"]?.title)
        assertEquals("Bleak House", app.bookByUuid["b"]?.title)
        assertNull(app.bookByUuid["missing"])
        scope.close()
    }

    /** The path that matters: a position write reaches the index. */
    @Test
    fun positionWritesAreVisible() = mainTest {
        val scope = testScope()
        val app = model(scope, listOf(SharedFixtures.book("Dracula", uuid = "d", progress = 0.1)))
        val before = app.bookByUuid["d"]?.position?.locator?.totalProgression
        assertTrue(before?.let { abs(it - 0.1) < 0.0001 } == true)

        app.recordPosition(
            ReadiumLocator(
                href = "OEBPS/ch09.xhtml", type = "application/xhtml+xml",
                locations = ReadiumLocator.Locations(progression = 0.62, totalProgression = 0.62),
            ),
            timestamp = 1.0,
            bookUuid = "d",
        )

        val after = app.bookByUuid["d"]?.position?.locator?.totalProgression
        assertTrue("the book screen would still be showing $after", after?.let { abs(it - 0.62) < 0.0001 } == true)
        scope.close()
    }

    /** A position that moves an unfiled book to another shelf moves its counts and rails. */
    @Test
    fun aPositionThatChangesTheShelfRebuildsTheFacets() = mainTest {
        val scope = testScope()
        val app = model(scope, listOf(SharedFixtures.book("Dracula", uuid = "d"), SharedFixtures.book("Bleak House", uuid = "b")))
        assertEquals(2, app.facets.count(LibraryArrangement.Shelf.TO_READ))
        assertEquals(0, app.facets.count(LibraryArrangement.Shelf.READING))
        assertTrue(app.readingHome.upNext.any { it.uuid == "d" })

        app.recordPosition(
            ReadiumLocator(
                href = "OEBPS/ch09.xhtml", type = "application/xhtml+xml",
                locations = ReadiumLocator.Locations(progression = 0.5, totalProgression = 0.5),
            ),
            timestamp = 1.0,
            bookUuid = "d",
        )

        assertTrue("the grid is not what is under test", app.arrangedBooks.any { it.uuid == "d" })
        assertEquals("the Reading chip did not count the book now on it", 1, app.facets.count(LibraryArrangement.Shelf.READING))
        assertEquals("the To read chip went on counting a book being read", 1, app.facets.count(LibraryArrangement.Shelf.TO_READ))
        assertTrue(app.rails.reading.any { it.uuid == "d" })
        assertFalse(app.rails.toRead.any { it.uuid == "d" })
        assertFalse(
            "Up next listed the book beside the Continue card it had become",
            app.readingHome.upNext.any { it.uuid == "d" },
        )
        scope.close()
    }

    /** Signing out empties the index too. */
    @Test
    fun signOutClearsTheIndex() = mainTest {
        val scope = testScope()
        val app = model(scope, listOf(SharedFixtures.book("Dracula", uuid = "d")))
        assertNotNull(app.bookByUuid["d"])
        app.signOut(keepDownloads = true)
        assertTrue(app.bookByUuid.isEmpty())
        scope.close()
    }

    /** The author and narrator groupings say what the computed ones did. */
    @Test
    fun groupingsMatchTheDerivation() = mainTest {
        val scope = testScope()
        val books = listOf(
            SharedFixtures.book("Dracula", uuid = "d", authors = listOf("Bram Stoker"), narrators = listOf("A Reader")),
            SharedFixtures.book("The Lair", uuid = "l", authors = listOf("Bram Stoker")),
            SharedFixtures.book("Bleak House", uuid = "b", authors = listOf("Charles Dickens")),
        )
        val app = model(scope, books)
        val derivation = LibraryDerivation(books)

        assertEquals(derivation.byAuthor.mapValues { (_, v) -> v.map { it.uuid } }, app.booksByAuthor.mapValues { (_, v) -> v.map { it.uuid } })
        assertEquals(derivation.byNarrator.mapValues { (_, v) -> v.map { it.uuid } }, app.booksByNarrator.mapValues { (_, v) -> v.map { it.uuid } })
        assertEquals(2, app.booksByAuthor["Bram Stoker"]?.size)
        assertEquals(1, app.booksByNarrator["A Reader"]?.size)
        scope.close()
    }

    /** The tag grouping says what the derivation does, each book once. */
    @Test
    fun tagGroupingMatchesTheDerivation() = mainTest {
        val scope = testScope()
        val books = listOf(
            SharedFixtures.book("Dracula", uuid = "d", tags = listOf("Gothic", "Gothic")),
            SharedFixtures.book("Carmilla", uuid = "c", tags = listOf("Gothic", "Vampires")),
        )
        val app = model(scope, books)

        assertEquals(LibraryDerivation(books).byTag.mapValues { (_, v) -> v.map { it.uuid } }, app.booksByTag.mapValues { (_, v) -> v.map { it.uuid } })
        assertEquals(listOf("d", "c"), app.booksByTag["Gothic"]?.map { it.uuid })
        assertEquals(1, app.booksByTag["Vampires"]?.size)
        scope.close()
    }
}
